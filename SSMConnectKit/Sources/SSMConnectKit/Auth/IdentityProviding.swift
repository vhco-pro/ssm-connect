import Foundation

/// Resolves the caller's own AWS identity and mints presigned-identity tokens (multi-user, CL-01/CL-03).
///
/// Behind a protocol for the same reason every other AWS-touching dependency is: the connection
/// flow must be drivable from a conformance fixture with no network. Before this existed the
/// multi-user path constructed `STSPresigner` / `STSIdentityResolver` inline, which made the
/// `IdentityProvider` port of `contracts/state-machine.schema.json` impossible to inject.
protocol IdentityProviding: Sendable {
    /// Resolve the caller's AWS identity to the Linux username the workstation expects.
    func resolveIdentity(region: String, credentials: AWSCredentials) async throws -> String

    /// Mint a presigned-identity token.
    ///
    /// Called fresh per use rather than cached: a presigned URL expires, and a stale one fails the
    /// agent's verifier and DCV's external-token check alike.
    func presignedIdentityToken(region: String, credentials: AWSCredentials) -> String
}

/// Production `IdentityProviding`, backed by `STSPresigner` + `STSIdentityResolver`.
///
/// Both are constructed per call because `STSPresigner` is region-scoped and the region comes from
/// the active profile, which can change between connects.
struct STSIdentityProvider: IdentityProviding {
    var now: @Sendable () -> Date = { Date() }

    func resolveIdentity(region: String, credentials: AWSCredentials) async throws -> String {
        let resolver = STSIdentityResolver(presigner: STSPresigner(region: region), now: now)
        let (_, username) = try await resolver.resolve(credentials: credentials)
        return username
    }

    func presignedIdentityToken(region: String, credentials: AWSCredentials) -> String {
        STSPresigner(region: region).presignedGetCallerIdentityURL(credentials: credentials, now: now())
    }
}
