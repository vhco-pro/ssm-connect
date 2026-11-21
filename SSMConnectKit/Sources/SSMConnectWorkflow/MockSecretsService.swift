import Foundation
import SSMConnectDomain

/// In-memory `SecretsProviding` for higher-level (state-machine) tests (E1).
package final class MockSecretsService: SecretsProviding, @unchecked Sendable {
    package var result: Result<String, Error> = .success("hunter2")

    package private(set) var fetchCount = 0
    package private(set) var lastSecretId: String?
    package private(set) var lastRegion: String?

    package func fetchSecret(secretId: String, region: String, credentials: AWSCredentials) async throws -> String {
        fetchCount += 1
        lastSecretId = secretId
        lastRegion = region
        return try result.get()
    }

    package init() {}
}
