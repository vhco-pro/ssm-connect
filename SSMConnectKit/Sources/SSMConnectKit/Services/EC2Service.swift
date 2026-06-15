import AWSEC2
import Foundation

/// Default `EC2Providing` backed by `aws-sdk-swift`'s `EC2Client` (C2, C3).
///
/// Resolves the workstation by tag, starts it if stopped, and polls until it is `running`.
/// All operations use the profile's **resource region** and the SSO-derived STS credentials.
final class EC2Service: EC2Providing {
    typealias ClientFactory = @Sendable (_ credentials: AWSCredentials, _ region: String) throws -> EC2Clienting

    private let makeClient: ClientFactory

    init(makeClient: @escaping ClientFactory = { try EC2ClientFactory.make(credentials: $0, region: $1) }) {
        self.makeClient = makeClient
    }

    // MARK: - EC2Providing

    func resolveInstance(
        tagKey: String,
        tagValue: String,
        region: String,
        credentials: AWSCredentials
    ) async throws -> EC2Instance {
        let client = try makeClient(credentials, region)
        // F-06: filter by tag + the states a resolvable workstation can be in.
        let input = DescribeInstancesInput(filters: [
            .init(name: "tag:\(tagKey)", values: [tagValue]),
            .init(name: "instance-state-name", values: ["pending", "running", "stopping", "stopped"]),
        ])
        let output = try await client.describeInstances(input)
        let instances = (output.reservations ?? []).flatMap { $0.instances ?? [] }

        guard !instances.isEmpty else {
            throw EC2Error.noMatchingInstance(tagKey: tagKey, tagValue: tagValue)
        }
        guard instances.count == 1 else {
            throw EC2Error.multipleMatchingInstances(tagKey: tagKey, tagValue: tagValue, count: instances.count)
        }
        return try Self.domain(from: instances[0])
    }

    func startInstance(instanceId: String, region: String, credentials: AWSCredentials) async throws {
        let client = try makeClient(credentials, region)
        _ = try await client.startInstances(StartInstancesInput(instanceIds: [instanceId]))
    }

    func stopInstance(instanceId: String, region: String, credentials: AWSCredentials) async throws {
        let client = try makeClient(credentials, region)
        _ = try await client.stopInstances(StopInstancesInput(instanceIds: [instanceId]))
    }

    func pollUntilRunning(
        instanceId: String,
        region: String,
        credentials: AWSCredentials,
        timeout: Duration,
        interval: Duration
    ) async throws -> EC2Instance {
        let client = try makeClient(credentials, region)
        let deadline = ContinuousClock.now.advanced(by: timeout)
        var lastState: EC2Instance.State = .pending

        while ContinuousClock.now < deadline {
            let instance = try await describeOne(client: client, instanceId: instanceId)
            lastState = instance.state
            switch instance.state {
            case .running:
                return instance
            case .terminated, .shuttingDown:
                throw EC2Error.instanceTerminated(instanceId: instanceId)
            case .pending, .stopping, .stopped, .unknown:
                break  // keep polling
            }
            try await Task.sleep(for: interval)
        }
        // Timed out: distinguish a stuck-pending instance from a generic start timeout (spec §8).
        throw lastState == .pending
            ? EC2Error.pendingStuck(instanceId: instanceId)
            : EC2Error.startTimedOut(instanceId: instanceId)
    }

    // MARK: - Helpers

    private func describeOne(client: EC2Clienting, instanceId: String) async throws -> EC2Instance {
        let output = try await client.describeInstances(DescribeInstancesInput(instanceIds: [instanceId]))
        guard let instance = (output.reservations ?? []).flatMap({ $0.instances ?? [] }).first else {
            throw EC2Error.noMatchingInstance(tagKey: "instance-id", tagValue: instanceId)
        }
        return try Self.domain(from: instance)
    }

    private static func domain(from instance: EC2ClientTypes.Instance) throws -> EC2Instance {
        guard let id = instance.instanceId else { throw EC2Error.malformedResponse }
        return EC2Instance(
            id: id,
            state: state(from: instance.state?.name),
            privateIpAddress: instance.privateIpAddress
        )
    }

    private static func state(from name: EC2ClientTypes.InstanceStateName?) -> EC2Instance.State {
        switch name {
        case .pending:      .pending
        case .running:      .running
        case .shuttingDown: .shuttingDown
        case .stopped:      .stopped
        case .stopping:     .stopping
        case .terminated:   .terminated
        default:            .unknown
        }
    }
}
