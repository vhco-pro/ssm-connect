import AppKit
import Darwin
import Foundation

enum RemoteSSHError: LocalizedError {
    case invalidLease, unavailable, targetChanged, invalidFolder, configurationConflict
    var errorDescription: String? {
        switch self {
        case .invalidLease: "Remote access is off or its owned session expired. Open VS Code from SSM Connect again."
        case .unavailable: "Install Visual Studio Code and Microsoft's Remote - SSH extension before opening the remote workspace."
        case .targetChanged: "The workstation identity changed. Reopen remote access from SSM Connect; no direct SSH fallback was attempted."
        case .invalidFolder: "Use an absolute remote folder path, or leave it blank to choose a folder in VS Code."
        case .configurationConflict: "The SSH setup changed independently. Nothing was overwritten; review the existing configuration."
        }
    }
}

struct RemoteSSHLease: Codable, Equatable, Sendable {
    let profile: ConnectionProfile
    let instanceID: String
    let user: String
    let keyPath: String
    let pluginPath: String
    let ownerPID: Int32
    let ownerLaunchDate: Date
    let ownerBundleID: String
    let generation: UUID
    let expiresAt: Date

    func canReuse(profile: ConnectionProfile, instanceID: String, user: String, now: Date = Date()) throws -> Bool {
        guard self.profile.id == profile.id, self.profile.accountId == profile.accountId,
              self.profile.resourceRegion == profile.resourceRegion, self.profile.ssoStartUrl == profile.ssoStartUrl,
              self.profile.ssoRegion == profile.ssoRegion, self.profile.roleName == profile.roleName,
              self.profile.instanceTagKey == profile.instanceTagKey, self.profile.instanceTagValue == profile.instanceTagValue,
              self.instanceID == instanceID, self.user == user else { throw RemoteSSHError.targetChanged }
        return expiresAt > now
    }

    func continues(_ original: RemoteSSHLease, ownerActive: Bool, now: Date = Date()) -> Bool {
        guard ownerActive, generation == original.generation,
              ownerPID == original.ownerPID, ownerBundleID == original.ownerBundleID,
              ownerLaunchDate == original.ownerLaunchDate, keyPath == original.keyPath,
              pluginPath == original.pluginPath else { return false }
        return (try? canReuse(profile: original.profile, instanceID: original.instanceID,
                              user: original.user, now: now)) == true
    }

    func extending(until expiry: Date) -> RemoteSSHLease {
        RemoteSSHLease(profile: profile, instanceID: instanceID, user: user, keyPath: keyPath,
            pluginPath: pluginPath, ownerPID: ownerPID, ownerLaunchDate: ownerLaunchDate,
            ownerBundleID: ownerBundleID, generation: generation, expiresAt: expiry)
    }

    var ownerIsActive: Bool {
        guard expiresAt > Date(), let application = NSRunningApplication(processIdentifier: ownerPID),
              !application.isTerminated, application.bundleIdentifier == ownerBundleID,
              application.launchDate == ownerLaunchDate else { return false }
        return true
    }

    func validate(path: String, ownerActive: Bool) throws {
        guard ownerActive, profile.isConfigured, ProfileEditorValidation.safeHost(user),
              instanceID.range(of: #"^i-[a-f0-9]+$"#, options: .regularExpression) != nil else {
            throw RemoteSSHError.invalidLease
        }
        let file = URL(fileURLWithPath: path)
        for candidate in [file, URL(fileURLWithPath: keyPath), URL(fileURLWithPath: keyPath + ".pub")] {
            let attributes = try FileManager.default.attributesOfItem(atPath: candidate.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  attributes[.ownerAccountID] as? UInt32 == getuid(),
                  ((attributes[.posixPermissions] as? Int ?? 0) & 0o077) == 0 else {
                throw RemoteSSHError.invalidLease
            }
        }
        guard FileManager.default.isExecutableFile(atPath: pluginPath) else { throw RemoteSSHError.invalidLease }
    }
}

enum RemoteSSHConfiguration {
    static func alias(_ id: UUID) -> String { "ssm-connect-" + id.uuidString.lowercased() }

    static func folderURI(alias: String, folder: String) throws -> String {
        guard folder.hasPrefix("/"), !folder.contains(where: \ .isNewline), !folder.contains("\0") else {
            throw RemoteSSHError.invalidFolder
        }
        var components = URLComponents()
        components.scheme = "vscode-remote"
        components.host = "ssh-remote+" + alias
        components.path = folder
        guard let url = components.url else { throw RemoteSSHError.invalidFolder }
        return url.absoluteString
    }

    static func arguments(alias: String, folder: String?) throws -> [String] {
        guard let folder, !folder.isEmpty else { return ["--new-window", "--remote", "ssh-remote+" + alias] }
        return ["--new-window", "--folder-uri", try folderURI(alias: alias, folder: folder)]
    }

    static func contents(lease: RemoteSSHLease, leasePath: String, helperPath: String, knownHostsPath: String) throws -> String {
        guard ProfileEditorValidation.safeHost(lease.user), ProfileEditorValidation.safeHost(lease.instanceID),
              [leasePath, helperPath, lease.keyPath, knownHostsPath].allSatisfy({ !$0.contains(where: \ .isNewline) }) else {
            throw RemoteSSHError.invalidLease
        }
        let host = alias(lease.profile.id)
        return ["Host \(host)", "  HostName \(lease.instanceID)", "  User \(lease.user)",
                "  IdentityFile \(optionQuote(lease.keyPath))", "  IdentitiesOnly yes", "  BatchMode yes",
                "  ForwardAgent no", "  ForwardX11 no", "  ConnectTimeout 90", "  StrictHostKeyChecking accept-new",
                "  UserKnownHostsFile \(optionQuote(knownHostsPath))", "  HostKeyAlias \(lease.instanceID)",
                "  ServerAliveInterval 30", "  ServerAliveCountMax 3",
                "  ProxyCommand \(shellQuote(helperPath)) --configuration \(shellQuote(leasePath))", ""].joined(separator: "\n")
    }

    private static func optionQuote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "%", with: "%%") + "\""
    }
    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''").replacingOccurrences(of: "%", with: "%%") + "'"
    }
}

public enum RemoteSSHProxyRuntime {
    private static func current(_ lease: RemoteSSHLease, path: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let current = try? JSONDecoder().decode(RemoteSSHLease.self, from: data) else { return false }
        return current.continues(lease, ownerActive: current.ownerIsActive)
    }

    static func authorizeChannel(_ lease: RemoteSSHLease, auth: AuthProviding = AWSAuthProvider(),
                                 ec2: EC2Providing = EC2Service(),
                                 instanceConnect: InstanceConnectProviding = InstanceConnectService(),
                                 ssm: SSMProviding = SSMService()) async throws -> SSMSessionResponse {
        let credentials = try await auth.refreshIfNeeded(profile: lease.profile)
        let instance = try await ec2.resolveInstance(tagKey: lease.profile.instanceTagKey,
            tagValue: lease.profile.instanceTagValue, region: lease.profile.resourceRegion, credentials: credentials)
        guard instance.id == lease.instanceID, instance.state == .running else { throw RemoteSSHError.targetChanged }
        let publicKey = try String(contentsOfFile: lease.keyPath + ".pub", encoding: .utf8)
        try await instanceConnect.sendPublicKey(instanceId: lease.instanceID, user: lease.user,
            publicKey: publicKey, region: lease.profile.resourceRegion, credentials: credentials)
        return try await ssm.startSSHSession(instanceId: lease.instanceID,
            region: lease.profile.resourceRegion, credentials: credentials)
    }

    public static func run(configurationPath: String) async throws -> Int32 {
        let data = try Data(contentsOf: URL(fileURLWithPath: configurationPath))
        guard data.count < 128 * 1024 else { throw RemoteSSHError.invalidLease }
        let lease = try JSONDecoder().decode(RemoteSSHLease.self, from: data)
        try lease.validate(path: configurationPath, ownerActive: lease.ownerIsActive)
        let session = try await authorizeChannel(lease)
        guard current(lease, path: configurationPath) else { throw RemoteSSHError.invalidLease }
        let request: [String: Any] = ["Target": lease.instanceID, "DocumentName": SSMService.sshDocument,
                                      "Parameters": ["portNumber": ["22"]]]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: lease.pluginPath)
        process.arguments = ["AWS_SSM_START_SESSION_RESPONSE", lease.profile.resourceRegion, "StartSession", "",
                             String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)]
        process.environment = ProcessInfo.processInfo.environment.merging([
            "AWS_SSM_START_SESSION_RESPONSE": try session.pluginSessionJSON()
        ]) { _, current in current }
        process.standardInput = FileHandle.standardInput
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        return try await waitForOwnedProcess(process, isCurrent: { current(lease, path: configurationPath) })
    }

    static func waitForOwnedProcess(_ process: Process, isCurrent: () -> Bool,
                                   pollInterval: Duration = .milliseconds(250),
                                   terminationGrace: Duration = .seconds(5)) async throws -> Int32 {
        var stopDeadline: ContinuousClock.Instant?
        do {
            while process.isRunning {
                try Task.checkCancellation()
                if !isCurrent() {
                    if stopDeadline == nil {
                        process.terminate()
                        stopDeadline = ContinuousClock.now.advanced(by: terminationGrace)
                    } else if let deadline = stopDeadline, ContinuousClock.now >= deadline {
                        kill(process.processIdentifier, SIGKILL)
                    }
                }
                try await Task.sleep(for: pollInterval)
            }
            return process.terminationStatus
        } catch {
            if process.isRunning {
                process.terminate()
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            throw error
        }
    }

    public static var failureMessage: String {
        "SSM Connect could not authorize this SSH channel. Reopen remote access from the app and check AWS sign-in.\n"
    }
}