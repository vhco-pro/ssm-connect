import Foundation
import SSMConnectDomain
import SSMConnectWorkflow

/// A parsed AWS SSO token from `~/.aws/sso/cache/*.json` (F-05).
///
/// The cache format is identical to AWS CLI v2 (spike-confirmed, spec §12.1): a recent
/// `aws sso login` produces a file the app can reuse, and the `refreshToken` +
/// `clientId`/`clientSecret` enable a silent `CreateToken grant_type=refresh_token`
/// before any browser prompt.
public struct SSOToken: Equatable, Sendable {
    public let startUrl: String
    public let region: String
    public let accessToken: String
    public let expiresAt: Date

    // Present when the token was minted via the device-authorization flow; required for
    // silent refresh.
    public let clientId: String?
    public let clientSecret: String?
    public let refreshToken: String?
    public let registrationExpiresAt: Date?

    /// Whether the `accessToken` is at or past its expiry.
    public var isExpired: Bool { Date() >= expiresAt }

    /// Whether a silent refresh (`CreateToken grant_type=refresh_token`) is possible.
    public var canRefresh: Bool {
        guard let refreshToken, !refreshToken.isEmpty,
              let clientId, !clientId.isEmpty,
              let clientSecret, !clientSecret.isEmpty else { return false }
        // A registration that has itself expired cannot be used to refresh.
        if let registrationExpiresAt, Date() >= registrationExpiresAt { return false }
        return true
    }
}
