import AWSEC2
import AWSSSM
import AWSSSOOIDC
import Foundation
import SmithyIdentity

// retries: scripts failure sequences on the loopback server and records how many
// attempts the SDK makes, the delays between them and the outcome, with no retry
// settings configured.

struct RetryFixture: Codable {
    var name: String
    var service: String
    var responses: [CannedResponse]
    var attempts: Int
    var delays: [Double]
    var outcome: String
}

let closeConnection = CannedResponse(status: 0, headers: [], body: "")

func jsonError(_ status: Int, _ type: String, _ contentType: String = "application/x-amz-json-1.1") -> CannedResponse {
    CannedResponse(status: status, headers: [["Content-Type", contentType], ["x-amzn-ErrorType", type]],
                   body: #"{"__type":"\#(type)","message":"scripted \#(type)"}"#)
}

func ec2Error(_ status: Int, _ code: String) -> CannedResponse {
    CannedResponse(status: status, headers: [["Content-Type", "text/xml;charset=UTF-8"]],
                   body: "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Response><Errors><Error><Code>\(code)</Code><Message>scripted \(code)</Message></Error></Errors><RequestID>11111111-2222-3333-4444-555555555555</RequestID></Response>")
}

func oidcError(_ status: Int, _ type: String, _ error: String) -> CannedResponse {
    CannedResponse(status: status, headers: [["Content-Type", "application/json"], ["x-amzn-ErrorType", type]],
                   body: #"{"error":"\#(error)","error_description":"scripted \#(error)"}"#)
}

func recordRetries(to directory: String) async throws {
    let exchange = Exchange()
    let (channel, group, endpoint) = try await startServer(exchange)
    let region = "eu-central-1"
    let resolver = StaticAWSCredentialIdentityResolver(AWSCredentialIdentity(
        accessKey: "AKIDEXAMPLE", secret: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", sessionToken: "SESSIONTOKEN"
    ))

    // A fresh client per scenario, so no retry quota carries over between scenarios.
    func ssm() async throws -> SSMClient {
        SSMClient(config: try await SSMClient.SSMClientConfig(awsCredentialIdentityResolver: resolver, region: region, endpoint: endpoint))
    }
    func ec2() async throws -> EC2Client {
        EC2Client(config: try await EC2Client.EC2ClientConfig(awsCredentialIdentityResolver: resolver, region: region, endpoint: endpoint))
    }
    func oidc() async throws -> SSOOIDCClient {
        SSOOIDCClient(config: try await SSOOIDCClient.SSOOIDCClientConfig(awsCredentialIdentityResolver: resolver, region: region, endpoint: endpoint))
    }

    let session = awsJSON(#"{"SessionId":"user-0123456789abcdef0","StreamUrl":"wss://ssmmessages.eu-central-1.amazonaws.com/v1/data-channel/user-0123456789abcdef0","TokenValue":"session-token-value"}"#)
    let instances = ec2XML(describeInstancesXML)
    let token = restJSON(#"{"accessToken":"access-token","tokenType":"Bearer","expiresIn":3600,"refreshToken":"refresh-token"}"#)

    func run(_ name: String, _ service: String, _ responses: [CannedResponse], _ call: () async throws -> Void) async throws {
        exchange.arm(responses)
        let outcome: String
        do {
            try await call()
            outcome = "success"
        } catch {
            outcome = "error: " + String(describing: type(of: error))
        }
        let arrivals = exchange.arrivals
        let delays = zip(arrivals.dropFirst(), arrivals).map { ($0.timeIntervalSince($1) * 1000).rounded() / 1000 }
        let fixture = RetryFixture(name: name, service: service, responses: responses, attempts: arrivals.count, delays: delays, outcome: outcome)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(fixture).write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).json"))
    }

    let startSSH = { (client: SSMClient) in
        _ = try await client.startSession(input: StartSessionInput(documentName: "AWS-StartSSHSession", parameters: ["portNumber": ["22"]], target: instanceID))
    }
    let describe = { (client: EC2Client) in
        _ = try await client.describeInstances(input: DescribeInstancesInput(instanceIds: [instanceID]))
    }
    let createToken = { (client: SSOOIDCClient) in
        _ = try await client.createToken(input: CreateTokenInput(clientId: "client-id", clientSecret: "client-secret", deviceCode: "device-code",
                                                                 grantType: "urn:ietf:params:oauth:grant-type:device_code"))
    }

    // AWS JSON 1.1 (Systems Manager)
    try await run("ssm-throttling-then-success", "ssm", [jsonError(400, "ThrottlingException"), jsonError(400, "ThrottlingException"), session]) { try await startSSH(try await ssm()) }
    try await run("ssm-throttling-exhausted", "ssm", [jsonError(400, "ThrottlingException")]) { try await startSSH(try await ssm()) }
    try await run("ssm-500-then-success", "ssm", [jsonError(500, "InternalServerError"), session]) { try await startSSH(try await ssm()) }
    try await run("ssm-503-exhausted", "ssm", [jsonError(503, "ServiceUnavailable")]) { try await startSSH(try await ssm()) }
    try await run("ssm-408-then-success", "ssm", [jsonError(408, "RequestTimeout"), session]) { try await startSSH(try await ssm()) }
    try await run("ssm-connection-closed-then-success", "ssm", [closeConnection, session]) { try await startSSH(try await ssm()) }
    try await run("ssm-access-denied", "ssm", [jsonError(400, "AccessDeniedException")]) { try await startSSH(try await ssm()) }
    var retryAfter = jsonError(503, "ServiceUnavailable")
    retryAfter.headers.append(["x-amz-retry-after", "5000"])
    try await run("ssm-retry-after-ignored", "ssm", [retryAfter, session]) { try await startSSH(try await ssm()) }

    // EC2 Query
    try await run("ec2-request-limit-then-success", "ec2", [ec2Error(503, "RequestLimitExceeded"), instances]) { try await describe(try await ec2()) }
    try await run("ec2-internal-error-then-success", "ec2", [ec2Error(500, "InternalError"), instances]) { try await describe(try await ec2()) }
    try await run("ec2-unauthorized", "ec2", [ec2Error(403, "UnauthorizedOperation")]) { try await describe(try await ec2()) }

    // REST JSON (SSO OIDC); the app's device polling handles these two itself.
    try await run("sso-oidc-slow-down", "sso-oidc", [oidcError(400, "SlowDownException", "slow_down"), token]) { try await createToken(try await oidc()) }
    try await run("sso-oidc-authorization-pending", "sso-oidc", [oidcError(400, "AuthorizationPendingException", "authorization_pending"), token]) { try await createToken(try await oidc()) }
    try await run("sso-oidc-503-then-success", "sso-oidc", [oidcError(503, "InternalServerException", "server_error"), token]) { try await createToken(try await oidc()) }

    try await channel.close()
    try await group.shutdownGracefully()
}
