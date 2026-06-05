import Foundation

/// Abstraction over SSM readiness + session start so the connection flow can be unit-tested
/// with mocks (D1, ADR-P2). Implemented by `SSMService`; mocked by `MockSSMService`.
///
/// Uses the profile's **resource region** and the SSO-derived STS credentials.
protocol SSMProviding: Sendable {
    /// Poll `DescribeInstanceInformation` until the instance reports `PingStatus=Online` (F-08).
    /// Throws `SSMError.notOnlineInTime` on timeout.
    func waitForSSMOnline(
        instanceId: String,
        region: String,
        credentials: AWSCredentials,
        timeout: Duration,
        interval: Duration
    ) async throws

    /// Call `SSM.StartSession` with `AWS-StartPortForwardingSession` for the given ports (F-09).
    func startSession(
        instanceId: String,
        region: String,
        credentials: AWSCredentials,
        localPort: Int,
        remotePort: Int
    ) async throws -> SSMSessionResponse
}

/// Errors surfaced by `SSMService` (spec §8 edge cases).
enum SSMError: LocalizedError, Equatable {
    case notOnlineInTime(instanceId: String)
    case malformedSessionResponse

    var errorDescription: String? {
        switch self {
        case let .notOnlineInTime(id):
            "Instance \(id) is running but its SSM agent has not registered (PingStatus not Online). This can happen on first boot while cloud-init runs — wait a few minutes and retry."
        case .malformedSessionResponse:
            "SSM StartSession returned an incomplete response (missing session id, stream URL, or token)."
        }
    }
}
