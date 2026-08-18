import Foundation

/// Temporary STS credentials obtained from AWS SSO (`SSO.GetRoleCredentials`, F-04).
///
/// Held in memory only for the lifetime of the session — never written to disk,
/// `UserDefaults`, Keychain, or logs (NF-01).
public struct AWSCredentials: Equatable, Sendable {
    public init(accessKeyId: String, secretAccessKey: String, sessionToken: String, expiration: Date) {
        self.accessKeyId = accessKeyId
        self.secretAccessKey = secretAccessKey
        self.sessionToken = sessionToken
        self.expiration = expiration
    }

    public let accessKeyId: String
    public let secretAccessKey: String
    public let sessionToken: String
    /// Absolute expiry of these STS credentials.
    public let expiration: Date

    /// Whether the credentials are at or past their expiry instant.
    public var isExpired: Bool { Date() >= expiration }
}
