import Foundation
import Testing
@testable import SSMConnectAWSClient

/// Retry parity with the pinned aws-sdk-swift and nothing configured
/// (Fixtures/retries, recorded by FixtureRecorder, and smithy-swift 0.242.0's
/// DefaultRetryStrategy): at most 3 attempts; before retry n a delay of
/// random() * 2^n seconds, capped at 20; throttling and transient error codes, HTTP
/// 500, 502, 503, 504 and 408, lost connections and timeouts retried;
/// x-amz-retry-after ignored. The STS identity request keeps its single attempt.
@Suite("Retry parity", .serialized)
struct RetryParityTests {
    struct Fixture: Decodable {
        struct Response: Decodable { let status: Int; let headers: [[String]]; let body: String }
        let name: String
        let service: String
        let responses: [Response]
        let attempts: Int
        let delays: [Double]
        let outcome: String
    }

    static let directory = Bundle.module.url(forResource: "Fixtures/retries", withExtension: nil)!

    static var names: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }

    static func fixture(_ name: String) throws -> Fixture {
        try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: directory.appendingPathComponent("\(name).json")))
    }

    static let credentials = AWSCredentialSet(accessKeyID: "AKIDEXAMPLE", secretAccessKey: "secret", sessionToken: "SESSIONTOKEN")

    /// Makes the recorded scenario's call through the client.
    static func call(_ service: String, _ client: AWSClient) async throws {
        switch service {
        case "ssm":
            _ = try await client.startSession(target: "i-0123456789abcdef0", documentName: "AWS-StartSSHSession", parameters: ["portNumber": ["22"]])
        case "ec2":
            _ = try await client.describeInstances(instanceIds: ["i-0123456789abcdef0"])
        case "sso-oidc":
            _ = try await client.createToken(clientId: "client-id", clientSecret: "client-secret",
                                             grantType: "urn:ietf:params:oauth:grant-type:device_code", deviceCode: "device-code")
        default:
            Issue.record("unknown service \(service)")
        }
    }

    static func client(_ transport: ScriptedTransport, random: Double = 0.5, sleeps: SleepLog = SleepLog(),
                       region: String = "eu-central-1") -> AWSClient {
        AWSClient(region: region, credentials: credentials, transport: transport,
                  retry: RetryPolicy(random: { random }, sleep: { seconds in try await sleeps.sleep(seconds) }))
    }

    @Test("The recorded scenarios cover each protocol")
    func coverage() {
        #expect(Self.names.count == 14)
        #expect(Set(Self.names.map { $0.split(separator: "-").first! }) == ["ec2", "ssm", "sso"])
    }

    @Test("The recorded SDK delays stay within the strategy's bounds", arguments: names)
    func recordedBounds(_ name: String) throws {
        let fixture = try Self.fixture(name)
        #expect(fixture.delays.count == fixture.attempts - 1)
        for (retry, delay) in fixture.delays.enumerated() {
            // Scheduling adds a little to the sleep the strategy chose.
            #expect(delay <= min(pow(2.0, Double(retry)), 20.0) + 0.25, "\(name) retry \(retry): \(delay)")
        }
    }

    @Test("The client makes the SDK's attempts with the same outcome", arguments: names)
    func attempts(_ name: String) async throws {
        let fixture = try Self.fixture(name)
        let transport = ScriptedTransport(fixture.responses.map { response in
            response.status == 0
                ? .failure(URLError(.networkConnectionLost))
                : .response(HTTPResponse(status: response.status, headers: response.headers.map { ($0[0], $0[1]) }, body: Data(response.body.utf8)))
        })
        let sleeps = SleepLog()
        let client = Self.client(transport, random: 0.5, sleeps: sleeps)
        var succeeded = true
        do { try await Self.call(fixture.service, client) } catch { succeeded = false }
        #expect(transport.attempts == fixture.attempts)
        #expect(succeeded == (fixture.outcome == "success"))
        #expect(await sleeps.values == (0..<(fixture.attempts - 1)).map { 0.5 * pow(2.0, Double($0)) })
    }

    @Test("Delays are random() * 2^retry seconds, capped at 20")
    func delays() async throws {
        for random in [1.0, 0.25, 0.0] {
            let transport = ScriptedTransport([.response(HTTPResponse(status: 503, headers: [], body: Data()))])
            let sleeps = SleepLog()
            await #expect(throws: (any Error).self) { try await Self.call("ssm", Self.client(transport, random: random, sleeps: sleeps)) }
            #expect(await sleeps.values == [random, random * 2])
        }
        #expect(RetryPolicy.delay(retry: 10, random: 1.0) == 20)
        #expect(RetryPolicy.delay(retry: 3, random: 1.0) == 8)
    }

    @Test("Retry settings in the environment and shared config change nothing")
    func settingsIgnored() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config")
        try Data("[default]\nmax_attempts = 7\nretry_mode = adaptive\n".utf8).write(to: config)
        let variables = ["AWS_MAX_ATTEMPTS": "5", "AWS_RETRY_MODE": "adaptive", "AWS_NEW_RETRIES_2026": "true", "AWS_CONFIG_FILE": config.path]
        for (name, value) in variables { EndpointParityTests.setVariable(name, value) }
        defer { for name in variables.keys { EndpointParityTests.setVariable(name, nil) } }

        let transport = ScriptedTransport([.response(HTTPResponse(status: 400, headers: [("x-amzn-ErrorType", "ThrottlingException")],
                                                                  body: Data(#"{"__type":"ThrottlingException"}"#.utf8)))])
        let sleeps = SleepLog()
        await #expect(throws: (any Error).self) { try await Self.call("ssm", Self.client(transport, random: 0.5, sleeps: sleeps)) }
        #expect(transport.attempts == 3)
        #expect(await sleeps.values == [0.5, 1.0])
    }

    @Test("Cancelling during a backoff wait makes no further attempt")
    func cancellationDuringBackoff() async throws {
        let transport = ScriptedTransport([.response(HTTPResponse(status: 503, headers: [], body: Data()))])
        let client = AWSClient(region: "eu-central-1", credentials: Self.credentials, transport: transport,
                               retry: RetryPolicy(random: { 0.5 }, sleep: { _ in throw CancellationError() }))
        await #expect(throws: CancellationError.self) { try await Self.call("ssm", client) }
        #expect(transport.attempts == 1)
    }

    @Test("Timeouts and lost connections are retried; other transport failures are not")
    func transportFailures() async throws {
        let retried: [URLError.Code] = [.timedOut, .networkConnectionLost, .secureConnectionFailed]
        for code in retried {
            let transport = ScriptedTransport([.failure(URLError(code)), .response(HTTPResponse(status: 200, headers: [("Content-Type", "application/x-amz-json-1.1")],
                body: Data(#"{"SessionId":"s","StreamUrl":"wss://x","TokenValue":"t"}"#.utf8)))])
            try await Self.call("ssm", Self.client(transport))
            #expect(transport.attempts == 2, "\(code)")
        }
        for code in [URLError.Code.cannotFindHost, .notConnectedToInternet] {
            let transport = ScriptedTransport([.failure(URLError(code))])
            await #expect(throws: (any Error).self) { try await Self.call("ssm", Self.client(transport)) }
            #expect(transport.attempts == 1, "\(code)")
        }
    }

    @Test("The STS identity request makes exactly one attempt")
    func stsSingleAttempt() async throws {
        for status in [503, 400, 403] {
            let transport = ScriptedTransport([.response(HTTPResponse(status: status, headers: [], body: Data("<ErrorResponse/>".utf8)))])
            let client = Self.client(transport)
            await #expect(throws: (any Error).self) { _ = try await client.getCallerIdentityARN() }
            #expect(transport.attempts == 1, "\(status)")
        }
        let transport = ScriptedTransport([.failure(URLError(.networkConnectionLost))])
        await #expect(throws: (any Error).self) { _ = try await Self.client(transport).getCallerIdentityARN() }
        #expect(transport.attempts == 1)
    }
}

/// Replays outcomes in order; the last repeats.
final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    enum Outcome { case response(HTTPResponse), failure(any Error) }
    private let lock = NSLock()
    private var outcomes: [Outcome]
    private var count = 0

    init(_ outcomes: [Outcome]) { self.outcomes = outcomes }

    var attempts: Int { lock.withLock { count } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let outcome: Outcome = lock.withLock {
            count += 1
            return outcomes.count > 1 ? outcomes.removeFirst() : outcomes[0]
        }
        switch outcome {
        case .response(let response): return response
        case .failure(let error): throw error
        }
    }
}

/// Records requested backoff waits instead of sleeping.
actor SleepLog {
    private(set) var values: [Double] = []
    func sleep(_ seconds: Double) async throws { values.append(seconds) }
}
