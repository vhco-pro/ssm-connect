import Foundation

/// In-memory `EC2Providing` test double for higher-level (state-machine) tests (C4).
/// Configure the per-method outcomes and inspect the recorded call counts/arguments.
final class MockEC2Service: EC2Providing, @unchecked Sendable {
    var resolveResult: Result<EC2Instance, Error> = .success(.stub())
    var startError: Error?
    var stopError: Error?
    var pollResult: Result<EC2Instance, Error> = .success(.stub(state: .running))

    private(set) var resolveCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var pollCount = 0
    private(set) var lastStartedInstanceId: String?
    private(set) var lastStoppedInstanceId: String?

    func resolveInstance(
        tagKey: String,
        tagValue: String,
        region: String,
        credentials: AWSCredentials
    ) async throws -> EC2Instance {
        resolveCount += 1
        return try resolveResult.get()
    }

    func startInstance(instanceId: String, region: String, credentials: AWSCredentials) async throws {
        startCount += 1
        lastStartedInstanceId = instanceId
        if let startError { throw startError }
    }

    func stopInstance(instanceId: String, region: String, credentials: AWSCredentials) async throws {
        stopCount += 1
        lastStoppedInstanceId = instanceId
        if let stopError { throw stopError }
    }

    func pollUntilRunning(
        instanceId: String,
        region: String,
        credentials: AWSCredentials,
        timeout: Duration,
        interval: Duration
    ) async throws -> EC2Instance {
        pollCount += 1
        return try pollResult.get()
    }
}

extension EC2Instance {
    /// Convenience fixture for tests and mock defaults.
    static func stub(
        id: String = "i-0123456789abcdef0",
        state: State = .stopped,
        privateIpAddress: String? = "10.0.1.42"
    ) -> EC2Instance {
        EC2Instance(id: id, state: state, privateIpAddress: privateIpAddress)
    }
}
