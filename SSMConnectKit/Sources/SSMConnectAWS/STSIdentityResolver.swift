import Foundation
import SSMConnectDomain
import SSMConnectAWSClient

/// Resolves the *local* user's own identity by re-executing a presigned
/// `sts:GetCallerIdentity` request and parsing the returned ARN, then mapping it
/// to a Linux username with `IdentityMapper`.
///
/// The client needs this **before** connecting, to target its own DCV session
/// (`sessionid=<user>`). It sends through the shared AWS client's
/// `getCallerIdentityARN`: the presigned URL from the client's endpoint resolver,
/// sent once with no retry and no clock-skew correction, failing on any
/// non-success response.
package struct STSIdentityResolver {
    package let presigner: STSPresigner
    package var now: @Sendable () -> Date = { Date() }
    package var transport: any HTTPTransport = URLSessionTransport()

    package enum IdentityResolveError: Error, Equatable, LocalizedError {
        case badURL
        case stsRejected
        case noArn

        package var errorDescription: String? {
            switch self {
            case .badURL: "Couldn't build the identity request."
            case .stsRejected: "AWS rejected the identity request — your session may have expired."
            case .noArn: "Couldn't determine your AWS identity."
            }
        }
    }

    /// Returns the verified caller ARN and the derived Linux username.
    package func resolve(credentials: AWSCredentials) async throws -> (arn: String, username: String) {
        let client = AWSClient(region: presigner.region, credentials: credentials.signingCredentials,
                               transport: transport, now: now)
        let arn: String
        do {
            arn = try await client.getCallerIdentityARN()
        } catch AWSClientError.identityRejected {
            throw IdentityResolveError.stsRejected
        } catch AWSClientError.malformedResponse {
            throw IdentityResolveError.noArn
        } catch is AWSEndpoints.ResolveError {
            throw IdentityResolveError.badURL
        }
        let username = try IdentityMapper.username(fromARN: arn)
        return (arn, username)
    }

    package init(presigner: STSPresigner, now: @escaping @Sendable () -> Date = { Date() }, transport: any HTTPTransport = URLSessionTransport()) {
        self.presigner = presigner
        self.now = now
        self.transport = transport
    }
}
