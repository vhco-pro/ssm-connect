import AWSSSM
import Foundation
@testable import SSMConnectDomain
@testable import SSMConnectWorkflow
@testable import SSMConnectAWS
@testable import SSMConnectMacOS
@testable import SSMConnectUI

/// Configurable `SSMClienting` double for `SSMService` unit tests.
final class MockSSMClient: SSMClienting, @unchecked Sendable {
    /// Sequence of `describeInstanceInformation` outcomes, consumed in order; the last repeats.
    var describeResults: [Result<DescribeInstanceInformationOutput, Error>] = []
    var startSessionResult: Result<StartSessionOutput, Error> =
        .success(StartSessionOutput(sessionId: "s-1", streamUrl: "wss://example", tokenValue: "tok"))

    private(set) var describeInputs: [DescribeInstanceInformationInput] = []
    private(set) var startSessionInputs: [StartSessionInput] = []
    private var describeIndex = 0

    func describeInstanceInformation(_ input: DescribeInstanceInformationInput) async throws -> DescribeInstanceInformationOutput {
        describeInputs.append(input)
        guard !describeResults.isEmpty else { return DescribeInstanceInformationOutput() }
        let result = describeResults[min(describeIndex, describeResults.count - 1)]
        describeIndex += 1
        return try result.get()
    }

    /// Sessions `describeSessions` reports, and the terminations it then receives (AC-07).
    var describeSessionsResult: Result<DescribeSessionsOutput, Error> = .success(DescribeSessionsOutput(sessions: []))
    private(set) var describeSessionsInputs: [DescribeSessionsInput] = []
    private(set) var terminateSessionInputs: [TerminateSessionInput] = []

    func describeSessions(_ input: DescribeSessionsInput) async throws -> DescribeSessionsOutput {
        describeSessionsInputs.append(input)
        return try describeSessionsResult.get()
    }

    func terminateSession(_ input: TerminateSessionInput) async throws -> TerminateSessionOutput {
        terminateSessionInputs.append(input)
        return TerminateSessionOutput(sessionId: input.sessionId)
    }

    func startSession(_ input: StartSessionInput) async throws -> StartSessionOutput {
        startSessionInputs.append(input)
        return try startSessionResult.get()
    }
}

enum SSMFixtures {
    static func describeOutput(instanceId: String, pingStatus: SSMClientTypes.PingStatus?) -> DescribeInstanceInformationOutput {
        DescribeInstanceInformationOutput(instanceInformationList: [
            SSMClientTypes.InstanceInformation(instanceId: instanceId, pingStatus: pingStatus),
        ])
    }
}
