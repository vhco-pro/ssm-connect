import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import SSMConnectAWSClient

/// Retry quota parity with the pinned aws-sdk-swift (Fixtures/quota, recorded by FixtureRecorder
/// from smithy-swift 0.242.0 `RetryQuota` in its default mode): one quota of 500 tokens per client,
/// 5 per retry and 10 per timeout retry, 1 back for a success without a retry and the retry's cost
/// back for a success after one.
@Suite("Retry quota")
struct RetryQuotaTests {
    struct Fixture: Decodable {
        struct Reply: Decodable { let status: Int; let code: String?; let dateOffsetSeconds: Double? }
        struct Step: Decodable { let calls: Int; let script: [Reply]; let attempts: [Int]; let outcomes: [String] }
        let name: String
        let region: String
        let steps: [Step]
    }

    static let directory = Bundle.module.url(forResource: "Fixtures/quota", withExtension: nil)!
    static var names: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }

    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let credentials = AWSCredentialSet(accessKeyID: "AKIDEXAMPLE", secretAccessKey: "secret", sessionToken: "token")
    static let noWait = RetryPolicy(random: { 0 }, sleep: { _ in })

    static func client(_ transport: QuotaTransport, region: String = "eu-central-1") -> AWSClient {
        AWSClient(region: region, credentials: credentials, transport: transport, now: { now }, retry: noWait, clockSkew: ClockSkewStore())
    }

    /// Runs one DescribeInstances call against `script` and returns its attempts and outcome.
    static func call(_ client: AWSClient, _ transport: QuotaTransport, _ script: [QuotaTransport.Reply]) async -> (Int, String) {
        transport.arm(script)
        do {
            _ = try await client.describeInstances(instanceIds: ["i-0123456789abcdef0"])
            return (transport.attempts, "success")
        } catch {
            return (transport.attempts, "error")
        }
    }

    static let internalError = QuotaTransport.Reply(status: 500, code: "InternalError", dateOffset: 0)
    static let ok = QuotaTransport.Reply(status: 200, code: nil, dateOffset: 0)

    @Test("The recorded scenarios are present")
    func coverage() {
        #expect(Self.names == ["ec2-quota-connection-lost-cost", "ec2-quota-exhausted", "ec2-quota-refill", "ec2-quota-skew-refused", "ec2-quota-timeout-cost"])
    }

    @Test("One reused client spends and refills its quota as the SDK did", arguments: names)
    func parity(_ name: String) async throws {
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: Self.directory.appendingPathComponent("\(name).json")))
        let transport = QuotaTransport(now: Self.now)
        let client = Self.client(transport, region: fixture.region)
        for (index, step) in fixture.steps.enumerated() {
            let script = step.script.map { QuotaTransport.Reply(status: $0.status, code: $0.code, dateOffset: $0.dateOffsetSeconds) }
            var attempts: [Int] = []
            var outcomes: [String] = []
            for _ in 0..<step.calls {
                let (count, outcome) = await Self.call(client, transport, script)
                attempts.append(count)
                outcomes.append(outcome)
            }
            #expect(attempts == step.attempts, "\(name) step \(index + 1): attempts")
            #expect(outcomes == step.outcomes.map { $0.hasPrefix("error") ? "error" : "success" }, "\(name) step \(index + 1): outcomes")
        }
    }

    @Test("Each client has its own quota")
    func perClient() async {
        let spentTransport = QuotaTransport(now: Self.now)
        let spent = Self.client(spentTransport)
        for _ in 0..<50 { _ = await Self.call(spent, spentTransport, [Self.internalError]) }
        #expect(await Self.call(spent, spentTransport, [Self.internalError]).0 == 1)

        let freshTransport = QuotaTransport(now: Self.now)
        let fresh = Self.client(freshTransport)
        #expect(await Self.call(fresh, freshTransport, [Self.internalError]).0 == 3)
    }
}

/// Answers each attempt from the armed script (the last reply repeats). Status 0 throws a
/// timeout and -1 a lost connection; otherwise an EC2 response with a Date header at the fixed
/// time plus the reply's offset.
final class QuotaTransport: HTTPTransport, @unchecked Sendable {
    struct Reply {
        var status: Int
        var code: String?
        var dateOffset: Double?
    }
    private let lock = NSLock()
    private var script: [Reply] = []
    private var count = 0
    let now: Date

    init(now: Date) { self.now = now }

    func arm(_ replies: [Reply]) { lock.withLock { script = replies; count = 0 } }
    var attempts: Int { lock.withLock { count } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let reply: Reply = lock.withLock {
            count += 1
            return script.count > 1 ? script.removeFirst() : script[0]
        }
        if reply.status == 0 { throw URLError(.timedOut) }
        if reply.status == -1 { throw URLError(.networkConnectionLost) }
        var headers: [(String, String)] = [("Content-Type", "text/xml;charset=UTF-8")]
        if let offset = reply.dateOffset { headers.append(("Date", SkewTransport.httpDate(now.addingTimeInterval(offset)))) }
        let body = reply.code.map { "<Response><Errors><Error><Code>\($0)</Code><Message>m</Message></Error></Errors></Response>" }
            ?? "<DescribeInstancesResponse><reservationSet/></DescribeInstancesResponse>"
        return HTTPResponse(status: reply.status, headers: headers, body: Data(body.utf8))
    }
}
