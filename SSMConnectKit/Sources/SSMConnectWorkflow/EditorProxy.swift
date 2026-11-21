import Foundation
import SSMConnectDomain

/// The editor's SSH proxy, which VS Code's SSH runs as ProxyCommand with a lease file. Before any
/// AWS call it validates the lease (owner-only files, a live owner, the owner's build, an
/// unexpired lease); then it authorizes the channel (credentials through the owner's SSO cache,
/// the same instance still running, the lease's key pushed) and runs the plugin on its own stdin
/// and stdout until the plugin ends, ending it once the lease stops being current. Each platform
/// supplies the owner port, its private files and the AWS services.
package struct EditorProxy {
    package var owner: LeaseOwnerProbing
    package var files: OwnerOnlyFiles
    package var auth: AuthProviding
    package var ec2: EC2Providing
    package var ssm: SSMProviding
    package var instanceConnect: InstanceConnectProviding
    package var isRejectedAuthorization: @Sendable (Error) -> Bool
    /// Ends a child process that ignored termination.
    package var forceTerminate: @Sendable (Process) -> Void
    package var build: String
    package var now: @Sendable () -> Date

    package init(owner: LeaseOwnerProbing, files: OwnerOnlyFiles, auth: AuthProviding, ec2: EC2Providing, ssm: SSMProviding,
                 instanceConnect: InstanceConnectProviding, isRejectedAuthorization: @escaping @Sendable (Error) -> Bool,
                 forceTerminate: @escaping @Sendable (Process) -> Void, build: String = InstalledBuild.current,
                 now: @escaping @Sendable () -> Date = { Date() }) {
        self.owner = owner
        self.files = files
        self.auth = auth
        self.ec2 = ec2
        self.ssm = ssm
        self.instanceConnect = instanceConnect
        self.isRejectedAuthorization = isRejectedAuthorization
        self.forceTerminate = forceTerminate
        self.build = build
        self.now = now
    }

    /// Validates the lease at `configurationPath` and returns it, refusing before any AWS call.
    package func admit(configurationPath: String) throws -> RemoteSSHLease {
        let data = try Data(contentsOf: URL(fileURLWithPath: configurationPath))
        guard data.count < 128 * 1024 else { throw RemoteSSHError.invalidLease }
        let lease = try JSONDecoder().decode(RemoteSSHLease.self, from: data)
        try lease.validate(path: configurationPath, ownerActive: owner.isActive(lease.owner), files: files)
        // A proxy of another build than the lease's owner refuses before any AWS call (AC-17).
        try lease.requireSameBuild(build)
        guard lease.expiresAt > now() else {
            try EditorRecoveryRequest(lease: lease, reason: .expired).write(for: URL(fileURLWithPath: configurationPath))
            throw RemoteSSHError.invalidLease
        }
        return lease
    }

    package func authorizeChannel(_ lease: RemoteSSHLease) async throws -> SSMSessionResponse {
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

    /// Runs the proxy for VS Code and returns the plugin's exit status.
    package func run(configurationPath: String) async throws -> Int32 {
        let lease = try admit(configurationPath: configurationPath)
        let leaseURL = URL(fileURLWithPath: configurationPath)
        let session: SSMSessionResponse
        do { session = try await authorizeChannel(lease) }
        catch {
            if let remote = error as? RemoteSSHError, case .targetChanged = remote {
                try EditorRecoveryRequest(lease: lease, reason: .targetChanged).write(for: leaseURL)
            } else if let ec2 = error as? EC2Error, case .noMatchingInstance = ec2 {
                try EditorRecoveryRequest(lease: lease, reason: .targetChanged).write(for: leaseURL)
            } else if isRejectedAuthorization(error) {
                try EditorRecoveryRequest(lease: lease, reason: .authorization).write(for: leaseURL)
            }
            throw error
        }
        guard isCurrent(lease, path: configurationPath) else { throw RemoteSSHError.invalidLease }
        let request: [String: Any] = ["Target": lease.instanceID, "DocumentName": SSHArguments.sshDocument,
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
        return try await waitForOwnedProcess(process, isCurrent: { isCurrent(lease, path: configurationPath) })
    }

    /// Whether the lease file still holds this lease, renewed or not, with its owner alive.
    package func isCurrent(_ lease: RemoteSSHLease, path: String) -> Bool {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let current = try? JSONDecoder().decode(RemoteSSHLease.self, from: data) else { return false }
        let active = current.expiresAt > now() && owner.isActive(current.owner)
        return current.continues(lease, ownerActive: active, now: now())
    }

    /// Waits for the plugin, terminating it once the lease is no longer current and forcing it
    /// after the grace period.
    package func waitForOwnedProcess(_ process: Process, isCurrent: () -> Bool,
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
                        forceTerminate(process)
                    }
                }
                try await Task.sleep(for: pollInterval)
            }
            return process.terminationStatus
        } catch {
            if process.isRunning {
                process.terminate()
                if process.isRunning { forceTerminate(process) }
            }
            throw error
        }
    }

    package static var failureMessage: String {
        "SSM Connect could not authorize this SSH channel. Check its menu for sign-in or replacement review, then use Reconnect Existing Workspace and retry the original window.\n"
    }

    package static func failureMessage(for error: Error, isRejectedAuthorization: (Error) -> Bool) -> String {
        if isRejectedAuthorization(error) {
            return "SSM Connect needs AWS sign-in for this SSH channel. Choose Sign In with SSO in the app, then Reconnect Existing Workspace and retry the existing VS Code window. No new editor window is required.\n"
        }
        guard let error = error as? RemoteSSHError else { return failureMessage }
        switch error {
        case .targetChanged, .replacementApprovalRequired:
            return "SSM Connect refused a changed or unavailable workstation. For an expected replacement, choose Review Replacement Workstation in the app, verify the instance and user, then Continue and retry the existing VS Code window. Do not approve an unexpected target; no new editor window is required.\n"
        case .updated:
            return "SSM Connect was updated; restart it.\n"
        case .invalidLease:
            return "SSM Connect editor access is unavailable or expired. Choose Reconnect Existing Workspace in the app; if replacement review or sign-in is requested, complete that action, then retry the existing VS Code window. No new editor window is required.\n"
        case .configurationConflict:
            return "SSM Connect found independently changed or conflicting SSH setup. Review the configuration in the app before retrying; it was not overwritten. Do not clear host-key checks or edit the access lease to bypass this refusal.\n"
        default:
            return failureMessage
        }
    }
}
