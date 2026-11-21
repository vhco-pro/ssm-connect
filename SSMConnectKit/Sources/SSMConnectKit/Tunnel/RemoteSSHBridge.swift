import AppKit
import Darwin
import Foundation

/// The owning-app checks a lease needs on macOS: the owner process and file ownership.
extension RemoteSSHLease {
    var ownerIsActive: Bool {
        expiresAt > Date() && ownerProcessIsActive
    }

    var ownerProcessIsActive: Bool {
        guard let application = NSRunningApplication(processIdentifier: ownerPID),
              !application.isTerminated, application.bundleIdentifier == ownerBundleID,
              application.launchDate == ownerLaunchDate else { return false }
        return true
    }

    func validate(path: String, ownerActive: Bool) throws {
        try validate(path: path, ownerActive: ownerActive, files: .posix)
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
        try lease.validate(path: configurationPath, ownerActive: lease.ownerProcessIsActive)
        let leaseURL = URL(fileURLWithPath: configurationPath)
        guard lease.expiresAt > Date() else {
            try EditorRecoveryRequest(lease: lease, reason: .expired).write(for: leaseURL)
            throw RemoteSSHError.invalidLease
        }
        let session: SSMSessionResponse
        do { session = try await authorizeChannel(lease) }
        catch {
            if let remote = error as? RemoteSSHError, case .targetChanged = remote {
                try EditorRecoveryRequest(lease: lease, reason: .targetChanged).write(for: leaseURL)
            } else if let ec2 = error as? EC2Error, case .noMatchingInstance = ec2 {
                try EditorRecoveryRequest(lease: lease, reason: .targetChanged).write(for: leaseURL)
            } else if AWSAuthProvider.isRejectedAuthorization(error) {
                try EditorRecoveryRequest(lease: lease, reason: .authorization).write(for: leaseURL)
            }
            throw error
        }
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
        "SSM Connect could not authorize this SSH channel. Check its menu for sign-in or replacement review, then use Reconnect Existing Workspace and retry the original window.\n"
    }

    public static func failureMessage(for error: Error) -> String {
        if AWSAuthProvider.isRejectedAuthorization(error) {
            return "SSM Connect needs AWS sign-in for this SSH channel. Choose Sign In with SSO in the app, then Reconnect Existing Workspace and retry the existing VS Code window. No new editor window is required.\n"
        }
        guard let error = error as? RemoteSSHError else { return failureMessage }
        switch error {
        case .targetChanged, .replacementApprovalRequired:
            return "SSM Connect refused a changed or unavailable workstation. For an expected replacement, choose Review Replacement Workstation in the app, verify the instance and user, then Continue and retry the existing VS Code window. Do not approve an unexpected target; no new editor window is required.\n"
        case .invalidLease:
            return "SSM Connect editor access is unavailable or expired. Choose Reconnect Existing Workspace in the app; if replacement review or sign-in is requested, complete that action, then retry the existing VS Code window. No new editor window is required.\n"
        case .configurationConflict:
            return "SSM Connect found independently changed or conflicting SSH setup. Review the configuration in the app before retrying; it was not overwritten. Do not clear host-key checks or edit the access lease to bypass this refusal.\n"
        default:
            return failureMessage
        }
    }
}