import AWSEC2
import AWSEC2InstanceConnect
import AWSSecretsManager
import AWSSSM
import AWSSSO
import AWSSSOOIDC
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import SmithyIdentity

// requests: drives each SDK operation the app calls, with the inputs the app passes,
// against a loopback server that records the request and returns a canned success
// response, then writes the request, the response and the decoded fields the app reads.

struct RecordedRequest: Codable {
    var method: String
    var uri: String
    var headers: [[String]]
    var body: String
}

struct CannedResponse: Codable {
    var status: Int
    var headers: [[String]]
    var body: String
}

struct RequestFixture: Codable {
    var name: String
    var service: String
    var region: String
    var request: RecordedRequest
    var response: CannedResponse
    var decoded: [String: String]
}

/// Requests seen and the response to give the next one.
final class Exchange: @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [CannedResponse] = []
    private var seen: [RecordedRequest] = []
    private var times: [Date] = []

    /// One response for every request.
    func arm(_ response: CannedResponse) { arm([response]) }
    /// Responses in order; the last repeats. Status 0 closes the connection without a reply.
    func arm(_ responses: [CannedResponse]) { lock.withLock { queue = responses; seen = []; times = [] } }
    func record(_ request: RecordedRequest) -> CannedResponse {
        lock.withLock {
            seen.append(request)
            times.append(Date())
            guard !queue.isEmpty else { return CannedResponse(status: 500, headers: [], body: "unarmed") }
            return queue.count > 1 ? queue.removeFirst() : queue[0]
        }
    }
    var requests: [RecordedRequest] { lock.withLock { seen } }
    var arrivals: [Date] { lock.withLock { times } }
}

final class RecordingHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    let exchange: Exchange
    var head: HTTPRequestHead?
    var body = ByteBuffer()

    init(exchange: Exchange) { self.exchange = exchange }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let value):
            head = value
            body.clear()
        case .body(var chunk):
            body.writeBuffer(&chunk)
        case .end:
            guard let head else { return }
            let recorded = RecordedRequest(
                method: head.method.rawValue, uri: head.uri,
                headers: head.headers.map { [$0.name, $0.value] },
                body: body.getString(at: body.readerIndex, length: body.readableBytes) ?? ""
            )
            let response = exchange.record(recorded)
            if response.status == 0 {
                context.close(promise: nil)
                return
            }
            var headers = HTTPHeaders(response.headers.map { ($0[0], $0[1]) })
            headers.replaceOrAdd(name: "Content-Length", value: String(response.body.utf8.count))
            let status = HTTPResponseStatus(statusCode: response.status)
            context.write(wrapOutboundOut(.head(HTTPResponseHead(version: head.version, status: status, headers: headers))), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(string: response.body)))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
}

func jsonResponse(_ contentType: String, _ body: String) -> CannedResponse {
    CannedResponse(status: 200, headers: [["Content-Type", contentType], ["x-amzn-RequestId", "11111111-2222-3333-4444-555555555555"]], body: body)
}
func restJSON(_ body: String) -> CannedResponse { jsonResponse("application/json", body) }
func awsJSON(_ body: String) -> CannedResponse { jsonResponse("application/x-amz-json-1.1", body) }
func ec2XML(_ body: String) -> CannedResponse {
    CannedResponse(status: 200, headers: [["Content-Type", "text/xml;charset=UTF-8"]], body: body)
}

let instanceID = "i-0123456789abcdef0"
let ec2Namespace = "http://ec2.amazonaws.com/doc/2016-11-15/"
let describeInstancesXML = """
<?xml version="1.0" encoding="UTF-8"?>
<DescribeInstancesResponse xmlns="\(ec2Namespace)"><requestId>11111111-2222-3333-4444-555555555555</requestId><reservationSet><item><reservationId>r-0123456789abcdef0</reservationId><ownerId>123456789012</ownerId><instancesSet><item><instanceId>\(instanceID)</instanceId><instanceState><code>16</code><name>running</name></instanceState><privateIpAddress>10.0.0.12</privateIpAddress><tagSet><item><key>Name</key><value>workstation</value></item></tagSet></item></instancesSet></item></reservationSet></DescribeInstancesResponse>
"""
func stateChangeXML(_ action: String, current: (Int, String), previous: (Int, String)) -> String {
    """
    <?xml version="1.0" encoding="UTF-8"?>
    <\(action)Response xmlns="\(ec2Namespace)"><requestId>11111111-2222-3333-4444-555555555555</requestId><instancesSet><item><instanceId>\(instanceID)</instanceId><currentState><code>\(current.0)</code><name>\(current.1)</name></currentState><previousState><code>\(previous.0)</code><name>\(previous.1)</name></previousState></item></instancesSet></\(action)Response>
    """
}

/// A loopback HTTP server that records requests into `exchange`.
func startServer(_ exchange: Exchange) async throws -> (channel: Channel, group: MultiThreadedEventLoopGroup, endpoint: String) {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let channel = try await ServerBootstrap(group: group)
        .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        .childChannelInitializer { channel in
            channel.pipeline.configureHTTPServerPipeline().flatMap {
                channel.pipeline.addHandler(RecordingHandler(exchange: exchange))
            }
        }
        .bind(host: "127.0.0.1", port: 0).get()
    return (channel, group, "http://127.0.0.1:\(channel.localAddress!.port!)")
}

func recordRequests(to directory: String) async throws {
    let exchange = Exchange()
    let (channel, group, endpoint) = try await startServer(exchange)

    let region = "eu-central-1"
    let identity = AWSCredentialIdentity(
        accessKey: "AKIDEXAMPLE", secret: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", sessionToken: "SESSIONTOKEN"
    )
    let resolver = StaticAWSCredentialIdentityResolver(identity)
    let oidc = SSOOIDCClient(config: try await SSOOIDCClient.SSOOIDCClientConfig(awsCredentialIdentityResolver: resolver, region: region, endpoint: endpoint))
    let sso = SSOClient(config: try await SSOClient.SSOClientConfig(awsCredentialIdentityResolver: resolver, region: region, endpoint: endpoint))
    let ec2 = EC2Client(config: try await EC2Client.EC2ClientConfig(awsCredentialIdentityResolver: resolver, region: region, endpoint: endpoint))
    let ssm = SSMClient(config: try await SSMClient.SSMClientConfig(awsCredentialIdentityResolver: resolver, region: region, endpoint: endpoint))
    let secrets = SecretsManagerClient(config: try await SecretsManagerClient.SecretsManagerClientConfig(awsCredentialIdentityResolver: resolver, region: region, endpoint: endpoint))
    let eic = EC2InstanceConnectClient(config: try await EC2InstanceConnectClient.EC2InstanceConnectClientConfig(awsCredentialIdentityResolver: resolver, region: region, endpoint: endpoint))

    func run(_ name: String, _ service: String, _ response: CannedResponse, _ call: () async throws -> [String: String]) async throws {
        exchange.arm(response)
        let decoded = try await call()
        let requests = exchange.requests
        guard requests.count == 1 else { throw RecorderError.unexpectedRequests(name, requests.count) }
        let fixture = RequestFixture(name: name, service: service, region: region, request: requests[0], response: response, decoded: decoded)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(fixture).write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).json"))
    }
    func text(_ value: Any?) -> String { value.map { "\($0)" } ?? "nil" }
    func epoch(_ date: Date?) -> String { date.map { String(Int($0.timeIntervalSince1970)) } ?? "nil" }

    try await run("sso-oidc-register-client", "sso-oidc", restJSON(#"{"clientId":"client-id","clientSecret":"client-secret","clientIdIssuedAt":1700000000,"clientSecretExpiresAt":1800000000}"#)) {
        let out = try await oidc.registerClient(input: RegisterClientInput(clientName: "SSM Connect", clientType: "public", scopes: ["sso:account:access"]))
        return ["clientId": text(out.clientId), "clientSecret": text(out.clientSecret), "clientSecretExpiresAt": text(out.clientSecretExpiresAt)]
    }
    try await run("sso-oidc-start-device-authorization", "sso-oidc", restJSON(#"{"deviceCode":"device-code","userCode":"ABCD-EFGH","verificationUri":"https://device.sso.eu-central-1.amazonaws.com/","verificationUriComplete":"https://device.sso.eu-central-1.amazonaws.com/?user_code=ABCD-EFGH","expiresIn":600,"interval":5}"#)) {
        let out = try await oidc.startDeviceAuthorization(input: StartDeviceAuthorizationInput(clientId: "client-id", clientSecret: "client-secret", startUrl: "https://example.awsapps.com/start"))
        return ["deviceCode": text(out.deviceCode), "verificationUriComplete": text(out.verificationUriComplete), "expiresIn": text(out.expiresIn), "interval": text(out.interval)]
    }
    let tokenBody = #"{"accessToken":"access-token","tokenType":"Bearer","expiresIn":3600,"refreshToken":"refresh-token"}"#
    try await run("sso-oidc-create-token-device-code", "sso-oidc", restJSON(tokenBody)) {
        let out = try await oidc.createToken(input: CreateTokenInput(clientId: "client-id", clientSecret: "client-secret", deviceCode: "device-code", grantType: "urn:ietf:params:oauth:grant-type:device_code"))
        return ["accessToken": text(out.accessToken), "expiresIn": text(out.expiresIn), "refreshToken": text(out.refreshToken)]
    }
    try await run("sso-oidc-create-token-refresh", "sso-oidc", restJSON(tokenBody)) {
        let out = try await oidc.createToken(input: CreateTokenInput(clientId: "client-id", clientSecret: "client-secret", grantType: "refresh_token", refreshToken: "refresh-token"))
        return ["accessToken": text(out.accessToken), "expiresIn": text(out.expiresIn), "refreshToken": text(out.refreshToken)]
    }
    try await run("sso-get-role-credentials", "sso", restJSON(#"{"roleCredentials":{"accessKeyId":"ASIAEXAMPLE","secretAccessKey":"role-secret","sessionToken":"role-session","expiration":1800000000000}}"#)) {
        let out = try await sso.getRoleCredentials(input: GetRoleCredentialsInput(accessToken: "access-token", accountId: "123456789012", roleName: "WorkstationUser"))
        let creds = out.roleCredentials
        return ["accessKeyId": text(creds?.accessKeyId), "secretAccessKey": text(creds?.secretAccessKey), "sessionToken": text(creds?.sessionToken), "expiration": text(creds?.expiration)]
    }
    func instances(_ out: DescribeInstancesOutput) -> [String: String] {
        let list = (out.reservations ?? []).flatMap { $0.instances ?? [] }
        return ["count": String(list.count), "instanceId": text(list.first?.instanceId), "state": text(list.first?.state?.name?.rawValue), "privateIpAddress": text(list.first?.privateIpAddress)]
    }
    try await run("ec2-describe-instances-by-tag", "ec2", ec2XML(describeInstancesXML)) {
        instances(try await ec2.describeInstances(input: DescribeInstancesInput(filters: [
            .init(name: "tag:Name", values: ["workstation"]),
            .init(name: "instance-state-name", values: ["pending", "running", "stopping", "stopped"]),
        ])))
    }
    try await run("ec2-describe-instances-by-id", "ec2", ec2XML(describeInstancesXML)) {
        instances(try await ec2.describeInstances(input: DescribeInstancesInput(instanceIds: [instanceID])))
    }
    try await run("ec2-start-instances", "ec2", ec2XML(stateChangeXML("StartInstances", current: (0, "pending"), previous: (80, "stopped")))) {
        let out = try await ec2.startInstances(input: StartInstancesInput(instanceIds: [instanceID]))
        return ["count": String(out.startingInstances?.count ?? 0)]
    }
    try await run("ec2-stop-instances", "ec2", ec2XML(stateChangeXML("StopInstances", current: (64, "stopping"), previous: (16, "running")))) {
        let out = try await ec2.stopInstances(input: StopInstancesInput(instanceIds: [instanceID]))
        return ["count": String(out.stoppingInstances?.count ?? 0)]
    }
    try await run("ssm-describe-instance-information", "ssm", awsJSON(#"{"InstanceInformationList":[{"InstanceId":"i-0123456789abcdef0","PingStatus":"Online"}]}"#)) {
        let out = try await ssm.describeInstanceInformation(input: DescribeInstanceInformationInput(filters: [.init(key: "InstanceIds", values: [instanceID])]))
        let list = out.instanceInformationList ?? []
        return ["count": String(list.count), "instanceId": text(list.first?.instanceId), "pingStatus": text(list.first?.pingStatus?.rawValue)]
    }
    let sessionBody = #"{"SessionId":"user-0123456789abcdef0","StreamUrl":"wss://ssmmessages.eu-central-1.amazonaws.com/v1/data-channel/user-0123456789abcdef0?role=publish_subscribe","TokenValue":"session-token-value"}"#
    func session(_ out: StartSessionOutput) -> [String: String] {
        ["sessionId": text(out.sessionId), "streamUrl": text(out.streamUrl), "tokenValue": text(out.tokenValue)]
    }
    try await run("ssm-start-session-ssh", "ssm", awsJSON(sessionBody)) {
        session(try await ssm.startSession(input: StartSessionInput(documentName: "AWS-StartSSHSession", parameters: ["portNumber": ["22"]], target: instanceID)))
    }
    try await run("ssm-start-session-port-forward", "ssm", awsJSON(sessionBody)) {
        session(try await ssm.startSession(input: StartSessionInput(documentName: "AWS-StartPortForwardingSession", parameters: ["portNumber": ["8443"], "localPortNumber": ["58443"]], target: instanceID)))
    }
    try await run("secretsmanager-get-secret-value", "secretsmanager", awsJSON(#"{"ARN":"arn:aws:secretsmanager:eu-central-1:123456789012:secret:dcv-AbCdEf","Name":"dcv","SecretString":"dcv-password","VersionId":"00000000-0000-0000-0000-000000000000"}"#)) {
        let out = try await secrets.getSecretValue(input: GetSecretValueInput(secretId: "dcv"))
        return ["secretString": text(out.secretString)]
    }
    try await run("ec2-instance-connect-send-ssh-public-key", "ec2-instance-connect", awsJSON(#"{"RequestId":"11111111-2222-3333-4444-555555555555","Success":true}"#)) {
        let out = try await eic.sendSSHPublicKey(input: SendSSHPublicKeyInput(instanceId: instanceID, instanceOSUser: "ec2-user", sshPublicKey: "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExample ssm-connect"))
        return ["success": text(out.success)]
    }
    try await channel.close()
    try await group.shutdownGracefully()
}

enum RecorderError: Error {
    case unexpectedRequests(String, Int)
}
