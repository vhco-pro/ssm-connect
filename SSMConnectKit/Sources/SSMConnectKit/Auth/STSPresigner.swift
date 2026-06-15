import Foundation
import CryptoKit

/// Builds a presigned `sts:GetCallerIdentity` GET URL to use as the DCV
/// connection **auth token** (the HashiCorp Vault / aws-iam-authenticator
/// pattern). The on-box agent's verifier re-executes this URL to recover the
/// verified caller ARN — so the proof of identity is the same AWS credential the
/// SSM tunnel already required, with no password and no new secret store.
///
/// This is a hand-rolled SigV4 query presign (CryptoKit HMAC-SHA256), matching
/// the algorithm validated in the spike. It must produce a URL the agent's Go
/// verifier accepts (spec §12.4 / ADR-5).
struct STSPresigner {
    let region: String

    var host: String { "sts.\(region).amazonaws.com" }

    /// Produces the presigned URL. `now` is injectable for deterministic tests.
    func presignedGetCallerIdentityURL(
        credentials: AWSCredentials,
        now: Date,
        expiresSeconds: Int = 120
    ) -> String {
        let amzDate = Self.amzDate(now)
        let dateStamp = Self.dateStamp(now)
        let scope = "\(dateStamp)/\(region)/sts/aws4_request"

        var query: [(String, String)] = [
            ("Action", "GetCallerIdentity"),
            ("Version", "2011-06-15"),
            ("X-Amz-Algorithm", "AWS4-HMAC-SHA256"),
            ("X-Amz-Credential", "\(credentials.accessKeyId)/\(scope)"),
            ("X-Amz-Date", amzDate),
            ("X-Amz-Expires", String(expiresSeconds)),
            ("X-Amz-SignedHeaders", "host"),
        ]
        if !credentials.sessionToken.isEmpty {
            query.append(("X-Amz-Security-Token", credentials.sessionToken))
        }

        // Canonical query string: RFC3986-encode each key/value, then sort by encoded key.
        let canonicalQuery = query
            .map { (Self.rfc3986(($0.0)), Self.rfc3986($0.1)) }
            .sorted { $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }
            .joined(separator: "&")

        let canonicalRequest = [
            "GET",
            "/",
            canonicalQuery,
            "host:\(host)\n",          // canonical headers (each terminated by \n)
            "host",                    // signed headers
            Self.sha256Hex(Data()),    // empty-payload hash
        ].joined(separator: "\n")

        let stringToSign = [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            Self.sha256Hex(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        let signingKey = Self.signingKey(
            secret: credentials.secretAccessKey,
            dateStamp: dateStamp,
            region: region,
            service: "sts"
        )
        let signature = Self.hexHMAC(key: signingKey, data: Data(stringToSign.utf8))
        return "https://\(host)/?\(canonicalQuery)&X-Amz-Signature=\(signature)"
    }

    // MARK: - SigV4 primitives

    static func signingKey(secret: String, dateStamp: String, region: String, service: String) -> SymmetricKey {
        let kDate = hmac(key: SymmetricKey(data: Data("AWS4\(secret)".utf8)), data: Data(dateStamp.utf8))
        let kRegion = hmac(key: SymmetricKey(data: kDate), data: Data(region.utf8))
        let kService = hmac(key: SymmetricKey(data: kRegion), data: Data(service.utf8))
        let kSigning = hmac(key: SymmetricKey(data: kService), data: Data("aws4_request".utf8))
        return SymmetricKey(data: kSigning)
    }

    private static func hmac(key: SymmetricKey, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: key))
    }

    static func hexHMAC(key: SymmetricKey, data: Data) -> String {
        hex(hmac(key: key, data: data))
    }

    static func sha256Hex(_ data: Data) -> String {
        hex(Data(SHA256.hash(data: data)))
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// RFC3986 encoding per SigV4: only `A-Za-z0-9-_.~` are unreserved; everything
    /// else is percent-encoded with uppercase hex (note `/` becomes `%2F`).
    static func rfc3986(_ s: String) -> String {
        let unreserved = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~"
        var allowed = CharacterSet()
        allowed.insert(charactersIn: unreserved)
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    // MARK: - Date helpers (UTC, fixed format)

    private static func amzDate(_ date: Date) -> String { formatter("yyyyMMdd'T'HHmmss'Z'").string(from: date) }
    private static func dateStamp(_ date: Date) -> String { formatter("yyyyMMdd").string(from: date) }

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = format
        return f
    }
}
