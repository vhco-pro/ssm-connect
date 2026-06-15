import AWSSecretsManager
import Testing
@testable import SSMConnectKit

@Suite("SecretsService")
struct SecretsServiceTests {
    private let creds = AWSCredentials.stub
    private let region = "eu-central-1"
    private let secretId = "ec2/workstation-dcv-password"

    private func makeService(client: MockSecretsClient) -> SecretsService {
        SecretsService(makeClient: { _, _ in client })
    }

    @Test("Fetches the secret string for the configured secret id")
    func fetchesSecret() async throws {
        let client = MockSecretsClient()
        client.result = .success(GetSecretValueOutput(secretString: "s3cr3t"))
        let service = makeService(client: client)

        let value = try await service.fetchSecret(secretId: secretId, region: region, credentials: creds)

        #expect(value == "s3cr3t")
        #expect(client.inputs.first?.secretId == secretId)
    }

    @Test("ResourceNotFoundException maps to SecretsError.notFound")
    func notFound() async {
        let client = MockSecretsClient()
        client.result = .failure(ResourceNotFoundException())
        let service = makeService(client: client)

        await #expect(throws: SecretsError.notFound(secretId: secretId)) {
            _ = try await service.fetchSecret(secretId: secretId, region: region, credentials: creds)
        }
    }

    @Test("Empty secret string maps to SecretsError.empty")
    func emptySecret() async {
        let client = MockSecretsClient()
        client.result = .success(GetSecretValueOutput(secretString: ""))
        let service = makeService(client: client)

        await #expect(throws: SecretsError.empty(secretId: secretId)) {
            _ = try await service.fetchSecret(secretId: secretId, region: region, credentials: creds)
        }
    }

    @Test("Nil secret string (binary-only secret) maps to SecretsError.empty")
    func nilSecretString() async {
        let client = MockSecretsClient()
        client.result = .success(GetSecretValueOutput(secretString: nil))
        let service = makeService(client: client)

        await #expect(throws: SecretsError.empty(secretId: secretId)) {
            _ = try await service.fetchSecret(secretId: secretId, region: region, credentials: creds)
        }
    }
}
