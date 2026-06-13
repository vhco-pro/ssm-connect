import Testing
import Foundation
@testable import SSMConnect

@Suite("STSIdentityResolver")
struct STSIdentityResolverTests {
    private let creds = AWSCredentials(accessKeyId: "AKID", secretAccessKey: "SEK", sessionToken: "tok", expiration: Date())

    @Test("Resolves ARN -> Linux username from the STS response")
    func resolves() async throws {
        let xml = Data("""
        <GetCallerIdentityResponse><GetCallerIdentityResult>\
        <Arn>arn:aws:sts::1:assumed-role/AWSReservedSSO_x/alice@example.com</Arn>\
        </GetCallerIdentityResult></GetCallerIdentityResponse>
        """.utf8)
        var resolver = STSIdentityResolver(presigner: STSPresigner(region: "eu-central-1"))
        resolver.fetch = { _ in xml }
        let out = try await resolver.resolve(credentials: creds)
        #expect(out.username == "alice")
        #expect(out.arn.hasSuffix("alice@example.com"))
    }

    @Test("STS rejection surfaces as an error")
    func rejection() async {
        var resolver = STSIdentityResolver(presigner: STSPresigner(region: "eu-central-1"))
        resolver.fetch = { _ in throw STSIdentityResolver.IdentityResolveError.stsRejected }
        await #expect(throws: STSIdentityResolver.IdentityResolveError.stsRejected) {
            try await resolver.resolve(credentials: creds)
        }
    }

    @Test("parseArn returns nil when no Arn element is present")
    func parseNil() {
        #expect(STSIdentityResolver.parseArn(Data("<empty/>".utf8)) == nil)
        #expect(STSIdentityResolver.parseArn(Data("<Arn>x</Arn>".utf8)) == "x")
    }
}
