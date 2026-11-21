// The aws-sdk-swift implementation, used on macOS until T36 switches it to SSM Connect's client.
#if os(macOS)
import AWSSecretsManager
import Foundation
import SSMConnectDomain
import SSMConnectWorkflow

/// Default `SecretsProviding` backed by `aws-sdk-swift`'s `SecretsManagerClient` (E1, F-11).
package final class SecretsService: SecretsProviding {
    package typealias ClientFactory = @Sendable (_ credentials: AWSCredentials, _ region: String) throws -> SecretsClienting

    private let makeClient: ClientFactory

    package init(makeClient: @escaping ClientFactory = { try SecretsClientFactory.make(credentials: $0, region: $1) }) {
        self.makeClient = makeClient
    }

    package func fetchSecret(secretId: String, region: String, credentials: AWSCredentials) async throws -> String {
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
#endif
