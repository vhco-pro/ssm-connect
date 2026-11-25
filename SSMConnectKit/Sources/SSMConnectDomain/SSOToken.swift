import Foundation

/// A parsed AWS SSO token from `~/.aws/sso/cache/*.json` (F-05).
///
/// The cache format is identical to AWS CLI v2 (spike-confirmed, spec §12.1): a recent
/// `aws sso login` produces a file the app can reuse, and the `refreshToken` +
/// `clientId`/`clientSecret` enable a silent `CreateToken grant_type=refresh_token`
/// before any browser prompt.
package struct SSOToken: Equatable, Sendable {
    package let startUrl: String
    package let region: String
    package let accessToken: String
    package let expiresAt: Date

    // Present when the token was minted via the device-authorization flow; required for
    // silent refresh.
    package let clientId: String?
    package let clientSecret: String?
    package let refreshToken: String?
    package let registrationExpiresAt: Date?

    /// Whether the `accessToken` is at or past its expiry.
    package var isExpired: Bool { isExpired(at: Date()) }

    package func isExpired(at now: Date) -> Bool { now >= expiresAt }

    /// Whether a silent refresh (`CreateToken grant_type=refresh_token`) is possible.
    package var canRefresh: Bool { canRefresh(at: Date()) }

    package func canRefresh(at now: Date) -> Bool {
        guard let refreshToken, !refreshToken.isEmpty,
              let clientId, !clientId.isEmpty,
              let clientSecret, !clientSecret.isEmpty else { return false }
        // A registration that has itself expired cannot be used to refresh.
        if let registrationExpiresAt, now >= registrationExpiresAt { return false }
        return true
    }

    package init(startUrl: String, region: String, accessToken: String, expiresAt: Date, clientId: String?, clientSecret: String?, refreshToken: String?, registrationExpiresAt: Date?) {
        self.startUrl = startUrl
        self.region = region
        self.accessToken = accessToken
        self.expiresAt = expiresAt
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.refreshToken = refreshToken
        self.registrationExpiresAt = registrationExpiresAt
    }
}
