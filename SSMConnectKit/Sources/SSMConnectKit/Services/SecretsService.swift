import AWSSecretsManager
import Foundation

/// Default `SecretsProviding` backed by `aws-sdk-swift`'s `SecretsManagerClient` (E1, F-11).
final class SecretsService: SecretsProviding {
    typealias ClientFactory = @Sendable (_ credentials: AWSCredentials, _ region: String) throws -> SecretsClienting

    private let makeClient: ClientFactory

    init(makeClient: @escaping ClientFactory = { try SecretsClientFactory.make(credentials: $0, region: $1) }) {
        self.makeClient = makeClient
    }

    func fetchSecret(secretId: String, region: String, credentials: AWSCredentials) async throws -> String {
        let client = try makeClient(credentials, region)
        let output: GetSecretValueOutput
        do {
            output = try await client.getSecretValue(GetSecretValueInput(secretId: secretId))
        } catch is ResourceNotFoundException {
            throw SecretsError.notFound(secretId: secretId)
        }
        guard let value = output.secretString, !value.isEmpty else {
            throw SecretsError.empty(secretId: secretId)
        }
        return value
    }
}
