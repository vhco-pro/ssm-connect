import AppKit
import Darwin
import Foundation
import Observation

@MainActor @Observable public final class RemoteDevelopmentStateMachine {
    private(set) var profile: ConnectionProfile
    private(set) var isOpening = false
    private(set) var errorMessage: String?
    private(set) var editorLaunched = false
    private(set) var leaseMessage: String?
    private(set) var isRenewingLease = false
    private let auth: AuthProviding
    private let ec2: EC2Providing
    private let ssm: SSMProviding
    private let keyGenerator: SSHKeyGenerating
    private let root: URL
    private let setup: RemoteSSHSetup
    private let helperPath: () -> String
    private let pluginPath: () -> String?
    private let editorPath: () -> String?
    private let editorPreflight: (String) async throws -> Void
    private let ownerIdentity: () -> (pid: Int32, launchDate: Date, bundleID: String)?
    private let now: () -> Date
    private let renewalSleep: @Sendable (Duration) async throws -> Void
    private let writeLease: (Data, URL) throws -> Void
    private let launchEditor: (String, [String]) async throws -> Void
    private var task: Task<Void, Never>?
    private var continuationTask: Task<Void, Never>?
    private var renewalTask: Task<Void, Never>?
    private var renewalGeneration = 0
    private var keys: [UUID: SSHKeyMaterial] = [:]
    private var leases: [UUID: URL] = [:]
    private var grantedLeases: [UUID: RemoteSSHLease] = [:]
    private var leaseExpiries: [UUID: Date] = [:]

    public convenience init(profile: ConnectionProfile, authorization: AuthorizationSession? = nil) {
        self.init(profile: profile, root: BrowserPrivateFiles.root.deletingLastPathComponent()
            .appendingPathComponent("RemoteAccess"), configURL: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config"),
            auth: authorization ?? AWSAuthProvider())
    }

    init(profile: ConnectionProfile, root: URL, configURL: URL, auth: AuthProviding = AWSAuthProvider(),
         ec2: EC2Providing = EC2Service(), ssm: SSMProviding = SSMService(), keyGenerator: SSHKeyGenerating = SSHKeyGenerator(),
         helperPath: @escaping () -> String = { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ssm-connect-proxy").path },
         pluginPath: @escaping () -> String? = BundledPluginTunnel.defaultPluginPath,
         editorPath: @escaping () -> String? = {
             NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode")?
                 .appendingPathComponent("Contents/Resources/app/bin/code").path
         }, editorPreflight: @escaping (String) async throws -> Void = RemoteEditorPreflight.check,
         ownerIdentity: @escaping () -> (pid: Int32, launchDate: Date, bundleID: String)? = {
             guard let launchDate = NSRunningApplication.current.launchDate,
                   let bundleID = NSRunningApplication.current.bundleIdentifier else { return nil }
             return (NSRunningApplication.current.processIdentifier, launchDate, bundleID)
         },
         now: @escaping () -> Date = { Date() },
         renewalSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         writeLease: @escaping (Data, URL) throws -> Void = { try BrowserPrivateFiles.write($0, to: $1) },
         launchEditor: @escaping (String, [String]) async throws -> Void = {
             _ = try await RemoteEditorPreflight.run($0, arguments: $1)
         }) {
        self.profile = profile
        self.root = root
        self.setup = RemoteSSHSetup(root: root, configURL: configURL)
        self.auth = auth
        self.ec2 = ec2
        self.ssm = ssm
        self.keyGenerator = keyGenerator
        self.helperPath = helperPath
        self.pluginPath = pluginPath
        self.editorPath = editorPath
        self.editorPreflight = editorPreflight
        self.ownerIdentity = ownerIdentity
        self.now = now
        self.renewalSleep = renewalSleep
        self.writeLease = writeLease
        self.launchEditor = launchEditor
        AppQuitHandler.shared.register { [weak self] in self?.terminateForQuit() }
    }

    var isActive: Bool { leases[profile.id] != nil }
    var leaseExpiry: Date? { leaseExpiries[profile.id] }
    var setupInstalled: Bool { setup.isInstalled }
    var setupConfigPath: String { setup.configURL.path }

    public func apply(profile: ConnectionProfile) {
        guard self.profile != profile else { return }
        task?.cancel()
        cancelContinuation()
        self.profile = profile
        errorMessage = nil
        editorLaunched = false
        leaseMessage = nil
        if leases[profile.id] != nil, profile.remoteDevelopment?.enabled == true {
            do {
                let lease = try readOwnedLease()
                guard try lease.canReuse(profile: profile, instanceID: lease.instanceID, user: lease.user, now: now()),
                      configuredUser(lease.profile) == configuredUser(profile) else { throw RemoteSSHError.targetChanged }
                scheduleContinuation()
            } catch {
                leaseMessage = "Editor access was not renewed: \(error.localizedDescription)"
            }
        }
    }

    func installSetup(consent: Bool) throws { try setup.install(consent: consent) }

    func restoreSetup() throws {
        guard setup.isInstalled else { throw RemoteSSHError.configurationConflict }
        stopAll()
        try setup.restore()
    }

    func open() {
        guard task == nil else { return }
        cancelContinuation()
        leaseMessage = nil
        isOpening = true
        errorMessage = nil
        editorLaunched = false
        let selected = profile
        task = Task {
            defer {
                self.isOpening = false
                self.task = nil
                if !Task.isCancelled, self.profile == selected { self.scheduleContinuation() }
            }
            do { try await self.prepareAndLaunch() }
            catch { if !Task.isCancelled { self.errorMessage = error.localizedDescription } }
        }
    }

    func awaitOpening() async { await task?.value }

    func stop() { task?.cancel(); stop(profileID: profile.id) }

    func terminateForQuit() { stopAll() }

    private func stop(profileID: UUID) {
        if profileID == profile.id {
            cancelContinuation()
            leaseMessage = nil
        }
        leaseExpiries.removeValue(forKey: profileID)
        grantedLeases.removeValue(forKey: profileID)
        if let path = leases.removeValue(forKey: profileID) { try? FileManager.default.removeItem(at: path) }
        let key = keys.removeValue(forKey: profileID)
        Task { try? await Task.sleep(for: .seconds(1)); key?.remove() }
    }

    private func stopAll() {
        task?.cancel()
        cancelContinuation()
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
        var instance = try await auth.authorized(profile: profile, credentials: credentials) { credentials in
            try await ec2.resolveInstance(tagKey: profile.instanceTagKey, tagValue: profile.instanceTagValue,
                                         region: profile.resourceRegion, credentials: credentials)
        }
                try Task.checkCancellation()
        guard !instance.state.isTerminal else { throw EC2Error.instanceTerminated(instanceId: instance.id) }
        if instance.state != .running {
            let instanceID = instance.id
            instance = try await auth.authorized(profile: profile, credentials: credentials) { credentials in
                try await ec2.startInstance(instanceId: instanceID, region: profile.resourceRegion, credentials: credentials)
                return try await ec2.pollUntilRunning(instanceId: instanceID, region: profile.resourceRegion,
                    credentials: credentials, timeout: .seconds(600), interval: .seconds(5))
            }
        }
        try Task.checkCancellation()
        try await auth.authorized(profile: profile, credentials: credentials) { credentials in
            try await ssm.waitForSSMOnline(instanceId: instance.id, region: profile.resourceRegion, credentials: credentials,
                                         timeout: .seconds(120), interval: .seconds(5))
        }
        try Task.checkCancellation()
        let configuredUser = configuredUser(profile)
        let user = try await auth.authorized(profile: profile, credentials: credentials) { credentials in
            configuredUser.isEmpty
                ? try await STSIdentityResolver(presigner: STSPresigner(region: profile.resourceRegion)).resolve(credentials: credentials).username
                : configuredUser
        }
        try Task.checkCancellation()
        if let path = leases[profile.id] {
            let lease = try JSONDecoder().decode(RemoteSSHLease.self, from: Data(contentsOf: path))
            guard lease == grantedLeases[profile.id] else { throw RemoteSSHError.configurationConflict }
            if try !lease.canReuse(profile: profile, instanceID: instance.id, user: user, now: now()) {
                stop(profileID: profile.id)
            }
        }
        if leases[profile.id] == nil {
            let key = try await keyGenerator.generate()
            try Task.checkCancellation()
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.privateKeyPath + ".pub")
            let directory = root.appendingPathComponent(profile.id.uuidString, isDirectory: true)
            let leaseURL = directory.appendingPathComponent("lease.json")
            guard let owner = ownerIdentity() else { throw RemoteSSHError.invalidLease }
            let lease = RemoteSSHLease(profile: profile, instanceID: instance.id, user: user, keyPath: key.privateKeyPath,
                pluginPath: pluginPath() ?? "", ownerPID: owner.pid,
                ownerLaunchDate: owner.launchDate, ownerBundleID: owner.bundleID, generation: UUID(), expiresAt: now().addingTimeInterval(24 * 60 * 60))
            try writeLease(try JSONEncoder().encode(lease), leaseURL)
            let contents = try RemoteSSHConfiguration.contents(lease: lease, leasePath: leaseURL.path,
                helperPath: helperPath(), knownHostsPath: root.appendingPathComponent("known-hosts").path)
            try setup.writeHost(contents, profileID: profile.id)
            keys[profile.id] = key
            leases[profile.id] = leaseURL
            grantedLeases[profile.id] = lease
            leaseExpiries[profile.id] = lease.expiresAt
        }
        try Task.checkCancellation()
        try await launchEditor(editor, arguments)
        editorLaunched = true
    }

    func renewAccess() {
        beginRenewal()
    }

    func checkLeaseContinuation() {
        guard let expiry = leaseExpiry else { return }
        guard expiry.timeIntervalSince(now()) <= 300 else { scheduleContinuation(); return }
        beginRenewal()
    }

    func awaitLeaseRenewal() async { await renewalTask?.value }

    private func configuredUser(_ profile: ConnectionProfile) -> String {
        profile.webForwards?.sshUser?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private func cancelContinuation() {
        renewalGeneration += 1
        continuationTask?.cancel()
        continuationTask = nil
        renewalTask?.cancel()
        renewalTask = nil
        isRenewingLease = false
    }

    private func scheduleContinuation() {
        continuationTask?.cancel()
        guard let expiry = leaseExpiry else { return }
        let delay = max(0, expiry.timeIntervalSince(now()) - 300)
        let sleep = renewalSleep
        let selected = profile
        let generation = renewalGeneration
        continuationTask = Task { [weak self] in
            do {
                try await sleep(.seconds(delay))
                try Task.checkCancellation()
                guard let self, self.profile == selected, self.renewalGeneration == generation else { return }
                self.checkLeaseContinuation()
            } catch is CancellationError { return }
            catch { self?.leaseMessage = "Editor lease renewal could not be scheduled. Use Renew Editor Access." }
        }
    }

    private func beginRenewal() {
        guard renewalTask == nil, task == nil, leases[profile.id] != nil else { return }
        continuationTask?.cancel()
        continuationTask = nil
        renewalGeneration += 1
        let generation = renewalGeneration
        let selected = profile
        isRenewingLease = true
        leaseMessage = "Renewing editor access; existing windows and channels are unchanged."
        renewalTask = Task {
            defer {
                if self.renewalGeneration == generation {
                    self.isRenewingLease = false
                    self.renewalTask = nil
                }
            }
            for attempt in 0..<3 {
                do {
                    try Task.checkCancellation()
                    let extended = try await self.renewLease(profile: selected)
                    try Task.checkCancellation()
                    guard generation == self.renewalGeneration else { return }
                    self.leaseMessage = extended ? nil
                        : "The existing editor lease deadline is already later. It was not shortened; automatic renewal remains scheduled."
                    self.scheduleContinuation()
                    return
                } catch {
                    guard generation == self.renewalGeneration, !Task.isCancelled else { return }
                    let signInRequired = AWSAuthProvider.isRejectedAuthorization(error)
                        || (self.auth as? AuthorizationSession)?.status == .signInRequired
                    if signInRequired { (self.auth as? AuthorizationSession)?.requireSignIn() }
                    let transient = !signInRequired && (error is URLError || error is StageTimeoutError)
                    if transient, attempt < 2, let expiry = self.leaseExpiry,
                       expiry.timeIntervalSince(self.now()) > Double((attempt + 1) * 30 + 60) {
                        self.leaseMessage = "Editor lease renewal is temporarily unavailable; a bounded retry is pending."
                        do { try await self.renewalSleep(.seconds((attempt + 1) * 30)) }
                        catch is CancellationError { return }
                        catch {
                            self.leaseMessage = "Editor lease retry could not be scheduled. Use Renew Editor Access."
                            return
                        }
                        continue
                    }
                    if signInRequired {
                        self.leaseMessage = "Sign In Required to renew editor access. Sign in with SSO, then use Renew Editor Access; the current lease deadline is unchanged."
                    } else if transient {
                        self.leaseMessage = "Editor lease renewal failed after bounded attempts. Check your network and use Renew Editor Access; the current deadline is unchanged."
                    } else {
                        self.leaseMessage = "Editor lease was not extended: \(error.localizedDescription) Use Renew Editor Access after resolving the error."
                    }
                    return
                }
            }
        }
    }

    private func readOwnedLease() throws -> RemoteSSHLease {
        guard let url = leases[profile.id], let owner = ownerIdentity(),
              let granted = grantedLeases[profile.id] else { throw RemoteSSHError.invalidLease }
        let data = try Data(contentsOf: url)
        guard data.count < 128 * 1024 else { throw RemoteSSHError.invalidLease }
        let lease = try JSONDecoder().decode(RemoteSSHLease.self, from: data)
        guard lease == granted else { throw RemoteSSHError.configurationConflict }
        guard lease.ownerPID == owner.pid, lease.ownerLaunchDate == owner.launchDate,
              lease.ownerBundleID == owner.bundleID else { throw RemoteSSHError.invalidLease }
        try lease.validate(path: url.path, ownerActive: lease.expiresAt > now())
        return lease
    }

    private func renewLease(profile: ConnectionProfile) async throws -> Bool {
        guard self.profile == profile, profile.remoteDevelopment?.enabled == true,
              let url = leases[profile.id] else { throw RemoteSSHError.invalidLease }
        guard setup.isInstalled else { throw RemoteSSHError.configurationConflict }
        let original = try readOwnedLease()
        guard try original.canReuse(profile: profile, instanceID: original.instanceID, user: original.user, now: now()),
              configuredUser(original.profile) == configuredUser(profile) else { throw RemoteSSHError.targetChanged }
        let originalData = try Data(contentsOf: url)
        let auth = auth
        let ec2 = ec2
        let ssm = ssm
        let date = now()
        let budget = min(60, original.expiresAt.timeIntervalSince(date))
        guard budget > 0 else { throw RemoteSSHError.invalidLease }
        try await withStageTimeout("Editor lease renewal", .seconds(budget)) {
            let credentials = try await auth.refreshIfNeeded(profile: profile)
            guard credentials.expiration > date else { throw AuthError.signInRequired }
            try Task.checkCancellation()
            let instance = try await ec2.resolveInstance(tagKey: profile.instanceTagKey, tagValue: profile.instanceTagValue,
                                                        region: profile.resourceRegion, credentials: credentials)
            guard instance.id == original.instanceID, instance.state == .running else { throw RemoteSSHError.targetChanged }
            try Task.checkCancellation()
            try await ssm.waitForSSMOnline(instanceId: instance.id, region: profile.resourceRegion, credentials: credentials,
                                         timeout: .seconds(30), interval: .seconds(5))
            let configured = profile.webForwards?.sshUser?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let user = configured.isEmpty
                ? try await STSIdentityResolver(presigner: STSPresigner(region: profile.resourceRegion)).resolve(credentials: credentials).username
                : configured
            guard user == original.user else { throw RemoteSSHError.targetChanged }
        }
        try Task.checkCancellation()
        guard self.profile == profile, leases[profile.id] == url, setup.isInstalled,
              try Data(contentsOf: url) == originalData else { throw RemoteSSHError.configurationConflict }
        let current = try readOwnedLease()
        guard current.continues(original, ownerActive: true, now: now()) else { throw RemoteSSHError.invalidLease }
        let expiry = now().addingTimeInterval(24 * 60 * 60)
        guard expiry > current.expiresAt else { return false }
        let renewed = current.extending(until: expiry)
        try writeLease(try JSONEncoder().encode(renewed), url)
        grantedLeases[profile.id] = renewed
        leaseExpiries[profile.id] = renewed.expiresAt
        return true
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