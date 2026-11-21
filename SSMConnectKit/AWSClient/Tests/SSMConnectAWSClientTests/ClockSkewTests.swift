import Foundation
import Testing
@testable import SSMConnectAWSClient

/// Clock-skew correction parity with the pinned aws-sdk-swift (Fixtures/skew, recorded by
/// FixtureRecorder from aws-sdk-swift 1.7.62 `AWSClockSkewProvider` and smithy-swift
/// `ClockSkewStore`). Each test uses its own store, so learned offsets never leak.
@Suite("Clock skew")
struct ClockSkewTests {
    struct Fixture: Decodable {
        struct Response: Decodable { let status: Int; let headers: [[String]]; let body: String }
        struct Dated: Decodable { let response: Response; let dateOffsetSeconds: Double? }
        struct Attempt: Decodable { let signedOffsetSeconds: Double }
        struct Call: Decodable { let attempts: [Attempt]; let outcome: String }
        let name: String
        let service: String
        let responses: [Dated]
        let calls: [Call]
    }

    static let directory = Bundle.module.url(forResource: "Fixtures/skew", withExtension: nil)!
    static var names: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }
    static func fixture(_ name: String) throws -> Fixture {
        try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: directory.appendingPathComponent("\(name).json")))
    }

    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let nineHours = 9.0 * 3600
    static let credentials = AWSCredentialSet(accessKeyID: "AKIDEXAMPLE", secretAccessKey: "secret", sessionToken: "token")

    static func client(_ transport: SkewTransport, store: ClockSkewStore, sleeps: SleepLog = SleepLog(),
                       region: String = "eu-central-1") -> AWSClient {
        AWSClient(region: region, credentials: credentials, transport: transport, now: { now },
                  retry: RetryPolicy(random: { 0.5 }, sleep: { try await sleeps.sleep($0) }), clockSkew: store)
    }

    static func call(_ service: String, _ client: AWSClient) async throws {
        switch service {
        case "ssm": _ = try await client.startSession(target: "i-0123456789abcdef0", documentName: "AWS-StartSSHSession", parameters: ["portNumber": ["22"]])
        default: _ = try await client.describeInstances(instanceIds: ["i-0123456789abcdef0"])
        }
    }

    static func ec2Error(_ status: Int, _ code: String, dateOffset: Double?) -> SkewTransport.Reply {
        .init(status: status, headers: [("Content-Type", "text/xml")], dateOffset: dateOffset,
              body: "<Response><Errors><Error><Code>\(code)</Code><Message>m</Message></Error></Errors></Response>")
    }
    static func ec2OK(dateOffset: Double?) -> SkewTransport.Reply {
        .init(status: 200, headers: [("Content-Type", "text/xml")], dateOffset: dateOffset,
              body: "<DescribeInstancesResponse><reservationSet/></DescribeInstancesResponse>")
    }

    @Test("The recorded scenarios are present")
    func coverage() {
        #expect(Self.names.count == 10)
    }

    @Test("The client corrects skew as the SDK did", arguments: names)
    func parity(_ name: String) async throws {
        let fixture = try Self.fixture(name)
        let replies = fixture.responses.map { dated in
            SkewTransport.Reply(status: dated.response.status, headers: dated.response.headers.map { ($0[0], $0[1]) },
                                dateOffset: dated.dateOffsetSeconds, body: dated.response.body)
        }
        // The concurrent scenario holds both first requests until both have been sent, as the
        // recorder did, so both fail before either learns the offset.
        let transport = SkewTransport(replies, now: Self.now, holdFirst: name.contains("concurrent") ? 2 : 0)
        let client = Self.client(transport, store: ClockSkewStore())
        let recorded = fixture.calls[0]
        var outcomes: [String] = []
        if name.contains("concurrent") {
            outcomes = await withTaskGroup(of: String.self) { group in
                for _ in 0..<2 {
                    group.addTask { do { try await Self.call(fixture.service, client); return "success" } catch { return "error" } }
                }
                var results: [String] = []
                for await result in group { results.append(result) }
                return results.sorted()
            }
        } else {
            let count = recorded.outcome.components(separatedBy: ", ").count
            for _ in 0..<count {
                do { try await Self.call(fixture.service, client); outcomes.append("success") } catch { outcomes.append("error") }
            }
        }
        let expectedOutcomes = recorded.outcome.components(separatedBy: ", ").map { $0.hasPrefix("error") ? "error" : "success" }.sorted()
        #expect(outcomes.sorted() == expectedOutcomes)
        let offsets = transport.signedOffsets
        #expect(offsets.count == recorded.attempts.count)
        for (sent, expected) in zip(offsets, recorded.attempts.map(\.signedOffsetSeconds)) {
            #expect(abs(sent - expected) <= 5, "\(name): signed offset \(sent), SDK \(expected)")
        }
    }

    @Test("A learned offset applies to that host only")
    func perHost() async throws {
        let store = ClockSkewStore()
        let ec2 = SkewTransport([Self.ec2Error(401, "AuthFailure", dateOffset: Self.nineHours), Self.ec2OK(dateOffset: Self.nineHours)], now: Self.now)
        try await Self.call("ec2", Self.client(ec2, store: store))
        let ssm = SkewTransport([.init(status: 200, headers: [("Content-Type", "application/x-amz-json-1.1")], dateOffset: 0,
                                       body: #"{"SessionId":"s","StreamUrl":"wss://x","TokenValue":"t"}"#)], now: Self.now)
        try await Self.call("ssm", Self.client(ssm, store: store))
        #expect(ssm.signedOffsets == [0])
        #expect(await store.offset(host: "ec2.eu-central-1.amazonaws.com") == Self.nineHours)
    }

    @Test("A new difference within 60 seconds of the stored offset keeps it; a larger change replaces it")
    func changeThreshold() async throws {
        let store = ClockSkewStore()
        try await Self.call("ec2", Self.client(SkewTransport([Self.ec2Error(401, "AuthFailure", dateOffset: Self.nineHours), Self.ec2OK(dateOffset: Self.nineHours)], now: Self.now), store: store))
        // Unchanged within 60 s: not a skew retry, and AuthFailure is not otherwise retried.
        let small = SkewTransport([Self.ec2Error(401, "AuthFailure", dateOffset: Self.nineHours + 30)], now: Self.now)
        await #expect(throws: AWSServiceError.self) { try await Self.call("ec2", Self.client(small, store: store)) }
        #expect(small.signedOffsets.count == 1)
        #expect(await store.offset(host: "ec2.eu-central-1.amazonaws.com") == Self.nineHours)
        // Changed by 2 minutes: replaced and retried with the new offset.
        let large = SkewTransport([Self.ec2Error(401, "AuthFailure", dateOffset: Self.nineHours + 120), Self.ec2OK(dateOffset: Self.nineHours + 120)], now: Self.now)
        try await Self.call("ec2", Self.client(large, store: store))
        #expect(large.signedOffsets.map { $0.rounded() } == [Self.nineHours, Self.nineHours + 120])
    }

    @Test("The difference is taken from the unadjusted local time, not the offset signing time")
    func unadjustedLocalTime() async throws {
        let store = ClockSkewStore()
        try await Self.call("ec2", Self.client(SkewTransport([Self.ec2Error(401, "AuthFailure", dateOffset: Self.nineHours), Self.ec2OK(dateOffset: Self.nineHours)], now: Self.now), store: store))
        // The server is still 9 h ahead of local time: from local time that matches the stored
        // offset, so nothing changes. Measured from the offset signing time it would look near
        // and wrongly clear the offset.
        let again = SkewTransport([Self.ec2Error(401, "AuthFailure", dateOffset: Self.nineHours)], now: Self.now)
        await #expect(throws: AWSServiceError.self) { try await Self.call("ec2", Self.client(again, store: store)) }
        #expect(again.signedOffsets.count == 1)
        #expect(await store.offset(host: "ec2.eu-central-1.amazonaws.com") == Self.nineHours)
    }

    @Test("Only a difference beyond 300 seconds is learned", arguments: [(290.0, false), (310.0, true), (-310.0, true)])
    func skewThreshold(_ offset: Double, _ learned: Bool) async throws {
        let store = ClockSkewStore()
        let transport = SkewTransport([Self.ec2Error(401, "AuthFailure", dateOffset: offset), Self.ec2OK(dateOffset: offset)], now: Self.now)
        let client = Self.client(transport, store: store)
        if learned {
            try await Self.call("ec2", client)
            #expect(transport.signedOffsets.map { $0.rounded() } == [0, offset])
            #expect(await store.offset(host: "ec2.eu-central-1.amazonaws.com") == offset)
        } else {
            await #expect(throws: AWSServiceError.self) { try await Self.call("ec2", client) }
            #expect(transport.signedOffsets.count == 1)
            #expect(await store.offset(host: "ec2.eu-central-1.amazonaws.com") == nil)
        }
    }

    @Test("A missing or unparseable Date header clears a stored offset and retries", arguments: ["missing", "invalid"])
    func badDateClears(_ kind: String) async throws {
        let store = ClockSkewStore()
        try await Self.call("ec2", Self.client(SkewTransport([Self.ec2Error(401, "AuthFailure", dateOffset: Self.nineHours), Self.ec2OK(dateOffset: Self.nineHours)], now: Self.now), store: store))
        let dateHeader: [(String, String)] = kind == "invalid" ? [("Date", "not a date")] : []
        let garbled = SkewTransport([
            .init(status: 401, headers: [("Content-Type", "text/xml")] + dateHeader, dateOffset: nil,
                  body: "<Response><Errors><Error><Code>AuthFailure</Code></Error></Errors></Response>"),
            Self.ec2OK(dateOffset: 0),
        ], now: Self.now)
        try await Self.call("ec2", Self.client(garbled, store: store))
        #expect(garbled.signedOffsets.map { $0.rounded() } == [Self.nineHours, 0])
        #expect(await store.offset(host: "ec2.eu-central-1.amazonaws.com") == nil)
    }

    @Test("A skew retry counts as an attempt and waits its backoff")
    func retryUsesPolicy() async throws {
        let sleeps = SleepLog()
        let transport = SkewTransport([Self.ec2Error(401, "AuthFailure", dateOffset: Self.nineHours), Self.ec2Error(500, "InternalError", dateOffset: Self.nineHours)], now: Self.now)
        await #expect(throws: AWSServiceError.self) { try await Self.call("ec2", Self.client(transport, store: ClockSkewStore(), sleeps: sleeps)) }
        // Attempt 1 (skew), attempt 2 (500, retryable), attempt 3 (500): three attempts in total.
        #expect(transport.signedOffsets.count == 3)
        #expect(await sleeps.values == [0.5, 1.0])
    }
}

/// Replies in order (the last repeats), stamping each reply's Date header at the client's
/// fixed time plus its offset, and recording each request's signing offset.
final class SkewTransport: HTTPTransport, @unchecked Sendable {
    struct Reply {
        var status: Int
        var headers: [(String, String)]
        var dateOffset: Double?
        var body: String
    }
    private let lock = NSLock()
    private var replies: [Reply]
    private var offsets: [Double] = []
    private let holdFirst: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []
    let now: Date

    /// `holdFirst` requests are held until that many have arrived, then released together.
    init(_ replies: [Reply], now: Date, holdFirst: Int = 0) {
        self.replies = replies
        self.now = now
        self.holdFirst = holdFirst
    }

    var signedOffsets: [Double] { lock.withLock { offsets } }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let reply: Reply = lock.withLock {
            let header = request.headers.first { $0.0.lowercased() == "x-amz-date" }?.1 ?? ""
            offsets.append(Self.amzDate(header).map { $0.timeIntervalSince(now) } ?? .nan)
            return replies.count > 1 ? replies.removeFirst() : replies[0]
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let release: [CheckedContinuation<Void, Never>] = lock.withLock {
                guard offsets.count <= holdFirst, holdFirst > 0 else { return [continuation] }
                waiting.append(continuation)
                guard waiting.count == holdFirst else { return [] }
                defer { waiting = [] }
                return waiting
            }
            release.forEach { $0.resume() }
        }
        var headers = reply.headers
        if let offset = reply.dateOffset { headers.append(("Date", Self.httpDate(now.addingTimeInterval(offset)))) }
        return HTTPResponse(status: reply.status, headers: headers, body: Data(reply.body.utf8))
    }

    static func httpDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f.string(from: date)
    }

    static func amzDate(_ text: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f.date(from: text)
    }
}
