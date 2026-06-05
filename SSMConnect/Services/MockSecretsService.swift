import Foundation

/// In-memory `SecretsProviding` for higher-level (state-machine) tests (E1).
final class MockSecretsService: SecretsProviding, @unchecked Sendable {
    var result: Result<String, Error> = .success("hunter2")

    private(set) var fetchCount = 0
    private(set) var lastSecretId: String?
    private(set) var lastRegion: String?

    func fetchSecret(secretId: String, region: String, credentials: AWSCredentials) async throws -> String {
        fetchCount += 1
        lastSecretId = secretId
        lastRegion = region
        return try result.get()
    }
}
