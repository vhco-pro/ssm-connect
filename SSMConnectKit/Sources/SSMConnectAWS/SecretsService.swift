import AWSSecretsManager
import Foundation
import SSMConnectDomain
import SSMConnectWorkflow

/// Default `SecretsProviding` backed by `aws-sdk-swift`'s `SecretsManagerClient` (E1, F-11).
public final class SecretsService: SecretsProviding {
    public typealias ClientFactory = @Sendable (_ credentials: AWSCredentials, _ region: String) throws -> SecretsClienting

    private let makeClient: ClientFactory

    public init(makeClient: @escaping ClientFactory = { try SecretsClientFactory.make(credentials: $0, region: $1) }) {
        self.makeClient = makeClient
    }

    public func fetchSecret(secretId: String, region: String, credentials: AWSCredentials) async throws -> String {
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
