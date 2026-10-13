import AppKit
import Darwin
import Foundation
import Observation

@MainActor @Observable public final class RemoteDevelopmentStateMachine {
    private(set) var profile: ConnectionProfile
    private(set) var isOpening = false
    private(set) var errorMessage: String?
    private(set) var editorLaunched = false
    private let auth: AuthProviding
    private let ec2: EC2Providing
    private let ssm: SSMProviding
    private let keyGenerator: SSHKeyGenerating
    private let root: URL
    private let setup: RemoteSSHSetup
    private let helperPath: () -> String
    private let editorPath: () -> String?
    private let editorPreflight: (String) async throws -> Void
    private var task: Task<Void, Never>?
    private var keys: [UUID: SSHKeyMaterial] = [:]
    private var leases: [UUID: URL] = [:]

    public convenience init(profile: ConnectionProfile) {
        self.init(profile: profile, root: BrowserPrivateFiles.root.deletingLastPathComponent()
            .appendingPathComponent("RemoteAccess"), configURL: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config"))
    }

    init(profile: ConnectionProfile, root: URL, configURL: URL, auth: AuthProviding = AWSAuthProvider(),
         ec2: EC2Providing = EC2Service(), ssm: SSMProviding = SSMService(), keyGenerator: SSHKeyGenerating = SSHKeyGenerator(),
         helperPath: @escaping () -> String = { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ssm-connect-proxy").path },
         editorPath: @escaping () -> String? = {
             NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode")?
                 .appendingPathComponent("Contents/Resources/app/bin/code").path
         }, editorPreflight: @escaping (String) async throws -> Void = RemoteEditorPreflight.check) {
        self.profile = profile
        self.root = root
        self.setup = RemoteSSHSetup(root: root, configURL: configURL)
        self.auth = auth
        self.ec2 = ec2
        self.ssm = ssm
        self.keyGenerator = keyGenerator
        self.helperPath = helperPath
        self.editorPath = editorPath
        self.editorPreflight = editorPreflight
        AppQuitHandler.shared.register { [weak self] in self?.stopAll() }
    }

    var isActive: Bool { leases[profile.id] != nil }
    var setupInstalled: Bool { setup.isInstalled }
    var setupConfigPath: String { setup.configURL.path }

    func apply(profile: ConnectionProfile) {
        guard self.profile != profile else { return }
        task?.cancel()
        self.profile = profile
        errorMessage = nil
        editorLaunched = false
    }

    func installSetup(consent: Bool) throws { try setup.install(consent: consent) }

    func restoreSetup() throws {
        guard setup.isInstalled else { throw RemoteSSHError.configurationConflict }
        stopAll()
        try setup.restore()
    }

    func open() {
        guard task == nil else { return }
        isOpening = true
        errorMessage = nil
        editorLaunched = false
        task = Task {
            defer { self.isOpening = false; self.task = nil }
            do { try await self.prepareAndLaunch() }
            catch { if !Task.isCancelled { self.errorMessage = error.localizedDescription } }
        }
    }

    func awaitOpening() async { await task?.value }

    func stop() { task?.cancel(); stop(profileID: profile.id) }

    private func stop(profileID: UUID) {
        if let path = leases.removeValue(forKey: profileID) { try? FileManager.default.removeItem(at: path) }
        let key = keys.removeValue(forKey: profileID)
        Task { try? await Task.sleep(for: .seconds(1)); key?.remove() }
    }

    private func stopAll() {
        task?.cancel()
        for id in Array(leases.keys) { stop(profileID: id) }
    }

    private func prepareAndLaunch() async throws {
        let profile = profile
        guard profile.isConfigured, profile.remoteDevelopment?.enabled == true, setup.isInstalled,
              let editor = editorPath(), FileManager.default.isExecutableFile(atPath: editor),
              FileManager.default.isExecutableFile(atPath: helperPath()) else { throw RemoteSSHError.unavailable }
                try await editorPreflight(editor)
                try Task.checkCancellation()
        let arguments = try RemoteSSHConfiguration.arguments(alias: RemoteSSHConfiguration.alias(profile.id), folder: profile.remoteDevelopment?.folder)
        let credentials = try await auth.authenticate(profile: profile)
                try Task.checkCancellation()
        var instance = try await ec2.resolveInstance(tagKey: profile.instanceTagKey, tagValue: profile.instanceTagValue,
                                                    region: profile.resourceRegion, credentials: credentials)
                try Task.checkCancellation()
        guard !instance.state.isTerminal else { throw EC2Error.instanceTerminated(instanceId: instance.id) }
        if instance.state != .running {
            try await ec2.startInstance(instanceId: instance.id, region: profile.resourceRegion, credentials: credentials)
            instance = try await ec2.pollUntilRunning(instanceId: instance.id, region: profile.resourceRegion,
                credentials: credentials, timeout: .seconds(600), interval: .seconds(5))
        }
        try Task.checkCancellation()
        try await ssm.waitForSSMOnline(instanceId: instance.id, region: profile.resourceRegion, credentials: credentials,
                                     timeout: .seconds(120), interval: .seconds(5))
        try Task.checkCancellation()
        let configuredUser = profile.webForwards?.sshUser?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let user = configuredUser.isEmpty
            ? try await STSIdentityResolver(presigner: STSPresigner(region: profile.resourceRegion)).resolve(credentials: credentials).username
            : configuredUser
        try Task.checkCancellation()
        if leases[profile.id] == nil {
            let key = try await keyGenerator.generate()
            try Task.checkCancellation()
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.privateKeyPath + ".pub")
            let directory = root.appendingPathComponent(profile.id.uuidString, isDirectory: true)
            let leaseURL = directory.appendingPathComponent("lease.json")
            guard let launchDate = NSRunningApplication.current.launchDate,
                  let bundleID = NSRunningApplication.current.bundleIdentifier else { throw RemoteSSHError.invalidLease }
            let lease = RemoteSSHLease(profile: profile, instanceID: instance.id, user: user, keyPath: key.privateKeyPath,
                pluginPath: BundledPluginTunnel.defaultPluginPath() ?? "", ownerPID: NSRunningApplication.current.processIdentifier,
                ownerLaunchDate: launchDate, ownerBundleID: bundleID, generation: UUID(), expiresAt: Date().addingTimeInterval(24 * 60 * 60))
            try BrowserPrivateFiles.write(try JSONEncoder().encode(lease), to: leaseURL)
            let contents = try RemoteSSHConfiguration.contents(lease: lease, leasePath: leaseURL.path,
                helperPath: helperPath(), knownHostsPath: root.appendingPathComponent("known-hosts").path)
            try setup.writeHost(contents, profileID: profile.id)
            keys[profile.id] = key
            leases[profile.id] = leaseURL
        } else {
            let lease = try JSONDecoder().decode(RemoteSSHLease.self, from: Data(contentsOf: leases[profile.id]!))
            guard lease.profile.accountId == profile.accountId, lease.profile.resourceRegion == profile.resourceRegion,
                lease.profile.ssoStartUrl == profile.ssoStartUrl, lease.profile.ssoRegion == profile.ssoRegion,
                lease.profile.roleName == profile.roleName, lease.expiresAt > Date(),
                  lease.instanceID == instance.id, lease.user == user else { throw RemoteSSHError.targetChanged }
        }
        try Task.checkCancellation()
        _ = try await RemoteEditorPreflight.run(editor, arguments: arguments)
        editorLaunched = true
    }
}

enum RemoteEditorPreflight {
    static func check(_ executable: String) async throws {
        let data = try await run(executable, arguments: ["--locate-extension", "ms-vscode-remote.remote-ssh"])
        let directory = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !directory.isEmpty,
              FileManager.default.fileExists(atPath: directory + "/package.json") else { throw RemoteSSHError.unavailable }
    }

    static func run(_ executable: String, arguments: [String], timeout: Duration = .seconds(15)) async throws -> Data {
        try Task.checkCancellation()
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("ssm-editor-cli-" + UUID().uuidString)
        try BrowserPrivateFiles.write(Data(), to: outputURL, createParent: false)
        defer { try? FileManager.default.removeItem(at: outputURL) }
        let output = try FileHandle(forWritingTo: outputURL)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        do {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while process.isRunning {
                try Task.checkCancellation()
                let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
                guard ContinuousClock.now < deadline,
                      (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 64 * 1024 else { throw RemoteSSHError.unavailable }
                try await Task.sleep(for: .milliseconds(25))
            }
            try Task.checkCancellation()
            let reader = try FileHandle(forReadingFrom: outputURL)
            defer { try? reader.close() }
            let data = try reader.read(upToCount: 64 * 1024 + 1) ?? Data()
            guard process.terminationStatus == 0, data.count <= 64 * 1024 else { throw RemoteSSHError.unavailable }
            return data
        } catch {
            if process.isRunning {
                process.terminate()
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            throw error
        }
    }
}