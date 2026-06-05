import Foundation
import Testing
@testable import SSMConnect

// Task B7 — SSOCacheReader fixture tests (F-05).
// Verifies parsing/matching of ~/.aws/sso/cache/*.json: valid, expired, expired-with-refresh,
// no match, malformed, and write-back via update().
@Suite("SSOCacheReader")
struct SSOCacheReaderTests {

    private static let region = "eu-west-1"

    /// Creates a fresh temp cache directory, writes the given `[filename: json]` files,
    /// and returns a reader pointed at it.
    private func makeReader(files: [String: String]) throws -> (URL, SSOCacheReader) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sso-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, contents) in files {
            try contents.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        return (dir, SSOCacheReader(directory: dir))
    }

    private func tokenJSON(
        startUrl: String,
        expiresAt: String,
        refresh: Bool = false,
        registrationExpiresAt: String? = "2999-01-01T00:00:00Z"
    ) -> String {
        var fields = [
            "\"startUrl\": \"\(startUrl)\"",
            "\"region\": \"\(Self.region)\"",
            "\"accessToken\": \"access-\(startUrl.hashValue)\"",
            "\"expiresAt\": \"\(expiresAt)\""
        ]
        if refresh {
            fields += [
                "\"clientId\": \"client-id\"",
                "\"clientSecret\": \"client-secret\"",
                "\"refreshToken\": \"refresh-token\""
            ]
            if let registrationExpiresAt {
                fields.append("\"registrationExpiresAt\": \"\(registrationExpiresAt)\"")
            }
        }
        return "{\n\(fields.joined(separator: ",\n"))\n}"
    }

    @Test("Returns a non-expired token matched by startUrl + region")
    func validToken() throws {
        let url = "https://valid.awsapps.com/start"
        let (_, reader) = try makeReader(files: [
            "valid.json": tokenJSON(startUrl: url, expiresAt: "2999-01-01T00:00:00Z")
        ])
        let token = try reader.token(startUrl: url, region: Self.region)
        #expect(token != nil)
        #expect(token?.isExpired == false)
        #expect(token?.canRefresh == false)
    }

    @Test("Expired token without a refresh token cannot refresh")
    func expiredTokenNoRefresh() throws {
        let url = "https://expired.awsapps.com/start"
        let (_, reader) = try makeReader(files: [
            "expired.json": tokenJSON(startUrl: url, expiresAt: "2000-01-01T00:00:00Z")
        ])
        let token = try reader.token(startUrl: url, region: Self.region)
        #expect(token?.isExpired == true)
        #expect(token?.canRefresh == false)
    }

    @Test("Expired token with a valid registration can refresh")
    func expiredTokenWithRefresh() throws {
        let url = "https://refresh.awsapps.com/start"
        let (_, reader) = try makeReader(files: [
            "refresh.json": tokenJSON(startUrl: url, expiresAt: "2000-01-01T00:00:00Z", refresh: true)
        ])
        let token = try reader.token(startUrl: url, region: Self.region)
        #expect(token?.isExpired == true)
        #expect(token?.canRefresh == true)
    }

    @Test("Refresh impossible once the client registration itself has expired")
    func expiredRegistrationCannotRefresh() throws {
        let url = "https://stale-reg.awsapps.com/start"
        let (_, reader) = try makeReader(files: [
            "stale.json": tokenJSON(
                startUrl: url,
                expiresAt: "2000-01-01T00:00:00Z",
                refresh: true,
                registrationExpiresAt: "2000-06-01T00:00:00Z"
            )
        ])
        let token = try reader.token(startUrl: url, region: Self.region)
        #expect(token?.canRefresh == false)
    }

    @Test("Returns nil when no file matches the startUrl")
    func noMatch() throws {
        let (_, reader) = try makeReader(files: [
            "valid.json": tokenJSON(startUrl: "https://a.awsapps.com/start", expiresAt: "2999-01-01T00:00:00Z")
        ])
        let token = try reader.token(startUrl: "https://other.awsapps.com/start", region: Self.region)
        #expect(token == nil)
    }

    @Test("Malformed files are skipped without failing the lookup")
    func malformedIgnored() throws {
        let url = "https://valid.awsapps.com/start"
        let (_, reader) = try makeReader(files: [
            "broken.json": "{ this is not valid json",
            "valid.json": tokenJSON(startUrl: url, expiresAt: "2999-01-01T00:00:00Z")
        ])
        let token = try reader.token(startUrl: url, region: Self.region)
        #expect(token?.startUrl == url)
    }

    @Test("update() writes the refreshed access token back to the same file")
    func updateWritesBack() throws {
        let url = "https://refresh.awsapps.com/start"
        let (_, reader) = try makeReader(files: [
            "refresh.json": tokenJSON(startUrl: url, expiresAt: "2000-01-01T00:00:00Z", refresh: true)
        ])
        let original = try #require(try reader.token(startUrl: url, region: Self.region))
        let refreshed = SSOToken(
            startUrl: original.startUrl,
            region: original.region,
            accessToken: "brand-new-access-token",
            expiresAt: Date().addingTimeInterval(3600),
            clientId: original.clientId,
            clientSecret: original.clientSecret,
            refreshToken: original.refreshToken,
            registrationExpiresAt: original.registrationExpiresAt
        )
        try reader.update(refreshed)

        let reloaded = try reader.token(startUrl: url, region: Self.region)
        #expect(reloaded?.accessToken == "brand-new-access-token")
        #expect(reloaded?.isExpired == false)
    }
}
