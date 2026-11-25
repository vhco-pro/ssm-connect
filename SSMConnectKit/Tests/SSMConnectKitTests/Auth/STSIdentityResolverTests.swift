import Testing
import Foundation
import SSMConnectAWSClient
@testable import SSMConnectKit

@Suite("STSIdentityResolver")
struct STSIdentityResolverTests {
    private let creds = AWSCredentials(accessKeyId: "AKID", secretAccessKey: "SEK", sessionToken: "tok", expiration: Date())

    private static let identityXML = """
    <GetCallerIdentityResponse><GetCallerIdentityResult>\
    <Arn>arn:aws:sts::1:assumed-role/AWSReservedSSO_x/alice@example.com</Arn>\
    </GetCallerIdentityResult></GetCallerIdentityResponse>
    """

    /// Records each request and answers from `reply`.
    final class Transport: HTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [HTTPRequest] = []
        let reply: @Sendable () throws -> HTTPResponse
        init(_ reply: @escaping @Sendable () throws -> HTTPResponse) { self.reply = reply }
        var requests: [HTTPRequest] { lock.withLock { seen } }
        func send(_ request: HTTPRequest) async throws -> HTTPResponse {
            lock.withLock { seen.append(request) }
            return try reply()
        }
    }

    @Test("Resolves ARN -> Linux username through the AWS client's transport")
    func resolves() async throws {
        let transport = Transport { HTTPResponse(status: 200, body: Data(Self.identityXML.utf8)) }
        let resolver = STSIdentityResolver(presigner: STSPresigner(region: "eu-central-1"), transport: transport)
        let out = try await resolver.resolve(credentials: creds)
        #expect(out.username == "alice")
        #expect(out.arn.hasSuffix("alice@example.com"))
        #expect(transport.requests.count == 1)
        #expect(transport.requests.first?.method == "GET")
        #expect(transport.requests.first?.url.host == "sts.eu-central-1.amazonaws.com")
        #expect(transport.requests.first?.url.query?.contains("Action=GetCallerIdentity") == true)
    }

    @Test("A China region sends to the amazonaws.com.cn host")
    func chinaHost() async throws {
        let transport = Transport { HTTPResponse(status: 200, body: Data(Self.identityXML.utf8)) }
        let resolver = STSIdentityResolver(presigner: STSPresigner(region: "cn-north-1"), transport: transport)
        _ = try await resolver.resolve(credentials: creds)
        #expect(transport.requests.first?.url.host == "sts.cn-north-1.amazonaws.com.cn")
    }

    @Test("A 503 is not retried and surfaces as an STS rejection")
    func singleAttemptOn503() async {
        let transport = Transport { HTTPResponse(status: 503, body: Data("<Error/>".utf8)) }
        let resolver = STSIdentityResolver(presigner: STSPresigner(region: "eu-central-1"), transport: transport)
        await #expect(throws: STSIdentityResolver.IdentityResolveError.stsRejected) {
            try await resolver.resolve(credentials: creds)
        }
        #expect(transport.requests.count == 1)
    }

    @Test("A lost connection is not retried")
    func singleAttemptOnLostConnection() async {
        let transport = Transport { throw URLError(.networkConnectionLost) }
        let resolver = STSIdentityResolver(presigner: STSPresigner(region: "eu-central-1"), transport: transport)
        await #expect(throws: URLError.self) {
            try await resolver.resolve(credentials: creds)
        }
        #expect(transport.requests.count == 1)
    }

    @Test("A response without an Arn surfaces as noArn")
    func noArn() async {
        let transport = Transport { HTTPResponse(status: 200, body: Data("<empty/>".utf8)) }
        let resolver = STSIdentityResolver(presigner: STSPresigner(region: "eu-central-1"), transport: transport)
        await #expect(throws: STSIdentityResolver.IdentityResolveError.noArn) {
            try await resolver.resolve(credentials: creds)
        }
    }
}
