import Foundation
import SSMConnectDomain
import SSMConnectWorkflow

/// Production `IdentityProviding`, backed by `STSPresigner` + `STSIdentityResolver`.
///
/// Both are constructed per call because `STSPresigner` is region-scoped and the region comes from
/// the active profile, which can change between connects.
public struct STSIdentityProvider: IdentityProviding {
    public init() {}

    public var now: @Sendable () -> Date = { Date() }

    public func resolveIdentity(region: String, credentials: AWSCredentials) async throws -> String {
        let resolver = STSIdentityResolver(presigner: STSPresigner(region: region), now: now)
        let (_, username) = try await resolver.resolve(credentials: credentials)
        return username
    }

    public func presignedIdentityToken(region: String, credentials: AWSCredentials) -> String {
        STSPresigner(region: region).presignedGetCallerIdentityURL(credentials: credentials, now: now())
    }
}
