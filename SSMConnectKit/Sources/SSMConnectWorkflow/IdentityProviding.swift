import Foundation
import SSMConnectDomain

/// Resolves the caller's own AWS identity and mints presigned-identity tokens (multi-user, CL-01/CL-03).
///
/// Behind a protocol for the same reason every other AWS-touching dependency is: the connection
/// flow must be drivable from a conformance fixture with no network. Before this existed the
/// multi-user path constructed `STSPresigner` / `STSIdentityResolver` inline, which made the
/// `IdentityProvider` port of `contracts/state-machine.schema.json` impossible to inject.
public protocol IdentityProviding: Sendable {
    /// Resolve the caller's AWS identity to the Linux username the workstation expects.
    func resolveIdentity(region: String, credentials: AWSCredentials) async throws -> String

    /// Mint a presigned-identity token.
    ///
    /// Called fresh per use rather than cached: a presigned URL expires, and a stale one fails the
    /// agent's verifier and DCV's external-token check alike.
    func presignedIdentityToken(region: String, credentials: AWSCredentials) -> String
}

/// Why the caller's own AWS identity could not be resolved.
///
/// Declared with the port rather than with the STS adapter because `ErrorCategory` branches on it:
/// STS refusing the presigned request means the session is gone, which is an authentication
/// failure, not an unclassified one.
public enum IdentityResolveError: Error, Equatable, LocalizedError {
    case badURL
    case stsRejected
    case noArn

    public var errorDescription: String? {
        switch self {
        case .badURL: "Couldn't build the identity request."
        case .stsRejected: "AWS rejected the identity request — your session may have expired."
        case .noArn: "Couldn't determine your AWS identity."
        }
    }
}

