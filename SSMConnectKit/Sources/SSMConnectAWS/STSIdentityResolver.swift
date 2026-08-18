import Foundation
import SSMConnectDomain
import SSMConnectWorkflow

/// Resolves the *local* user's own identity by re-executing a presigned
/// `sts:GetCallerIdentity` request and parsing the returned ARN, then mapping it
/// to a Linux username with `IdentityMapper`.
///
/// The client needs this **before** connecting, to target its own DCV session
/// (`sessionid=<user>`). It deliberately reuses `STSPresigner` rather than the
/// AWS SDK — the same primitive that mints the DCV auth token also answers
/// "who am I", so no extra SDK dependency is pulled in.
public struct STSIdentityResolver {
    public typealias Fetch = @Sendable (_ url: URL) async throws -> Data

    public let presigner: STSPresigner
    public var now: @Sendable () -> Date = { Date() }
    public var fetch: Fetch = { url in
        // Ephemeral session: the token-bearing URL must never land in the shared URL cache.
        let (data, response) = try await Self.ephemeralSession.data(from: url)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw IdentityResolveError.stsRejected
        }
        return data
    }

    private static let ephemeralSession = URLSession(configuration: .ephemeral)

    /// Returns the verified caller ARN and the derived Linux username.
    public func resolve(credentials: AWSCredentials) async throws -> (arn: String, username: String) {
        let urlString = presigner.presignedGetCallerIdentityURL(credentials: credentials, now: now())
        guard let url = URL(string: urlString) else { throw IdentityResolveError.badURL }
        let data = try await fetch(url)
        guard let arn = Self.parseArn(data) else { throw IdentityResolveError.noArn }
        let username = try IdentityMapper.username(fromARN: arn)
        return (arn, username)
    }

    /// Extracts the `<Arn>…</Arn>` value from an STS GetCallerIdentity XML response.
    public static func parseArn(_ data: Data) -> String? {
        guard let s = String(data: data, encoding: .utf8),
              let open = s.range(of: "<Arn>"),
              let close = s.range(of: "</Arn>"),
              open.upperBound <= close.lowerBound
        else { return nil }
        return String(s[open.upperBound..<close.lowerBound])
    }
}
