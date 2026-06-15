import Testing
@testable import SSMConnectKit

/// Unit tests for `EC2Service` orchestration with a mocked `EC2Client` (C5).
@Suite("EC2Service")
struct EC2ServiceTests {
    private let creds = AWSCredentials.stub
    private let tagKey = "Name"
    private let tagValue = "example-workstation"
    private let region = "eu-central-1"

    private func makeService(client: MockEC2Client) -> EC2Service {
        EC2Service(makeClient: { _, _ in client })
    }

    @Test("Resolves exactly one matching instance")
    func resolvesSingleInstance() async throws {
        let client = MockEC2Client()
        client.describeResults = [.success(EC2Fixtures.output([(id: "i-abc", state: .stopped, ip: "10.0.0.5")]))]
        let service = makeService(client: client)

        let instance = try await service.resolveInstance(
            tagKey: tagKey, tagValue: tagValue, region: region, credentials: creds
        )

        #expect(instance.id == "i-abc")
        #expect(instance.state == .stopped)
        #expect(instance.privateIpAddress == "10.0.0.5")
        // Filters: tag + instance-state-name
        let filters = client.describeInputs.first?.filters ?? []
        #expect(filters.contains { $0.name == "tag:Name" && $0.values == [tagValue] })
        #expect(filters.contains { $0.name == "instance-state-name" })
    }

    @Test("Zero matches throws noMatchingInstance")
    func zeroMatches() async throws {
        let client = MockEC2Client()
        client.describeResults = [.success(EC2Fixtures.output([]))]
        let service = makeService(client: client)

        await #expect(throws: EC2Error.noMatchingInstance(tagKey: tagKey, tagValue: tagValue)) {
            try await service.resolveInstance(tagKey: tagKey, tagValue: tagValue, region: region, credentials: creds)
        }
    }

    @Test("Multiple matches throws multipleMatchingInstances")
    func multipleMatches() async throws {
        let client = MockEC2Client()
        client.describeResults = [.success(EC2Fixtures.output([
            (id: "i-a", state: .running, ip: nil),
            (id: "i-b", state: .stopped, ip: nil),
        ]))]
        let service = makeService(client: client)

        await #expect(throws: EC2Error.multipleMatchingInstances(tagKey: tagKey, tagValue: tagValue, count: 2)) {
            try await service.resolveInstance(tagKey: tagKey, tagValue: tagValue, region: region, credentials: creds)
        }
    }

    @Test("startInstance calls StartInstances with the instance id")
    func startInstancePassesId() async throws {
        let client = MockEC2Client()
        let service = makeService(client: client)

        try await service.startInstance(instanceId: "i-xyz", region: region, credentials: creds)

        #expect(client.startInputs.count == 1)
        #expect(client.startInputs.first?.instanceIds == ["i-xyz"])
    }

    @Test("stopInstance calls StopInstances with the instance id")
    func stopInstancePassesId() async throws {
        let client = MockEC2Client()
        let service = makeService(client: client)

        try await service.stopInstance(instanceId: "i-xyz", region: region, credentials: creds)

        #expect(client.stopInputs.count == 1)
        #expect(client.stopInputs.first?.instanceIds == ["i-xyz"])
    }

    @Test("pollUntilRunning returns once the instance is running")
    func pollUntilRunningSucceeds() async throws {
        let client = MockEC2Client()
        client.describeResults = [
            .success(EC2Fixtures.output([(id: "i-abc", state: .pending, ip: nil)])),
            .success(EC2Fixtures.output([(id: "i-abc", state: .pending, ip: nil)])),
            .success(EC2Fixtures.output([(id: "i-abc", state: .running, ip: "10.0.0.9")])),
        ]
        let service = makeService(client: client)

        let instance = try await service.pollUntilRunning(
            instanceId: "i-abc", region: region, credentials: creds,
            timeout: .seconds(5), interval: .milliseconds(1)
        )

        #expect(instance.state == .running)
        #expect(instance.privateIpAddress == "10.0.0.9")
        #expect(client.describeInputs.count == 3)
    }

    @Test("pollUntilRunning throws instanceTerminated when the instance goes terminal")
    func pollUntilRunningTerminated() async throws {
        let client = MockEC2Client()
        client.describeResults = [
            .success(EC2Fixtures.output([(id: "i-abc", state: .pending, ip: nil)])),
            .success(EC2Fixtures.output([(id: "i-abc", state: .shuttingDown, ip: nil)])),
        ]
        let service = makeService(client: client)

        await #expect(throws: EC2Error.instanceTerminated(instanceId: "i-abc")) {
            try await service.pollUntilRunning(
                instanceId: "i-abc", region: region, credentials: creds,
                timeout: .seconds(5), interval: .milliseconds(1)
            )
        }
    }

    @Test("pollUntilRunning that stays pending past the deadline throws pendingStuck")
    func pollUntilRunningPendingStuck() async throws {
        let client = MockEC2Client()
        client.describeResults = [.success(EC2Fixtures.output([(id: "i-abc", state: .pending, ip: nil)]))]
        let service = makeService(client: client)

        await #expect(throws: EC2Error.pendingStuck(instanceId: "i-abc")) {
            try await service.pollUntilRunning(
                instanceId: "i-abc", region: region, credentials: creds,
                timeout: .milliseconds(5), interval: .milliseconds(1)
            )
        }
    }
}
