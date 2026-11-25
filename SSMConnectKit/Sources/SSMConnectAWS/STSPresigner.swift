import Foundation
import SSMConnectDomain
import SSMConnectAWSClient

/// Builds a presigned `sts:GetCallerIdentity` GET URL to use as the DCV
/// connection **auth token** (the HashiCorp Vault / aws-iam-authenticator
/// pattern). The on-box agent's verifier re-executes this URL to recover the
/// verified caller ARN, so the proof of identity is the same AWS credential the
/// SSM tunnel already required, with no password and no new secret store.
///
/// The URL comes from the shared AWS client: its endpoint resolver gives the STS
/// host (`amazonaws.com.cn` in China regions) and its Signature Version 4 signer,
/// which passes the AWS signing test suite, signs it. It must produce a URL the
/// agent's Go verifier accepts (spec §12.4 / ADR-5); STSPresignerTests holds that
/// known answer.
package struct STSPresigner {
    package let region: String

    /// Produces the presigned URL. `now` is injectable for deterministic tests.
    package func presignedGetCallerIdentityURL(
        credentials: AWSCredentials,
        now: Date,
        expiresSeconds: Int = 120
    ) throws -> String {
        try AWSClient(region: region, credentials: credentials.signingCredentials, now: { now })
            .presignedCallerIdentityURL(expires: expiresSeconds).absoluteString
    }

    package init(region: String) {
        self.region = region
    }
}
