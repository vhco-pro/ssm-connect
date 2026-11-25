import AWSEC2
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SmithyHTTPAPI
import SmithyIdentity

// quota: records the SDK's retry quota on one reused client. A stub HTTP engine answers
// each attempt from a script (an HTTP status with an EC2 error code, a success, or the
// URLError timeout the SDK's URLSession engine reports on Apple platforms), so a timeout
// is classified exactly as on macOS. For each call the recorder notes how many attempts
// the SDK made and the outcome; the quota shows up as calls that stop retrying early.

struct QuotaReply: Codable {
    /// 0 means the engine throws URLError(.timedOut) instead of answering, -1 URLError(.networkConnectionLost).
    var status: Int
    var code: String?
    /// Offset of the Date header from local time; nil means no Date header.
    var dateOffsetSeconds: Double?
}

struct QuotaStep: Codable {
    var calls: Int
    /// What each call's attempts get, in order; the last repeats.
    var script: [QuotaReply]
    /// The attempts each call made.
    var attempts: [Int]
    var outcomes: [String]
}

struct QuotaFixture: Codable {
    var name: String
    var service: String
    var region: String
    var steps: [QuotaStep]
}

final class ScriptedEngine: SmithyHTTPAPI.HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var script: [QuotaReply] = []
    private var count = 0

    func arm(_ replies: [QuotaReply]) { lock.withLock { script = replies; count = 0 } }
    var attempts: Int { lock.withLock { count } }

    func send(request: SmithyHTTPAPI.HTTPRequest) async throws -> SmithyHTTPAPI.HTTPResponse {
        let reply: QuotaReply = lock.withLock {
            count += 1
            return script.count > 1 ? script.removeFirst() : script[0]
        }
        if reply.status == 0 { throw URLError(.timedOut) }
        if reply.status == -1 { throw URLError(.networkConnectionLost) }
        var headers = Headers()
        headers.add(name: "Content-Type", value: "text/xml;charset=UTF-8")
        if let offset = reply.dateOffsetSeconds { headers.add(name: "Date", value: httpDate(Date().addingTimeInterval(offset))) }
        let body: String
        if let code = reply.code {
            body = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Response><Errors><Error><Code>\(code)</Code><Message>scripted \(code)</Message></Error></Errors><RequestID>11111111-2222-3333-4444-555555555555</RequestID></Response>"
        } else {
            body = describeInstancesXML
        }
        return HTTPResponse(headers: headers, body: .data(Data(body.utf8)), statusCode: HTTPStatusCode(rawValue: reply.status) ?? .badRequest)
    }
}

func recordQuota(to directory: String) async throws {
    let resolver = StaticAWSCredentialIdentityResolver(AWSCredentialIdentity(
        accessKey: "AKIDEXAMPLE", secret: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", sessionToken: "SESSIONTOKEN"
    ))
    let internalError = QuotaReply(status: 500, code: "InternalError", dateOffsetSeconds: 0)
    let timeout = QuotaReply(status: 0, code: nil, dateOffsetSeconds: nil)
    let lost = QuotaReply(status: -1, code: nil, dateOffsetSeconds: nil)
    let ok = QuotaReply(status: 200, code: nil, dateOffsetSeconds: 0)
    let skewed = QuotaReply(status: 401, code: "AuthFailure", dateOffsetSeconds: 9 * 3600)

    // One client per scenario, reused for every call in it. Each scenario uses its own region,
    // so its endpoint host differs and no learned clock skew carries over between scenarios.
    func scenario(_ name: String, region: String, _ plan: [(Int, [QuotaReply])]) async throws {
        let engine = ScriptedEngine()
        let client = EC2Client(config: try await EC2Client.EC2ClientConfig(awsCredentialIdentityResolver: resolver, region: region, httpClientEngine: engine))
        var steps: [QuotaStep] = []
        for (calls, script) in plan {
            var step = QuotaStep(calls: calls, script: script, attempts: [], outcomes: [])
            for _ in 0..<calls {
                engine.arm(script)
                do {
                    _ = try await client.describeInstances(input: DescribeInstancesInput(instanceIds: [instanceID]))
                    step.outcomes.append("success")
                } catch {
                    step.outcomes.append("error: " + String(describing: type(of: error)))
                }
                step.attempts.append(engine.attempts)
            }
            steps.append(step)
            FileHandle.standardError.write(Data("\(name): \(calls) x \(script.map(\.status)) -> attempts \(Set(step.attempts).sorted())\n".utf8))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(QuotaFixture(name: name, service: "ec2", region: region, steps: steps))
            .write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).json"))
    }

    // 50 calls that each use both retries spend the 500 tokens at 5 per retry.
    try await scenario("ec2-quota-exhausted", region: "eu-central-1", [(50, [internalError]), (1, [internalError])])
    // A timeout retry costs 10, so 25 timing-out calls spend the same tokens.
    try await scenario("ec2-quota-timeout-cost", region: "eu-west-1", [(25, [timeout]), (1, [internalError])])
    // A lost connection is retried at the ordinary cost of 5.
    try await scenario("ec2-quota-connection-lost-cost", region: "ap-southeast-2", [(50, [lost]), (1, [internalError])])
    // Each success without a retry returns 1 token; a success after a retry returns that retry's cost.
    try await scenario("ec2-quota-refill", region: "us-east-1", [(50, [internalError]), (5, [ok]), (1, [internalError, ok]), (1, [internalError])])
    // A skew retry is charged like any other and is refused once the tokens are spent.
    try await scenario("ec2-quota-skew-refused", region: "us-west-2", [(50, [internalError]), (1, [skewed, ok])])
}
