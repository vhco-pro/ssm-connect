import Foundation

/// Obtains AWS STS credentials for a profile via AWS SSO (F-04, F-05, B1).
///
/// Behind a protocol so the rest of the app (and tests) can depend on `MockAuthProvider`
/// without touching the network or a browser (ADR-P2).
protocol AuthProviding: Sendable {
    /// Full authentication flow: reuse a valid cached token, else silent refresh, else
    /// open the browser for device authorization. May require user interaction (F-04).
    func authenticate(profile: ConnectionProfile) async throws -> AWSCredentials

    /// Silent path only: reuse a valid cached token or refresh it. Never opens a browser;
    /// throws `AuthError.signInRequired` if interactive sign-in is needed (F-05, F-17).
    func refreshIfNeeded(profile: ConnectionProfile) async throws -> AWSCredentials
}

/// Errors surfaced by the authentication layer.
enum AuthError: LocalizedError, Equatable {
    /// No valid cached token and silent refresh is impossible — interactive sign-in needed.
    case signInRequired
    /// The device-authorization grant was not approved before it expired.
    case deviceAuthTimedOut
    /// `RegisterClient` / `StartDeviceAuthorization` returned without the expected fields.
    case deviceAuthorizationFailed
    /// `SSO.GetRoleCredentials` returned without usable credentials.
    case missingRoleCredentials

    var errorDescription: String? {
        switch self {
        case .signInRequired:           "Sign in required."
        case .deviceAuthTimedOut:       "Sign-in timed out. Please try again."
        case .deviceAuthorizationFailed: "Could not start AWS SSO authorization."
        case .missingRoleCredentials:   "AWS did not return role credentials."
        }
    }
}
