import Foundation
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
struct STSPresigner {
    let region: String

    /// Produces the presigned URL. `now` is injectable for deterministic tests.
    func presignedGetCallerIdentityURL(
        credentials: AWSCredentials,
        now: Date,
        expiresSeconds: Int = 120
    ) throws -> String {
        try AWSClient(region: region, credentials: credentials.signingCredentials, now: { now })
            .presignedCallerIdentityURL(expires: expiresSeconds).absoluteString
    }

    /// RFC3986 encoding per SigV4: only `A-Za-z0-9-_.~` are unreserved; everything
    /// else is percent-encoded with uppercase hex (note `/` becomes `%2F`).
    static func rfc3986(_ s: String) -> String {
        let unreserved = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~"
        var allowed = CharacterSet()
        allowed.insert(charactersIn: unreserved)
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

extension AWSCredentials {
    /// The credentials in the AWS client's form; an empty session token is omitted.
    var signingCredentials: AWSCredentialSet {
        AWSCredentialSet(accessKeyID: accessKeyId, secretAccessKey: secretAccessKey,
                         sessionToken: sessionToken.isEmpty ? nil : sessionToken)
    }
}
