import AppKit
import Darwin
import Foundation
import SSMConnectAWS
import SSMConnectDomain
import SSMConnectWorkflow

/// The app as lease owner on macOS: the running application with the recorded PID, bundle ID
/// and launch date.
package struct ApplicationLeaseOwner: LeaseOwnerProbing {
    package init() {}

    package func current() -> LeaseOwnerIdentity? {
        guard let launchDate = NSRunningApplication.current.launchDate,
              let bundleID = NSRunningApplication.current.bundleIdentifier else { return nil }
        return LeaseOwnerIdentity(pid: NSRunningApplication.current.processIdentifier, launchDate: launchDate, bundleID: bundleID)
    }

    package func isActive(_ owner: LeaseOwnerIdentity) -> Bool {
        guard let application = NSRunningApplication(processIdentifier: owner.pid),
              !application.isTerminated, application.bundleIdentifier == owner.bundleID,
              application.launchDate == owner.launchDate else { return false }
        return true
    }
}

/// The owning-app checks a lease needs on macOS: the owner process and file ownership.
extension RemoteSSHLease {
    package var ownerIsActive: Bool {
        expiresAt > Date() && ownerProcessIsActive
    }

    package var ownerProcessIsActive: Bool { ApplicationLeaseOwner().isActive(owner) }

    package func validate(path: String, ownerActive: Bool) throws {
        try validate(path: path, ownerActive: ownerActive, files: .posix)
    }
}

public enum RemoteSSHProxyRuntime {
    /// The shared editor proxy with the macOS owner, files and AWS services.
    static func proxy(auth: AuthProviding = ClientAuthProvider(openURL: { url in Task { @MainActor in NSWorkspace.shared.open(url) } }), ec2: EC2Providing = ClientEC2Service(),
                      instanceConnect: InstanceConnectProviding = ClientInstanceConnectService(),
                      ssm: SSMProviding = ClientSSMService()) -> EditorProxy {
        EditorProxy(owner: ApplicationLeaseOwner(), files: .posix, auth: auth, ec2: ec2, ssm: ssm,
                    instanceConnect: instanceConnect,
                    isRejectedAuthorization: { ClientAuthProvider.isRejectedAuthorization($0) },
                    forceTerminate: { kill($0.processIdentifier, SIGKILL) })
    }

    package static func authorizeChannel(_ lease: RemoteSSHLease, auth: AuthProviding = ClientAuthProvider(openURL: { url in Task { @MainActor in NSWorkspace.shared.open(url) } }),
                                 ec2: EC2Providing = ClientEC2Service(),
                                 instanceConnect: InstanceConnectProviding = ClientInstanceConnectService(),
                                 ssm: SSMProviding = ClientSSMService()) async throws -> SSMSessionResponse {
        try await proxy(auth: auth, ec2: ec2, instanceConnect: instanceConnect, ssm: ssm).authorizeChannel(lease)
    }

    public static func run(configurationPath: String) async throws -> Int32 {
        try await proxy().run(configurationPath: configurationPath)
    }

    package static func waitForOwnedProcess(_ process: Process, isCurrent: () -> Bool,
                                            pollInterval: Duration = .milliseconds(250),
                                            terminationGrace: Duration = .seconds(5)) async throws -> Int32 {
        try await proxy().waitForOwnedProcess(process, isCurrent: isCurrent, pollInterval: pollInterval,
                                              terminationGrace: terminationGrace)
    }

    public static var failureMessage: String { EditorProxy.failureMessage }

    public static func failureMessage(for error: Error) -> String {
        EditorProxy.failureMessage(for: error, isRejectedAuthorization: { ClientAuthProvider.isRejectedAuthorization($0) })
    }
}
