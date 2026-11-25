import Foundation
import Testing
@testable import SSMConnectAWS
@testable import SSMConnectDomain
@testable import SSMConnectWorkflow

/// The SSO token cache holds tokens, so every write leaves it owner-only by the platform's own
/// rules: mode 0600 on macOS and Linux, a protected DACL for the current user on Windows (AC-19).
/// An existing file keeps its unmodelled fields.
@Suite("SSO cache writer")
struct SSOCacheWriterTests {
    static let startURL = "https://d-0123456789.awsapps.com/start"

    static func token(_ access: String) -> SSOToken {
        SSOToken(startUrl: startURL, region: "eu-west-1", accessToken: access, expiresAt: Date().addingTimeInterval(3600),
                 clientId: "client", clientSecret: "client-secret", refreshToken: "refresh", registrationExpiresAt: nil)
    }

    static func isOwnerOnly(_ url: URL) throws -> Bool {
        #if os(Windows)
        return OwnerOnlyFiles.windows.isOwnerOnly(url, [:])
        #else
        return OwnerOnlyFiles.posix.isOwnerOnly(url, try FileManager.default.attributesOfItem(atPath: url.path))
        #endif
    }

    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sso-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("A new cache file is owner-only")
    func newFile() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try SSOCacheReader(directory: directory).update(Self.token("first"))
        let file = directory.appendingPathComponent(SSOCacheReader.cacheKey(for: Self.startURL) + ".json")
        #expect(try Self.isOwnerOnly(file))
        #expect(try SSOCacheReader(directory: directory).token(startUrl: Self.startURL, region: "eu-west-1")?.accessToken == "first")
    }

    @Test("Updating a file another tool wrote leaves it owner-only with its other fields")
    func existingFile() throws {
        let directory = try Self.directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("written-by-the-cli.json")
        let existing = ["startUrl": Self.startURL, "region": "eu-west-1", "accessToken": "old",
                        "expiresAt": "2020-01-01T00:00:00Z", "unmodelled": "kept"]
        try JSONSerialization.data(withJSONObject: existing).write(to: file)
        #if !os(Windows)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        #endif
        try SSOCacheReader(directory: directory).update(Self.token("second"))
        #expect(try Self.isOwnerOnly(file))
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        #expect(object?["accessToken"] as? String == "second" && object?["unmodelled"] as? String == "kept")
    }
}
