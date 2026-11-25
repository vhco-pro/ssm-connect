import Foundation
import SSMConnectDomain

/// In-memory `EC2Providing` test double for higher-level (state-machine) tests (C4).
/// Configure the per-method outcomes and inspect the recorded call counts/arguments.
package final class MockEC2Service: EC2Providing, @unchecked Sendable {
    package var resolveResult: Result<EC2Instance, Error> = .success(.stub())
    /// Holds instance resolution this long, so a test can act while a workflow waits on it.
    package var resolveDelay: Duration?
    package var startError: Error?
    package var stopError: Error?
    package var pollResult: Result<EC2Instance, Error> = .success(.stub(state: .running))

    package private(set) var resolveCount = 0
    package private(set) var startCount = 0
    package private(set) var stopCount = 0
    package private(set) var pollCount = 0
    package private(set) var lastStartedInstanceId: String?
    package private(set) var lastStoppedInstanceId: String?

    package func resolveInstance(
        tagKey: String,
        tagValue: String,
        region: String,
        credentials: AWSCredentials
    ) async throws -> EC2Instance {
        resolveCount += 1
        if let resolveDelay { try await Task.sleep(for: resolveDelay) }
        return try resolveResult.get()
    }

    package func startInstance(instanceId: String, region: String, credentials: AWSCredentials) async throws {
        startCount += 1
        lastStartedInstanceId = instanceId
        if let startError { throw startError }
    }

    package func stopInstance(instanceId: String, region: String, credentials: AWSCredentials) async throws {
        stopCount += 1
        lastStoppedInstanceId = instanceId
        if let stopError { throw stopError }
    }

    package func pollUntilRunning(
        instanceId: String,
        region: String,
        credentials: AWSCredentials,
        timeout: Duration,
        interval: Duration
    ) async throws -> EC2Instance {
        pollCount += 1
        return try pollResult.get()
    }

    package init() {}
}

extension EC2Instance {
    /// Convenience fixture for tests and mock defaults.
    package static func stub(
        id: String = "i-0123456789abcdef0",
        state: State = .stopped,
        privateIpAddress: String? = "10.0.1.42"
    ) -> EC2Instance {
        EC2Instance(id: id, state: state, privateIpAddress: privateIpAddress)
    }
}
