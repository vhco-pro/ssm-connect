import Foundation

/// A parsed AWS SSO token from `~/.aws/sso/cache/*.json` (F-05).
///
/// The cache format is identical to AWS CLI v2 (spike-confirmed, spec §12.1): a recent
/// `aws sso login` produces a file the app can reuse, and the `refreshToken` +
/// `clientId`/`clientSecret` enable a silent `CreateToken grant_type=refresh_token`
/// before any browser prompt.
struct SSOToken: Equatable, Sendable {
    let startUrl: String
    let region: String
    let accessToken: String
    let expiresAt: Date

    // Present when the token was minted via the device-authorization flow; required for
    // silent refresh.
    let clientId: String?
    let clientSecret: String?
    let refreshToken: String?
    let registrationExpiresAt: Date?

    /// Whether the `accessToken` is at or past its expiry.
    var isExpired: Bool { Date() >= expiresAt }

    /// Whether a silent refresh (`CreateToken grant_type=refresh_token`) is possible.
    var canRefresh: Bool {
        guard let refreshToken, !refreshToken.isEmpty,
              let clientId, !clientId.isEmpty,
              let clientSecret, !clientSecret.isEmpty else { return false }
        // A registration that has itself expired cannot be used to refresh.
        if let registrationExpiresAt, Date() >= registrationExpiresAt { return false }
        return true
    }
}
