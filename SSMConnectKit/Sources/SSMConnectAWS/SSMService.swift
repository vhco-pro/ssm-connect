import AWSSSM
import Foundation
import SSMConnectDomain
import SSMConnectWorkflow

/// Default `SSMProviding` backed by `aws-sdk-swift`'s `SSMClient` (D2).
///
/// Polls SSM until the instance's agent is `Online`, then opens a port-forwarding session.
public final class SSMService: SSMProviding {
    public typealias ClientFactory = @Sendable (_ credentials: AWSCredentials, _ region: String) throws -> SSMClienting

    /// SSM document for local port forwarding (spec §6.4).
    public static let portForwardDocument = SSMDocument.portForward

    private let makeClient: ClientFactory

    public init(makeClient: @escaping ClientFactory = { try SSMClientFactory.make(credentials: $0, region: $1) }) {
        self.makeClient = makeClient
    }

    // MARK: - SSMProviding

    public func waitForSSMOnline(
        instanceId: String,
        region: String,
        credentials: AWSCredentials,
        timeout: Duration,
        interval: Duration
    ) async throws {
        let client = try makeClient(credentials, region)
        let input = DescribeInstanceInformationInput(filters: [
            .init(key: "InstanceIds", values: [instanceId]),
        ])
        let deadline = ContinuousClock.now.advanced(by: timeout)

        while ContinuousClock.now < deadline {
            let output = try await client.describeInstanceInformation(input)
            let isOnline = (output.instanceInformationList ?? [])
                .contains { $0.instanceId == instanceId && $0.pingStatus == .online }
            if isOnline { return }
            try await Task.sleep(for: interval)
        }
        throw SSMError.notOnlineInTime(instanceId: instanceId)
    }

    public func startSession(
        instanceId: String,
        region: String,
        credentials: AWSCredentials,
        localPort: Int,
        remotePort: Int
    ) async throws -> SSMSessionResponse {
        let client = try makeClient(credentials, region)
        let input = StartSessionInput(
            documentName: Self.portForwardDocument,
            parameters: [
                "portNumber": [String(remotePort)],
                "localPortNumber": [String(localPort)],
            ],
            target: instanceId
        )
        let output = try await client.startSession(input)
        guard
            let sessionId = output.sessionId,
            let streamUrl = output.streamUrl,
            let tokenValue = output.tokenValue
        else {
            throw SSMError.malformedSessionResponse
        }
        return SSMSessionResponse(sessionId: sessionId, streamUrl: streamUrl, tokenValue: tokenValue)
    }
}
