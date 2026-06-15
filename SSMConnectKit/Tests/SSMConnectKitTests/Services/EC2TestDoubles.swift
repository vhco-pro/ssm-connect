import AWSEC2
import Foundation
@testable import SSMConnectKit

/// Configurable `EC2Clienting` double for `EC2Service` unit tests (C5).
final class MockEC2Client: EC2Clienting, @unchecked Sendable {
    /// Sequence of `describeInstances` outcomes, consumed in order; the last repeats.
    var describeResults: [Result<DescribeInstancesOutput, Error>] = []
    var startResult: Result<StartInstancesOutput, Error> = .success(StartInstancesOutput())
    var stopResult: Result<StopInstancesOutput, Error> = .success(StopInstancesOutput())

    private(set) var describeInputs: [DescribeInstancesInput] = []
    private(set) var startInputs: [StartInstancesInput] = []
    private(set) var stopInputs: [StopInstancesInput] = []
    private var describeIndex = 0

    func describeInstances(_ input: DescribeInstancesInput) async throws -> DescribeInstancesOutput {
        describeInputs.append(input)
        guard !describeResults.isEmpty else { return DescribeInstancesOutput() }
        let result = describeResults[min(describeIndex, describeResults.count - 1)]
        describeIndex += 1
        return try result.get()
    }

    func startInstances(_ input: StartInstancesInput) async throws -> StartInstancesOutput {
        startInputs.append(input)
        return try startResult.get()
    }

    func stopInstances(_ input: StopInstancesInput) async throws -> StopInstancesOutput {
        stopInputs.append(input)
        return try stopResult.get()
    }
}

enum EC2Fixtures {
    /// Build a `DescribeInstancesOutput` describing `instances` in a single reservation.
    static func output(_ instances: [(id: String, state: EC2ClientTypes.InstanceStateName, ip: String?)]) -> DescribeInstancesOutput {
        let modeled = instances.map { tuple in
            EC2ClientTypes.Instance(
                instanceId: tuple.id,
                privateIpAddress: tuple.ip,
                state: EC2ClientTypes.InstanceState(name: tuple.state)
            )
        }
        return DescribeInstancesOutput(reservations: [EC2ClientTypes.Reservation(instances: modeled)])
    }
}
