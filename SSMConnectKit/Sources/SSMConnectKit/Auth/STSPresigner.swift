import Foundation
import SSMConnectAWSClient

/// Builds a presigned `sts:GetCallerIdentity` GET URL to use as the DCV
/// connection **auth token** (the HashiCorp Vault / aws-iam-authenticator
/// pattern). The on-box agent's verifier re-executes this URL to recover the
/// verified caller ARN, so the proof of identity is the same AWS credential the
/// SSM tunnel already required, with no password and no new secret store.
///
/// Signing is the shared Signature Version 4 signer in SSMConnectAWSClient, which
/// passes the AWS signing test suite. It must produce a URL the agent's Go verifier
/// accepts (spec §12.4 / ADR-5); STSPresignerTests holds that known answer.
struct STSPresigner {
    let region: String

    var host: String { "sts.\(region).amazonaws.com" }

    /// Produces the presigned URL. `now` is injectable for deterministic tests.
    func presignedGetCallerIdentityURL(
        credentials: AWSCredentials,
        now: Date,
        expiresSeconds: Int = 120
    ) -> String {
        let request = SigV4.Request(
            method: "GET", path: "/", query: "Action=GetCallerIdentity&Version=2011-06-15",
            headers: [("Host", host)]
        )
        let signing = AWSCredentialSet(
            accessKeyID: credentials.accessKeyId,
            secretAccessKey: credentials.secretAccessKey,
            sessionToken: credentials.sessionToken.isEmpty ? nil : credentials.sessionToken
        )
        let result = SigV4.presign(
            request, credentials: signing,
            context: SigV4.Context(region: region, service: "sts", date: now),
            expires: expiresSeconds
        )
        return "https://\(host)/?\(result.signedQuery)"
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
