import Foundation
import Testing
@testable import SSMConnectAWSClient

/// Request and response parity with the pinned aws-sdk-swift (Fixtures/requests, written
/// by FixtureRecorder from the SDK operations the app calls, with the app's inputs).
///
/// Compared: method, path, query, body, Content-Type, X-Amz-Target, the session token or
/// SSO bearer token header, whether the request is signed and with which credential
/// scope, and the decoded fields the app reads. Not compared, by design: Host (the
/// recorder overrides the endpoint; EndpointParityTests covers endpoints), User-Agent,
/// amz-sdk-invocation-id and amz-sdk-request (SDK telemetry and retry bookkeeping;
/// RetryParityTests covers attempts), X-Amz-Date and the signature value (time-dependent;
/// SigV4Tests covers signing), and Content-Length (derived from the body).
@Suite("Request parity")
struct RequestParityTests {
    struct Fixture: Decodable {
        struct Request: Decodable { let method: String; let uri: String; let headers: [[String]]; let body: String }
        struct Response: Decodable { let status: Int; let headers: [[String]]; let body: String }
        let name: String
        let service: String
        let region: String
        let request: Request
        let response: Response
        let decoded: [String: String]
    }

    static let directory = Bundle.module.url(forResource: "Fixtures/requests", withExtension: nil)!

    static func fixture(_ name: String) throws -> Fixture {
        try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: directory.appendingPathComponent("\(name).json")))
    }

    static let credentials = AWSCredentialSet(
        accessKeyID: "AKIDEXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", sessionToken: "SESSIONTOKEN"
    )
    static let instanceID = "i-0123456789abcdef0"

    /// Each recorded case: how to make the same call through the client, projected to the
    /// decoded fields the recorder wrote.
    static func call(_ name: String, _ client: AWSClient) async throws -> [String: String] {
        switch name {
        case "sso-oidc-register-client":
            let out = try await client.registerClient(clientName: "SSM Connect", clientType: "public", scopes: ["sso:account:access"])
            return ["clientId": out.clientId, "clientSecret": out.clientSecret, "clientSecretExpiresAt": String(out.clientSecretExpiresAt)]
        case "sso-oidc-start-device-authorization":
            let out = try await client.startDeviceAuthorization(clientId: "client-id", clientSecret: "client-secret", startUrl: "https://example.awsapps.com/start")
            return ["deviceCode": out.deviceCode, "verificationUriComplete": text(out.verificationUriComplete), "expiresIn": String(out.expiresIn), "interval": String(out.interval)]
        case "sso-oidc-create-token-device-code":
            return token(try await client.createToken(clientId: "client-id", clientSecret: "client-secret", grantType: "urn:ietf:params:oauth:grant-type:device_code", deviceCode: "device-code"))
        case "sso-oidc-create-token-refresh":
            return token(try await client.createToken(clientId: "client-id", clientSecret: "client-secret", grantType: "refresh_token", refreshToken: "refresh-token"))
        case "sso-get-role-credentials":
            let out = try await client.getRoleCredentials(accessToken: "access-token", accountId: "123456789012", roleName: "WorkstationUser")
            return ["accessKeyId": out.accessKeyId, "secretAccessKey": out.secretAccessKey, "sessionToken": out.sessionToken, "expiration": String(out.expirationMilliseconds)]
        case "ec2-describe-instances-by-tag":
            return instances(try await client.describeInstances(filters: [
                ("tag:Name", ["workstation"]),
                ("instance-state-name", ["pending", "running", "stopping", "stopped"]),
            ]))
        case "ec2-describe-instances-by-id":
            return instances(try await client.describeInstances(instanceIds: [instanceID]))
        case "ec2-start-instances":
            return ["count": String(try await client.startInstances(instanceIds: [instanceID]).count)]
        case "ec2-stop-instances":
            return ["count": String(try await client.stopInstances(instanceIds: [instanceID]).count)]
        case "ssm-describe-instance-information":
            let list = try await client.describeInstanceInformation(filters: [("InstanceIds", [instanceID])])
            return ["count": String(list.count), "instanceId": text(list.first?.instanceId), "pingStatus": text(list.first?.pingStatus)]
        case "ssm-start-session-ssh":
            return session(try await client.startSession(target: instanceID, documentName: "AWS-StartSSHSession", parameters: ["portNumber": ["22"]]))
        case "ssm-start-session-port-forward":
            return session(try await client.startSession(target: instanceID, documentName: "AWS-StartPortForwardingSession",
                                                  parameters: ["portNumber": ["8443"], "localPortNumber": ["58443"]]))
        case "secretsmanager-get-secret-value":
            return ["secretString": text(try await client.getSecretValue(secretId: "dcv"))]
        case "ec2-instance-connect-send-ssh-public-key":
            return ["success": String(try await client.sendSSHPublicKey(instanceId: instanceID, instanceOSUser: "ec2-user",
                                                                sshPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample ssm-connect"))]
        default:
            throw CallError.unknown(name)
        }
    }

    enum CallError: Error { case unknown(String) }

    static let names = [
        "ec2-describe-instances-by-id",
        "ec2-describe-instances-by-tag",
        "ec2-instance-connect-send-ssh-public-key",
        "ec2-start-instances",
        "ec2-stop-instances",
        "secretsmanager-get-secret-value",
        "ssm-describe-instance-information",
        "ssm-start-session-port-forward",
        "ssm-start-session-ssh",
        "sso-get-role-credentials",
        "sso-oidc-create-token-device-code",
        "sso-oidc-create-token-refresh",
        "sso-oidc-register-client",
        "sso-oidc-start-device-authorization",
    ]

    static func text(_ value: String?) -> String { value ?? "nil" }
    static func token(_ out: SSOToken) -> [String: String] {
        ["accessToken": out.accessToken, "expiresIn": String(out.expiresIn), "refreshToken": text(out.refreshToken)]
    }
    static func instances(_ list: [InstanceSummary]) -> [String: String] {
        ["count": String(list.count), "instanceId": text(list.first?.instanceId), "state": text(list.first?.state),
         "privateIpAddress": text(list.first?.privateIpAddress)]
    }
    static func session(_ out: SessionStart) -> [String: String] {
        ["sessionId": out.sessionId, "streamUrl": out.streamUrl, "tokenValue": out.tokenValue]
    }

    @Test("Every recorded case has a client call")
    func coverage() throws {
        let recorded = try FileManager.default.contentsOfDirectory(atPath: Self.directory.path)
            .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
        #expect(recorded == Self.names)
        #expect(recorded.count == 14)
    }

    @Test("The client sends the SDK's request and decodes its response", arguments: names)
    func parity(_ name: String) async throws {
        let fixture = try Self.fixture(name)
        let transport = CapturingTransport(response: HTTPResponse(
            status: fixture.response.status, headers: fixture.response.headers.map { ($0[0], $0[1]) },
            body: Data(fixture.response.body.utf8)
        ))
        let client = AWSClient(region: fixture.region, credentials: Self.credentials, transport: transport)
        let decoded = try await Self.call(name, client)
        #expect(decoded == fixture.decoded)

        let sent = try #require(transport.requests.first)
        #expect(transport.requests.count == 1)
        let expected = fixture.request
        #expect(sent.method == expected.method)
        let expectedURL = URLComponents(string: "http://recorded" + expected.uri)!
        let sentURL = URLComponents(url: sent.url, resolvingAgainstBaseURL: false)!
        #expect((sentURL.path.isEmpty ? "/" : sentURL.path) == expectedURL.path)
        #expect(Self.pairs(sentURL.percentEncodedQuery) == Self.pairs(expectedURL.percentEncodedQuery))
        #expect(Self.body(sent.body, contentType: Self.header("content-type", sent.headers))
            == Self.body(Data(expected.body.utf8), contentType: Self.header("content-type", expected.headers.map { ($0[0], $0[1]) })))

        let expectedHeaders = expected.headers.map { ($0[0], $0[1]) }
        for name in ["content-type", "x-amz-target", "x-amz-security-token", "x-amz-sso_bearer_token"] {
            #expect(Self.header(name, sent.headers) == Self.header(name, expectedHeaders), "\(name)")
        }
        #expect(Self.scope(Self.header("authorization", sent.headers)) == Self.scope(Self.header("authorization", expectedHeaders)))
    }

    /// Today's direct STS path (STSIdentityResolver in the main package) sends a GET of the
    /// presigned URL that STSPresignerTests pins, and reads the <Arn> from the XML reply.
    @Test("The STS identity request matches today's direct path")
    func stsIdentity() async throws {
        let arn = "arn:aws:sts::123456789012:assumed-role/AWSReservedSSO_WorkstationUser_0123456789abcdef/jane.doe"
        let transport = CapturingTransport(response: HTTPResponse(
            status: 200, headers: [("Content-Type", "text/xml")],
            body: Data("<GetCallerIdentityResponse xmlns=\"https://sts.amazonaws.com/doc/2011-06-15/\"><GetCallerIdentityResult><Arn>\(arn)</Arn><UserId>AROAEXAMPLE:jane.doe</UserId><Account>123456789012</Account></GetCallerIdentityResult></GetCallerIdentityResponse>".utf8)
        ))
        let credentials = AWSCredentialSet(
            accessKeyID: "AKIDEXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", sessionToken: "SESSIONTOKEN123"
        )
        let client = AWSClient(region: "eu-central-1", credentials: credentials, transport: transport,
                               now: { Date(timeIntervalSince1970: 1_781_352_000) })
        #expect(try await client.getCallerIdentityARN() == arn)
        let sent = try #require(transport.requests.first)
        #expect(transport.requests.count == 1)
        #expect(sent.method == "GET")
        #expect(sent.body.isEmpty)
        #expect(sent.url.absoluteString == "https://sts.eu-central-1.amazonaws.com/?"
            + "Action=GetCallerIdentity&Version=2011-06-15"
            + "&X-Amz-Algorithm=AWS4-HMAC-SHA256"
            + "&X-Amz-Credential=AKIDEXAMPLE%2F20260613%2Feu-central-1%2Fsts%2Faws4_request"
            + "&X-Amz-Date=20260613T120000Z&X-Amz-Expires=120"
            + "&X-Amz-Security-Token=SESSIONTOKEN123&X-Amz-SignedHeaders=host"
            + "&X-Amz-Signature=72867d630efb3316185feb18215d315ab7e98ea73a7823946a3b07e755ac8aa2")
        #expect(Self.header("authorization", sent.headers) == nil)
    }

    @Test("The STS identity request uses the China endpoint in China regions")
    func stsChina() async throws {
        let transport = CapturingTransport(response: HTTPResponse(status: 200, headers: [], body: Data("<Arn>arn:aws-cn:sts::1:assumed-role/r/u</Arn>".utf8)))
        let client = AWSClient(region: "cn-north-1", credentials: Self.credentials, transport: transport)
        _ = try await client.getCallerIdentityARN()
        #expect(transport.requests.first?.url.host == "sts.cn-north-1.amazonaws.com.cn")
    }

    static func header(_ name: String, _ headers: [(String, String)]) -> String? {
        headers.first { $0.0.lowercased() == name }?.1
    }

    /// The credential scope without its date, or nil for an unsigned request.
    static func scope(_ authorization: String?) -> String? {
        guard let authorization, let range = authorization.range(of: "Credential=") else { return nil }
        let credential = authorization[range.upperBound...].prefix { $0 != "," }
        let parts = credential.split(separator: "/")
        return parts.count == 5 ? [parts[0], parts[2], parts[3], parts[4]].joined(separator: "/") : String(credential)
    }

    static func pairs(_ query: String?) -> [String] {
        (query ?? "").split(separator: "&").map { String($0).removingPercentEncoding ?? String($0) }.sorted()
    }

    /// JSON bodies compare as values, form bodies as sorted decoded pairs.
    static func body(_ data: Data, contentType: String?) -> String {
        if contentType?.contains("json") == true, !data.isEmpty,
           let object = try? JSONSerialization.jsonObject(with: data),
           let normalized = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
            return String(decoding: normalized, as: UTF8.self)
        }
        if contentType?.contains("x-www-form-urlencoded") == true {
            let pairs = String(decoding: data, as: UTF8.self).split(separator: "&").map {
                String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0)
            }
            return pairs.sorted().joined(separator: "&")
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// Returns one canned response and keeps every request sent.
final class CapturingTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var sent: [HTTPRequest] = []
    let response: HTTPResponse

    init(response: HTTPResponse) { self.response = response }

    var requests: [HTTPRequest] { lock.withLock { sent } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.withLock { sent.append(request) }
        return response
    }
}
