import AWSSSM
import Testing
@testable import SSMConnect

/// Unit tests for `SSMService` with a mocked `SSMClient` (D9).
@Suite("SSMService")
struct SSMServiceTests {
    private let creds = AWSCredentials.stub
    private let region = "eu-central-1"
    private let instanceId = "i-0123456789abcdef0"

    private func makeService(client: MockSSMClient) -> SSMService {
        SSMService(makeClient: { _, _ in client })
    }

    @Test("waitForSSMOnline returns once PingStatus is Online")
    func waitOnline() async throws {
        let client = MockSSMClient()
        client.describeResults = [
            .success(SSMFixtures.describeOutput(instanceId: instanceId, pingStatus: .inactive)),
            .success(SSMFixtures.describeOutput(instanceId: instanceId, pingStatus: .online)),
        ]
        let service = makeService(client: client)

        try await service.waitForSSMOnline(
            instanceId: instanceId, region: region, credentials: creds,
            timeout: .seconds(5), interval: .milliseconds(1)
        )

        #expect(client.describeInputs.count == 2)
        // Filter targets the instance id
        let filters = client.describeInputs.first?.filters ?? []
        #expect(filters.contains { $0.key == "InstanceIds" && $0.values == [instanceId] })
    }

    @Test("waitForSSMOnline times out when never Online")
    func waitTimeout() async throws {
        let client = MockSSMClient()
        client.describeResults = [.success(SSMFixtures.describeOutput(instanceId: instanceId, pingStatus: .connectionLost))]
        let service = makeService(client: client)

        await #expect(throws: SSMError.notOnlineInTime(instanceId: instanceId)) {
            try await service.waitForSSMOnline(
                instanceId: instanceId, region: region, credentials: creds,
                timeout: .milliseconds(5), interval: .milliseconds(1)
            )
        }
    }

    @Test("startSession sends port-forward parameters and maps the response")
    func startSessionMapsResponse() async throws {
        let client = MockSSMClient()
        client.startSessionResult = .success(StartSessionOutput(
            sessionId: "sess-1", streamUrl: "wss://stream", tokenValue: "token-1"
        ))
        let service = makeService(client: client)

        let response = try await service.startSession(
            instanceId: instanceId, region: region, credentials: creds,
            localPort: 8443, remotePort: 8443
        )

        #expect(response == SSMSessionResponse(sessionId: "sess-1", streamUrl: "wss://stream", tokenValue: "token-1"))
        let input = try #require(client.startSessionInputs.first)
        #expect(input.documentName == "AWS-StartPortForwardingSession")
        #expect(input.target == instanceId)
        #expect(input.parameters?["portNumber"] == ["8443"])
        #expect(input.parameters?["localPortNumber"] == ["8443"])
    }

    @Test("startSession throws on an incomplete response")
    func startSessionMalformed() async throws {
        let client = MockSSMClient()
        client.startSessionResult = .success(StartSessionOutput(sessionId: "s", streamUrl: nil, tokenValue: "t"))
        let service = makeService(client: client)

        await #expect(throws: SSMError.malformedSessionResponse) {
            try await service.startSession(
                instanceId: instanceId, region: region, credentials: creds,
                localPort: 8443, remotePort: 8443
            )
        }
    }
}
