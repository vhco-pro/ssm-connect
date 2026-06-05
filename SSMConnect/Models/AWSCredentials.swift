import Foundation

/// Temporary STS credentials obtained from AWS SSO (`SSO.GetRoleCredentials`, F-04).
///
/// Held in memory only for the lifetime of the session — never written to disk,
/// `UserDefaults`, Keychain, or logs (NF-01).
struct AWSCredentials: Equatable, Sendable {
    let accessKeyId: String
    let secretAccessKey: String
    let sessionToken: String
    /// Absolute expiry of these STS credentials.
    let expiration: Date

    /// Whether the credentials are at or past their expiry instant.
    var isExpired: Bool { Date() >= expiration }
}
