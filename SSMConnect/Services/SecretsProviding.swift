import Foundation

/// Fetches the DCV password from AWS Secrets Manager (E1, F-11).
protocol SecretsProviding: Sendable {
    /// Returns the plaintext secret string for `secretId` in `region`.
    /// Throws `SecretsError.notFound` if the secret is absent and `.empty` if it has no value.
    func fetchSecret(secretId: String, region: String, credentials: AWSCredentials) async throws -> String
}

enum SecretsError: LocalizedError, Equatable {
    case notFound(secretId: String)
    case empty(secretId: String)

    var errorDescription: String? {
        switch self {
        case let .notFound(secretId):
            return "Secret '\(secretId)' was not found. Verify the secret id in Settings or check the AWS Console."
        case let .empty(secretId):
            return "Secret '\(secretId)' has no value. Set the DCV password in Secrets Manager."
        }
    }
}
