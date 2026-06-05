import Foundation

/// Reads (and silently updates) the AWS SSO token cache (F-05, B2).
///
/// Behind a protocol so `AWSAuthProvider` can be unit-tested with fixture tokens
/// instead of touching the real `~/.aws/sso/cache/` directory.
protocol SSOCacheReading: Sendable {
    /// Returns the cached token matching `startUrl` + `region`, or `nil` if none exists.
    func token(startUrl: String, region: String) throws -> SSOToken?

    /// Writes a refreshed token back to its existing cache file, preserving any other
    /// fields. Best-effort: the app never creates *additional* token files (NF-01).
    func update(_ token: SSOToken) throws
}

/// Default `SSOCacheReading` backed by `~/.aws/sso/cache/*.json`.
struct SSOCacheReader: SSOCacheReading {
    private let directory: URL

    /// - Parameter directory: the cache directory; defaults to `~/.aws/sso/cache`.
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".aws/sso/cache", isDirectory: true)
    }

    func token(startUrl: String, region: String) throws -> SSOToken? {
        guard let match = try matchingFile(startUrl: startUrl, region: region) else { return nil }
        return match.token
    }

    func update(_ token: SSOToken) throws {
        guard let match = try matchingFile(startUrl: token.startUrl, region: token.region) else { return }
        // Re-read as a mutable JSON object so we preserve fields we don't model.
        let data = try Data(contentsOf: match.url)
        var object = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        object["accessToken"] = token.accessToken
        object["expiresAt"] = Self.isoString(from: token.expiresAt)
        if let refreshToken = token.refreshToken { object["refreshToken"] = refreshToken }
        let updated = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try updated.write(to: match.url, options: .atomic)
    }

    // MARK: - Private

    private func matchingFile(startUrl: String, region: String) throws -> (url: URL, token: SSOToken)? {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: directory,
                                                         includingPropertiesForKeys: nil) else {
            return nil
        }
        for url in entries where url.pathExtension.lowercased() == "json" {
            guard let data = try? Data(contentsOf: url),
                  let raw = try? JSONDecoder().decode(RawSSOToken.self, from: data),
                  let token = raw.toToken() else { continue }
            if token.startUrl == startUrl && token.region == region {
                return (url, token)
            }
        }
        return nil
    }

    // MARK: - Decoding

    /// Mirror of the on-disk cache JSON. `accessToken`, `expiresAt`, `startUrl`, and
    /// `region` are required for a usable token; the rest are optional.
    private struct RawSSOToken: Decodable {
        let startUrl: String?
        let region: String?
        let accessToken: String?
        let expiresAt: String?
        let clientId: String?
        let clientSecret: String?
        let refreshToken: String?
        let registrationExpiresAt: String?

        func toToken() -> SSOToken? {
            guard let startUrl, let region,
                  let accessToken, !accessToken.isEmpty,
                  let expiresAt, let expiry = SSOCacheReader.date(from: expiresAt) else {
                return nil
            }
            return SSOToken(
                startUrl: startUrl,
                region: region,
                accessToken: accessToken,
                expiresAt: expiry,
                clientId: clientId,
                clientSecret: clientSecret,
                refreshToken: refreshToken,
                registrationExpiresAt: registrationExpiresAt.flatMap(SSOCacheReader.date(from:))
            )
        }
    }

    /// Parses ISO-8601 timestamps as written by the AWS CLI (with or without fractional
    /// seconds), e.g. `2026-06-05T20:00:00Z` or `2026-06-05T20:00:00.123Z`.
    static func date(from string: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    static func isoString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
