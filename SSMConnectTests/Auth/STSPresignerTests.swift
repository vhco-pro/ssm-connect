import Testing
import Foundation
@testable import SSMConnect

@Suite("STSPresigner")
struct STSPresignerTests {
    /// Cross-implementation known-answer: the same fixed inputs were signed with an
    /// independent Python SigV4 implementation; the signature must match exactly, so
    /// the token this client mints is one the agent's Go verifier will accept.
    @Test("Presigned GetCallerIdentity matches the known-answer reference")
    func knownAnswer() {
        let creds = AWSCredentials(
            accessKeyId: "AKIDEXAMPLE",
            secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
            sessionToken: "SESSIONTOKEN123",
            expiration: Date(timeIntervalSince1970: 0)
        )
        let url = STSPresigner(region: "eu-central-1").presignedGetCallerIdentityURL(
            credentials: creds,
            now: Date(timeIntervalSince1970: 1_781_352_000), // 2026-06-13T12:00:00Z
            expiresSeconds: 120
        )
        let expected = "https://sts.eu-central-1.amazonaws.com/?"
            + "Action=GetCallerIdentity&Version=2011-06-15"
            + "&X-Amz-Algorithm=AWS4-HMAC-SHA256"
            + "&X-Amz-Credential=AKIDEXAMPLE%2F20260613%2Feu-central-1%2Fsts%2Faws4_request"
            + "&X-Amz-Date=20260613T120000Z&X-Amz-Expires=120"
            + "&X-Amz-Security-Token=SESSIONTOKEN123&X-Amz-SignedHeaders=host"
            + "&X-Amz-Signature=72867d630efb3316185feb18215d315ab7e98ea73a7823946a3b07e755ac8aa2"
        #expect(url == expected)
    }

    @Test("Empty session token is omitted; shape is a valid STS GetCallerIdentity URL")
    func shapeWithoutSessionToken() {
        let creds = AWSCredentials(accessKeyId: "AKID", secretAccessKey: "SEKRIT", sessionToken: "", expiration: Date())
        let url = STSPresigner(region: "us-east-1").presignedGetCallerIdentityURL(credentials: creds, now: Date())
        #expect(url.hasPrefix("https://sts.us-east-1.amazonaws.com/?"))
        #expect(url.contains("Action=GetCallerIdentity"))
        #expect(url.contains("X-Amz-Signature="))
        #expect(!url.contains("X-Amz-Security-Token"))
    }
}
