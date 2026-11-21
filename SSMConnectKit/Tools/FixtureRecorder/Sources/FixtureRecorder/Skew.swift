import AWSEC2
import AWSSSM
import Foundation
import SmithyIdentity

// skew: records how the SDK reacts to clock-skew errors. Each scenario uses its own
// loopback address, because the SDK keeps learned offsets per host for the process.
// For every attempt it records the offset between the request's X-Amz-Date and the
// local time the request arrived, so a corrected retry shows up as a signing offset.

struct SkewAttempt: Codable {
    var signedOffsetSeconds: Double
}

struct SkewFixture: Codable {
    var name: String
    var service: String
    /// Responses in order, each with the offset of its Date header from local time
    /// (nil means no Date header).
    var responses: [SkewResponse]
    var calls: [SkewCall]
}

struct SkewResponse: Codable {
    var response: CannedResponse
    var dateOffsetSeconds: Double?
}

struct SkewCall: Codable {
    var attempts: [SkewAttempt]
    var outcome: String
}

func httpDate(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "GMT")
    f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
    return f.string(from: date)
}

func amzDate(_ text: String) -> Date? {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    return f.date(from: text)
}

func recordSkew(to directory: String) async throws {
    let identity = AWSCredentialIdentity(accessKey: "AKIDEXAMPLE", secret: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", sessionToken: "SESSIONTOKEN")
    let resolver = StaticAWSCredentialIdentityResolver(identity)
    let nineHours = 9.0 * 3600
    var hostIndex = 1

    func withDate(_ response: CannedResponse, _ offset: Double?) -> SkewResponse {
        SkewResponse(response: response, dateOffsetSeconds: offset)
    }

    /// Runs `calls` against one fresh client and server, returning per-call attempts.
    func run(_ name: String, _ service: String, _ responses: [SkewResponse], calls: Int, concurrent: Bool = false,
             _ call: @escaping @Sendable (String) async throws -> Void) async throws {
        hostIndex += 1
        let exchange = Exchange()
        // Date headers are computed when each response is served, relative to local time then.
        exchange.armDated(responses.map { ($0.response, $0.dateOffsetSeconds) })
        let (channel, group, endpoint) = try await startServer(exchange, host: "127.0.0.\(hostIndex)")
        var outcomes: [String] = []
        if concurrent {
            outcomes = await withTaskGroup(of: String.self) { group in
                for _ in 0..<calls {
                    group.addTask {
                        do { try await call(endpoint); return "success" } catch { return "error: " + String(describing: type(of: error)) }
                    }
                }
                var results: [String] = []
                for await result in group { results.append(result) }
                return results.sorted()
            }
        } else {
            for _ in 0..<calls {
                do { try await call(endpoint); outcomes.append("success") } catch { outcomes.append("error: " + String(describing: type(of: error))) }
            }
        }
        let requests = exchange.requests
        let arrivals = exchange.arrivals
        let attempts: [SkewAttempt] = zip(requests, arrivals).map { request, arrival in
            let header = request.headers.first { $0[0].lowercased() == "x-amz-date" }?[1] ?? ""
            let signed = amzDate(header) ?? arrival
            return SkewAttempt(signedOffsetSeconds: (signed.timeIntervalSince(arrival)).rounded())
        }
        let fixture = SkewFixture(name: name, service: service, responses: responses,
                                  calls: [SkewCall(attempts: attempts, outcome: outcomes.joined(separator: ", "))])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(fixture).write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).json"))
        try await channel.close()
        try await group.shutdownGracefully()
    }

    let instances = ec2XML(describeInstancesXML)
    let session = awsJSON(#"{"SessionId":"s","StreamUrl":"wss://ssmmessages.eu-central-1.amazonaws.com/v1/data-channel/s","TokenValue":"t"}"#)
    // A fresh client per scenario, so retry quotas do not carry over; the skew store is per host.
    let describe: @Sendable (String) async throws -> Void = { endpoint in
        let client = EC2Client(config: try await EC2Client.EC2ClientConfig(awsCredentialIdentityResolver: resolver, region: "eu-central-1", endpoint: endpoint))
        _ = try await client.describeInstances(input: DescribeInstancesInput(instanceIds: [instanceID]))
    }
    let startSSH: @Sendable (String) async throws -> Void = { endpoint in
        let client = SSMClient(config: try await SSMClient.SSMClientConfig(awsCredentialIdentityResolver: resolver, region: "eu-central-1", endpoint: endpoint))
        _ = try await client.startSession(input: StartSessionInput(documentName: "AWS-StartSSHSession", parameters: ["portNumber": ["22"]], target: instanceID))
    }

    try await run("ec2-auth-failure-far-ahead", "ec2", [withDate(ec2Error(401, "AuthFailure"), nineHours), withDate(instances, nineHours)], calls: 1, describe)
    try await run("ec2-auth-failure-far-behind", "ec2", [withDate(ec2Error(401, "AuthFailure"), -nineHours), withDate(instances, -nineHours)], calls: 1, describe)
    try await run("ec2-request-expired-far", "ec2", [withDate(ec2Error(400, "RequestExpired"), nineHours), withDate(instances, nineHours)], calls: 1, describe)
    try await run("ec2-auth-failure-near", "ec2", [withDate(ec2Error(401, "AuthFailure"), 240), withDate(instances, 240)], calls: 1, describe)
    try await run("ec2-auth-failure-no-date", "ec2", [withDate(ec2Error(401, "AuthFailure"), nil), withDate(instances, nil)], calls: 1, describe)
    try await run("ec2-unauthorized-far", "ec2", [withDate(ec2Error(403, "UnauthorizedOperation"), nineHours), withDate(instances, nineHours)], calls: 1, describe)
    try await run("ssm-invalid-signature-far", "ssm", [withDate(jsonError(400, "InvalidSignatureException"), nineHours), withDate(session, nineHours)], calls: 1, startSSH)
    // Learn +9h, then the clock is "repaired": the server's Date matches local time again.
    try await run("ec2-learned-then-repaired", "ec2", [
        withDate(ec2Error(401, "AuthFailure"), nineHours), withDate(instances, nineHours),
        withDate(ec2Error(401, "AuthFailure"), 0), withDate(instances, 0),
    ], calls: 2, describe)
    // A learned offset is used for the next call to the same host without a failure first.
    try await run("ec2-learned-then-reused", "ec2", [
        withDate(ec2Error(401, "AuthFailure"), nineHours), withDate(instances, nineHours), withDate(instances, nineHours),
    ], calls: 2, describe)
    // Two calls fail with the same skew at once.
    try await run("ec2-concurrent-same-skew", "ec2", [
        withDate(ec2Error(401, "AuthFailure"), nineHours), withDate(ec2Error(401, "AuthFailure"), nineHours),
        withDate(instances, nineHours),
    ], calls: 2, concurrent: true, describe)
}
