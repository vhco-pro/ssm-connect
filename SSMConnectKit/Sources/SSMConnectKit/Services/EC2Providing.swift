import Foundation

/// Abstraction over EC2 instance resolution + lifecycle so the connection flow can be
/// unit-tested with mocks (C1, ADR-P2). Implemented by `EC2Service`; mocked by `MockEC2Service`.
///
/// Credentials and region are passed per-call (the active profile supplies the **resource
/// region**, distinct from the SSO region used by auth — B4). The instance ID is resolved
/// fresh on every connect and never persisted (F-06).
protocol EC2Providing: Sendable {
    /// Resolve exactly one instance matching `tag:<tagKey>=<tagValue>` (F-06).
    /// Throws `EC2Error.noMatchingInstance` / `.multipleMatchingInstances` otherwise.
    func resolveInstance(
        tagKey: String,
        tagValue: String,
        region: String,
        credentials: AWSCredentials
    ) async throws -> EC2Instance

    /// Start a stopped instance (F-07). No-op semantics if already running are the SDK's.
    func startInstance(
        instanceId: String,
        region: String,
        credentials: AWSCredentials
    ) async throws

    /// Stop a running instance (F-15).
    func stopInstance(
        instanceId: String,
        region: String,
        credentials: AWSCredentials
    ) async throws

    /// Poll `DescribeInstances` until the instance is `running` (F-07).
    /// Throws `.instanceTerminated` if it goes terminal, `.pendingStuck` / `.startTimedOut`
    /// on timeout depending on the last observed state.
    func pollUntilRunning(
        instanceId: String,
        region: String,
        credentials: AWSCredentials,
        timeout: Duration,
        interval: Duration
    ) async throws -> EC2Instance
}

/// Errors surfaced by `EC2Service` (spec §8 edge cases).
enum EC2Error: LocalizedError, Equatable {
    case noMatchingInstance(tagKey: String, tagValue: String)
    case multipleMatchingInstances(tagKey: String, tagValue: String, count: Int)
    case instanceTerminated(instanceId: String)
    case pendingStuck(instanceId: String)
    case startTimedOut(instanceId: String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case let .noMatchingInstance(key, value):
            "No workstation found with tag \(key)=\(value). Check the tag in Settings."
        case let .multipleMatchingInstances(key, value, count):
            "\(count) instances match tag \(key)=\(value). The tag must identify exactly one workstation."
        case let .instanceTerminated(id):
            "Workstation instance \(id) is terminated. It may need to be re-provisioned. Contact your platform team."
        case let .pendingStuck(id):
            "Instance \(id) is stuck in the pending state. Check the AWS Console."
        case let .startTimedOut(id):
            "Timed out waiting for instance \(id) to start."
        case .malformedResponse:
            "EC2 returned an instance with no ID."
        }
    }
}
