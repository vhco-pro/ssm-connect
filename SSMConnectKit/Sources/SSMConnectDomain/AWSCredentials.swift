import Foundation

/// Temporary STS credentials obtained from AWS SSO (`SSO.GetRoleCredentials`, F-04).
///
/// Held in memory only for the lifetime of the session — never written to disk,
/// `UserDefaults`, Keychain, or logs (NF-01).
package struct AWSCredentials: Equatable, Sendable {
    package let accessKeyId: String
    package let secretAccessKey: String
    package let sessionToken: String
    /// Absolute expiry of these STS credentials.
    package let expiration: Date

    /// Whether the credentials are at or past their expiry instant.
    package var isExpired: Bool { Date() >= expiration }

    package init(accessKeyId: String, secretAccessKey: String, sessionToken: String, expiration: Date) {
        self.accessKeyId = accessKeyId
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
        self.expiration = expiration
    }
}
