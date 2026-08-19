import AWSSSM
import Testing
@testable import SSMConnectDomain
@testable import SSMConnectWorkflow
@testable import SSMConnectAWS
@testable import SSMConnectMacOS
@testable import SSMConnectUI

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

/// Session hygiene (AC-07). Live measurement on the Windows client showed AWS still reporting a
/// session as `Connected` ten seconds after the plugin was killed outright, so a crashed client
/// leaks a session until it times out. The reap is what closes that gap.
///
/// The owner filter is the part that matters most here. `DescribeSessions` filtered by target
/// returns every session against that instance from anyone in the account, and a multi-user
/// workstation is shared by design — an unfiltered reap would disconnect colleagues.
@Suite("SSMService session hygiene")
struct SSMServiceReapTests {
    private let creds = AWSCredentials.stub
    private let region = "eu-central-1"
    private let instanceId = "i-0123456789abcdef0"
    private let me = "arn:aws:sts::000000000000:assumed-role/ExampleRole/example.user"

    private func makeService(client: MockSSMClient, callerARN: String? = nil) -> SSMService {
        let arn = callerARN ?? me
        return SSMService(makeClient: { _, _ in client }, callerARN: { _, _ in arn })
    }

    private func session(id: String, owner: String) -> SSMClientTypes.Session {
        SSMClientTypes.Session(owner: owner, sessionId: id)
    }

    @Test("a session this caller owns is terminated, and counted")
    func reapsOwnSession() async throws {
        let client = MockSSMClient()
        client.describeSessionsResult = .success(DescribeSessionsOutput(
            sessions: [session(id: "s-mine", owner: me)]
        ))
        let service = makeService(client: client)

        let reaped = try await service.reapOrphanedSessions(
            instanceId: instanceId, region: region, credentials: creds)

        #expect(reaped == 1)
        #expect(client.terminateSessionInputs.compactMap(\.sessionId) == ["s-mine"])
    }

    @Test("a session belonging to someone else is never terminated")
    func leavesOtherPeoplesSessionsAlone() async throws {
        // The failure this pins is not a wrong count — it is disconnecting a colleague from a
        // shared multi-user workstation.
        let client = MockSSMClient()
        client.describeSessionsResult = .success(DescribeSessionsOutput(sessions: [
            session(id: "s-theirs", owner: "arn:aws:sts::000000000000:assumed-role/ExampleRole/other.user"),
            session(id: "s-also-theirs", owner: "arn:aws:iam::000000000000:user/someone-else"),
        ]))
        let service = makeService(client: client)

        let reaped = try await service.reapOrphanedSessions(
            instanceId: instanceId, region: region, credentials: creds)

        #expect(reaped == 0)
        #expect(client.terminateSessionInputs.isEmpty)
    }

    @Test("only this caller's sessions are terminated when both are present")
    func reapsOnlyMineFromAMixedList() async throws {
        let client = MockSSMClient()
        client.describeSessionsResult = .success(DescribeSessionsOutput(sessions: [
            session(id: "s-theirs", owner: "arn:aws:sts::000000000000:assumed-role/ExampleRole/other.user"),
            session(id: "s-mine-1", owner: me),
            session(id: "s-mine-2", owner: me),
        ]))
        let service = makeService(client: client)

        let reaped = try await service.reapOrphanedSessions(
            instanceId: instanceId, region: region, credentials: creds)

        #expect(reaped == 2)
        #expect(client.terminateSessionInputs.compactMap(\.sessionId).sorted() == ["s-mine-1", "s-mine-2"])
    }

    @Test("the query asks only for active sessions against this instance")
    func queriesActiveSessionsForTheTarget() async throws {
        let client = MockSSMClient()
        let service = makeService(client: client)

        _ = try await service.reapOrphanedSessions(
            instanceId: instanceId, region: region, credentials: creds)

        let input = try #require(client.describeSessionsInputs.first)
        #expect(input.state == .active)
        // `.targetId` is the SDK spelling; its wire value is "Target", matching the .NET client.
        #expect(input.filters?.first?.key == .targetId)
        #expect(input.filters?.first?.value == instanceId)
    }

    @Test("nothing left behind means nothing terminated")
    func noSessionsMeansNoWork() async throws {
        let client = MockSSMClient()
        let service = makeService(client: client)

        let reaped = try await service.reapOrphanedSessions(
            instanceId: instanceId, region: region, credentials: creds)

        #expect(reaped == 0)
        #expect(client.terminateSessionInputs.isEmpty)
    }

    @Test("terminateSession closes exactly the named session")
    func terminatesNamedSession() async throws {
        let client = MockSSMClient()
        let service = makeService(client: client)

        try await service.terminateSession(
            sessionId: "s-graceful", region: region, credentials: creds)

        #expect(client.terminateSessionInputs.compactMap(\.sessionId) == ["s-graceful"])
    }
}
