import Foundation
import Testing
import SSMConnectAWSClient
@testable import SSMConnectAWS
@testable import SSMConnectDomain
@testable import SSMConnectWorkflow

/// The service ports on SSM Connect's own AWS client apply the same rules the SDK-backed services
/// did (T9, and T36 for the scenarios ported when those services were removed): tag resolution,
/// state mapping, start and stop, polling deadlines, session and secret shapes, key push results.
/// Runs on macOS, Linux and Windows.
@Suite("Client services")
struct ClientServicesTests {
    final class Scripted: HTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var replies: [HTTPResponse]
        private(set) var requests: [HTTPRequest] = []
        init(_ replies: [HTTPResponse]) { self.replies = replies }
        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            lock.withLock {
                requests.append(request)
                return replies.count > 1 ? replies.removeFirst() : replies[0]
            }
        }
    }

    static let creds = AWSCredentials(accessKeyId: "AKID", secretAccessKey: "secret", sessionToken: "token",
                                      expiration: Date().addingTimeInterval(3600))
    static func xml(_ body: String) -> HTTPResponse {
        HTTPResponse(status: 200, headers: [("Content-Type", "text/xml")], body: Data(body.utf8))
    }
    static func json(_ status: Int, _ body: String) -> HTTPResponse {
        HTTPResponse(status: status, headers: [("Content-Type", "application/x-amz-json-1.1")], body: Data(body.utf8))
    }
    static func instances(_ items: [(String, String)]) -> HTTPResponse {
        let entries = items.map { "<item><instanceId>\($0.0)</instanceId><instanceState><name>\($0.1)</name></instanceState><privateIpAddress>10.0.0.1</privateIpAddress></item>" }.joined()
        return xml("<DescribeInstancesResponse><reservationSet><item><instancesSet>\(entries)</instancesSet></item></reservationSet></DescribeInstancesResponse>")
    }
    static func clients(_ transport: Scripted) -> AWSClientFactory { AWSClientFactory(transport: transport) }

    @Test("Resolving by tag returns the one match and maps its state")
    func resolveOne() async throws {
        let transport = Scripted([Self.instances([("i-0abc", "stopped")])])
        let instance = try await ClientEC2Service(clients: Self.clients(transport))
            .resolveInstance(tagKey: "Name", tagValue: "ws", region: "eu-central-1", credentials: Self.creds)
        #expect(instance == EC2Instance(id: "i-0abc", state: .stopped, privateIpAddress: "10.0.0.1"))
        let form = String(decoding: transport.requests[0].body, as: UTF8.self)
        #expect(form.contains("Filter.1.Name=tag%3AName") && form.contains("Filter.2.Value.4=stopped"))
    }

    @Test("No match and several matches are the SDK service's errors")
    func resolveCounts() async {
        await #expect(throws: EC2Error.noMatchingInstance(tagKey: "Name", tagValue: "ws")) {
            _ = try await ClientEC2Service(clients: Self.clients(Scripted([Self.instances([])])))
                .resolveInstance(tagKey: "Name", tagValue: "ws", region: "eu-central-1", credentials: Self.creds)
        }
        await #expect(throws: EC2Error.multipleMatchingInstances(tagKey: "Name", tagValue: "ws", count: 2)) {
            _ = try await ClientEC2Service(clients: Self.clients(Scripted([Self.instances([("i-1", "running"), ("i-2", "running")])])))
                .resolveInstance(tagKey: "Name", tagValue: "ws", region: "eu-central-1", credentials: Self.creds)
        }
    }

    @Test("Polling returns once running and reports a terminated instance")
    func polling() async throws {
        let running = try await ClientEC2Service(clients: Self.clients(Scripted([Self.instances([("i-1", "pending")]), Self.instances([("i-1", "running")])])))
            .pollUntilRunning(instanceId: "i-1", region: "eu-central-1", credentials: Self.creds, timeout: .seconds(5), interval: .milliseconds(1))
        #expect(running.state == .running)
        await #expect(throws: EC2Error.instanceTerminated(instanceId: "i-1")) {
            _ = try await ClientEC2Service(clients: Self.clients(Scripted([Self.instances([("i-1", "shutting-down")])])))
                .pollUntilRunning(instanceId: "i-1", region: "eu-central-1", credentials: Self.creds, timeout: .seconds(5), interval: .milliseconds(1))
        }
    }

    @Test("Start and stop send the instance's ID")
    func startStop() async throws {
        let transport = Scripted([Self.xml("<StartInstancesResponse/>"), Self.xml("<StopInstancesResponse/>")])
        let service = ClientEC2Service(clients: Self.clients(transport))
        try await service.startInstance(instanceId: "i-0abc", region: "eu-central-1", credentials: Self.creds)
        try await service.stopInstance(instanceId: "i-0abc", region: "eu-central-1", credentials: Self.creds)
        let forms = transport.requests.map { String(decoding: $0.body, as: UTF8.self) }
        #expect(forms[0].contains("Action=StartInstances") && forms[0].contains("InstanceId.1=i-0abc"))
        #expect(forms[1].contains("Action=StopInstances") && forms[1].contains("InstanceId.1=i-0abc"))
    }

    @Test("An instance still pending past the deadline is reported as stuck")
    func pendingStuck() async {
        await #expect(throws: EC2Error.pendingStuck(instanceId: "i-1")) {
            _ = try await ClientEC2Service(clients: Self.clients(Scripted([Self.instances([("i-1", "pending")])])))
                .pollUntilRunning(instanceId: "i-1", region: "eu-central-1", credentials: Self.creds, timeout: .milliseconds(5), interval: .milliseconds(1))
        }
    }

    @Test("An SSH session uses AWS-StartSSHSession and port 22 without DCV parameters")
    func sshSession() async throws {
        let transport = Scripted([Self.json(200, #"{"SessionId":"s-1","StreamUrl":"wss://x","TokenValue":"t"}"#)])
        let response = try await ClientSSMService(clients: Self.clients(transport))
            .startSSHSession(instanceId: "i-1", region: "eu-central-1", credentials: Self.creds)
        #expect(response.sessionId == "s-1")
        let body = try JSONSerialization.jsonObject(with: transport.requests[0].body) as? [String: Any]
        #expect(body?["DocumentName"] as? String == "AWS-StartSSHSession")
        #expect(body?["Target"] as? String == "i-1")
        #expect((body?["Parameters"] as? [String: [String]]) == ["portNumber": ["22"]])
    }

    @Test("A session response missing a field is malformed, as the SDK service reported it")
    func incompleteSession() async {
        await #expect(throws: SSMError.malformedSessionResponse) {
            _ = try await ClientSSMService(clients: Self.clients(Scripted([Self.json(200, #"{"SessionId":"s","TokenValue":"t"}"#)])))
                .startSession(instanceId: "i-1", region: "eu-central-1", credentials: Self.creds, localPort: 8443, remotePort: 8443)
        }
    }

    @Test("SSM online gives up at its deadline and asks about the instance by ID")
    func onlineTimeout() async throws {
        let transport = Scripted([Self.json(200, #"{"InstanceInformationList":[{"InstanceId":"i-1","PingStatus":"ConnectionLost"}]}"#)])
        await #expect(throws: SSMError.notOnlineInTime(instanceId: "i-1")) {
            try await ClientSSMService(clients: Self.clients(transport))
                .waitForSSMOnline(instanceId: "i-1", region: "eu-central-1", credentials: Self.creds, timeout: .milliseconds(5), interval: .milliseconds(1))
        }
        let body = try JSONSerialization.jsonObject(with: transport.requests[0].body) as? [String: Any]
        let filters = body?["Filters"] as? [[String: Any]]
        #expect(filters?.contains { $0["Key"] as? String == "InstanceIds" && $0["Values"] as? [String] == ["i-1"] } == true)
    }

    @Test("A binary-only secret, with no secret string, is empty")
    func binarySecret() async {
        await #expect(throws: SecretsError.empty(secretId: "dcv")) {
            _ = try await ClientSecretsService(clients: Self.clients(Scripted([Self.json(200, #"{"SecretBinary":"AAEC"}"#)])))
                .fetchSecret(secretId: "dcv", region: "eu-central-1", credentials: Self.creds)
        }
    }

    @Test("A port-forward session sends both ports and returns the plugin's fields")
    func session() async throws {
        let transport = Scripted([Self.json(200, #"{"SessionId":"s","StreamUrl":"wss://x","TokenValue":"t"}"#)])
        let response = try await ClientSSMService(clients: Self.clients(transport))
            .startSession(instanceId: "i-1", region: "eu-central-1", credentials: Self.creds, localPort: 18443, remotePort: 8443)
        #expect(response == SSMSessionResponse(sessionId: "s", streamUrl: "wss://x", tokenValue: "t"))
        let body = try JSONSerialization.jsonObject(with: transport.requests[0].body) as? [String: Any]
        #expect(body?["DocumentName"] as? String == "AWS-StartPortForwardingSession")
        #expect((body?["Parameters"] as? [String: [String]]) == ["portNumber": ["8443"], "localPortNumber": ["18443"]])
    }

    @Test("SSM online waits for PingStatus Online")
    func online() async throws {
        let transport = Scripted([Self.json(200, #"{"InstanceInformationList":[{"InstanceId":"i-1","PingStatus":"ConnectionLost"}]}"#),
                                  Self.json(200, #"{"InstanceInformationList":[{"InstanceId":"i-1","PingStatus":"Online"}]}"#)])
        try await ClientSSMService(clients: Self.clients(transport))
            .waitForSSMOnline(instanceId: "i-1", region: "eu-central-1", credentials: Self.creds, timeout: .seconds(5), interval: .milliseconds(1))
        #expect(transport.requests.count == 2)
    }

    @Test("A missing secret and an empty secret are the SDK service's errors")
    func secrets() async {
        await #expect(throws: SecretsError.notFound(secretId: "dcv")) {
            _ = try await ClientSecretsService(clients: Self.clients(Scripted([Self.json(400, #"{"__type":"ResourceNotFoundException","message":"no"}"#)])))
                .fetchSecret(secretId: "dcv", region: "eu-central-1", credentials: Self.creds)
        }
        await #expect(throws: SecretsError.empty(secretId: "dcv")) {
            _ = try await ClientSecretsService(clients: Self.clients(Scripted([Self.json(200, #"{"SecretString":""}"#)])))
                .fetchSecret(secretId: "dcv", region: "eu-central-1", credentials: Self.creds)
        }
    }

    @Test("A refused or failed key push is keyPushFailed")
    func keyPush() async {
        for reply in [Self.json(200, #"{"Success":false}"#), Self.json(400, #"{"__type":"AuthException","message":"no"}"#)] {
            await #expect(throws: WebForwardsError.self) {
                try await ClientInstanceConnectService(clients: Self.clients(Scripted([reply])))
                    .sendPublicKey(instanceId: "i-1", user: "u", publicKey: "k", region: "eu-central-1", credentials: Self.creds)
            }
        }
    }

    @Test("Service errors render as the app renders them")
    func errorText() {
        #expect(AWSErrorText.message(for: AWSServiceError(typeName: "AccessDeniedException", message: "No access", httpStatus: 400))
                == "No access (AccessDeniedException, HTTP 400)")
        #expect(AWSErrorText.message(for: AWSServiceError(typeName: "Throttling", message: nil, httpStatus: 400))
                == "AWS returned a Throttling.")
    }
}
