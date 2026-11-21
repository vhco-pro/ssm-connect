import Foundation
import SSMConnectDomain

package enum RemoteSSHError: LocalizedError {
    case invalidLease, unavailable, targetChanged, invalidFolder, configurationConflict
    case invalidRecoveryState, replacementApprovalRequired, workstationNotReady
    package var errorDescription: String? {
        switch self {
        case .invalidLease: "Remote access is off or its owned session expired. Open VS Code from SSM Connect again."
        case .unavailable: "Install Visual Studio Code and Microsoft's Remote - SSH extension before opening the remote workspace."
        case .targetChanged: "The workstation identity changed. Reopen remote access from SSM Connect; no direct SSH fallback was attempted."
        case .invalidFolder: "Use an absolute remote folder path, or leave it blank to choose a folder in VS Code."
        case .configurationConflict: "The SSH setup changed independently. Nothing was overwritten; review the existing configuration."
        case .invalidRecoveryState: "Saved editor recovery state is invalid. Existing access was not replaced; review the profile and recovery settings."
        case .replacementApprovalRequired: "A different workstation instance requires confirmation in SSM Connect before this workspace can reconnect."
        case .workstationNotReady: "The workstation is not ready. Recovery can wait without starting or replacing it."
        }
    }
}

package struct RemoteSSHLease: Codable, Equatable, Sendable {
    package let profile: ConnectionProfile
    package let instanceID: String
    package let user: String
    package let keyPath: String
    package let pluginPath: String
    package let ownerPID: Int32
    package let ownerLaunchDate: Date
    package let ownerBundleID: String
    package let generation: UUID
    package let expiresAt: Date

    package func canReuse(profile: ConnectionProfile, instanceID: String, user: String, now: Date = Date()) throws -> Bool {
        guard self.profile.hasSameWorkstation(as: profile),
              self.instanceID == instanceID, self.user == user else { throw RemoteSSHError.targetChanged }
        return expiresAt > now
    }

    package func continues(_ original: RemoteSSHLease, ownerActive: Bool, now: Date = Date()) -> Bool {
        guard ownerActive, generation == original.generation,
              ownerPID == original.ownerPID, ownerBundleID == original.ownerBundleID,
              ownerLaunchDate == original.ownerLaunchDate, keyPath == original.keyPath,
              pluginPath == original.pluginPath else { return false }
        return (try? canReuse(profile: original.profile, instanceID: original.instanceID,
                              user: original.user, now: now)) == true
    }

    package func extending(until expiry: Date) -> RemoteSSHLease {
        RemoteSSHLease(profile: profile, instanceID: instanceID, user: user, keyPath: keyPath,
            pluginPath: pluginPath, ownerPID: ownerPID, ownerLaunchDate: ownerLaunchDate,
            ownerBundleID: ownerBundleID, generation: generation, expiresAt: expiry)
    }

    package func validate(path: String, ownerActive: Bool, files: OwnerOnlyFiles) throws {
        guard ownerActive, profile.isConfigured, ProfileEditorValidation.safeHost(user),
              instanceID.range(of: #"^i-[a-f0-9]+$"#, options: .regularExpression) != nil else {
            throw RemoteSSHError.invalidLease
        }
        let file = URL(fileURLWithPath: path)
        for candidate in [file, URL(fileURLWithPath: keyPath), URL(fileURLWithPath: keyPath + ".pub")] {
            let attributes = try FileManager.default.attributesOfItem(atPath: candidate.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular, files.isOwnerOnly(attributes) else {
                throw RemoteSSHError.invalidLease
            }
        }
        guard FileManager.default.isExecutableFile(atPath: pluginPath) else { throw RemoteSSHError.invalidLease }
    }

    package init(profile: ConnectionProfile, instanceID: String, user: String, keyPath: String, pluginPath: String, ownerPID: Int32, ownerLaunchDate: Date, ownerBundleID: String, generation: UUID, expiresAt: Date) {
        self.profile = profile
        self.instanceID = instanceID
        self.user = user
        self.keyPath = keyPath
        self.pluginPath = pluginPath
        self.ownerPID = ownerPID
        self.ownerLaunchDate = ownerLaunchDate
        self.ownerBundleID = ownerBundleID
        self.generation = generation
        self.expiresAt = expiresAt
    }
}

package enum RemoteSSHConfiguration {
    package static func alias(_ id: UUID) -> String { "ssm-connect-" + id.uuidString.lowercased() }

    package static func folderURI(alias: String, folder: String) throws -> String {
        guard let uri = RemoteFolder.uri(alias: alias, folder: folder) else { throw RemoteSSHError.invalidFolder }
        return uri
    }

    package static func arguments(alias: String, folder: String?) throws -> [String] {
        guard let folder, !folder.isEmpty else { return ["--new-window", "--remote", "ssh-remote+" + alias] }
        return ["--new-window", "--folder-uri", try folderURI(alias: alias, folder: folder)]
    }

    package static func contents(lease: RemoteSSHLease, leasePath: String, helperPath: String, knownHostsPath: String) throws -> String {
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
