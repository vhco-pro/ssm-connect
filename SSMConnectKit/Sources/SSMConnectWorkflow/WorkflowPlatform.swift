import Foundation
import SSMConnectDomain

/// What the shared workflows need from the platform and the AWS layer that is not a service
/// port of its own. Each shell supplies one: on macOS `WorkflowPlatform.macOS` in the umbrella.
package struct WorkflowPlatform: Sendable {
    /// Ends a child process this app started, synchronously, during app quit (F-13). On macOS:
    /// SIGTERM, a 0.3 s grace, then SIGKILL.
    package var terminateChildProcess: @Sendable (Int32) -> Void
    /// A user-facing message for an error the shared rules do not describe themselves (the AWS
    /// SDK's errors on macOS), or nil to use the error's own description.
    package var describeError: @Sendable (Error) -> String?
    /// Whether AWS rejected the authorization, so the user must sign in again.
    package var isRejectedAuthorization: @Sendable (Error) -> Bool
    /// Whether AWS denied the operation for lack of permission.
    package var isPermissionDenied: @Sendable (Error) -> Bool
    /// Whether an error means the SSO credentials expired or were not accepted.
    package var isExpiredCredentials: @Sendable (Error) -> Bool
    /// The caller's Linux username, from its STS identity in the region.
    package var resolveUsername: @Sendable (AWSCredentials, String) async throws -> String
    /// A fresh presigned STS identity token for the region (the DCV and agent auth token).
    package var identityToken: @Sendable (AWSCredentials, String) throws -> String
    /// Owner-only file checks and locking for lease and recovery files.
    package var ownerOnlyFiles: OwnerOnlyFiles

    package init(terminateChildProcess: @escaping @Sendable (Int32) -> Void,
                 describeError: @escaping @Sendable (Error) -> String?,
                 isRejectedAuthorization: @escaping @Sendable (Error) -> Bool,
                 isPermissionDenied: @escaping @Sendable (Error) -> Bool,
                 isExpiredCredentials: @escaping @Sendable (Error) -> Bool,
                 resolveUsername: @escaping @Sendable (AWSCredentials, String) async throws -> String,
                 identityToken: @escaping @Sendable (AWSCredentials, String) throws -> String,
                 ownerOnlyFiles: OwnerOnlyFiles) {
        self.terminateChildProcess = terminateChildProcess
        self.describeError = describeError
        self.isRejectedAuthorization = isRejectedAuthorization
        self.isPermissionDenied = isPermissionDenied
        self.isExpiredCredentials = isExpiredCredentials
        self.resolveUsername = resolveUsername
        self.identityToken = identityToken
        self.ownerOnlyFiles = ownerOnlyFiles
    }

    /// The shared rules' own description of an error: its localized description when it has
    /// one, then the platform's, then Foundation's.
    package func describe(_ error: Error) -> String {
        if let localized = (error as? LocalizedError)?.errorDescription { return localized }
        return describeError(error) ?? error.localizedDescription
    }
}
