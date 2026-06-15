import AWSSecretsManager
import Foundation
import SmithyIdentity

/// Thin seam over `aws-sdk-swift`'s `SecretsManagerClient` so `SecretsService` is unit-testable
/// with a mocked client (E1, ADR-P2).
protocol SecretsClienting: Sendable {
    func getSecretValue(_ input: GetSecretValueInput) async throws -> GetSecretValueOutput
}

extension SecretsManagerClient: SecretsClienting {
    func getSecretValue(_ input: GetSecretValueInput) async throws -> GetSecretValueOutput {
        try await getSecretValue(input: input)
    }
}

/// Builds a real `SecretsManagerClient` bound to SSO STS credentials and the resource region.
enum SecretsClientFactory {
    static func make(credentials: AWSCredentials, region: String) throws -> SecretsClienting {
        let identity = AWSCredentialIdentity(
            accessKey: credentials.accessKeyId,
            secret: credentials.secretAccessKey,
            sessionToken: credentials.sessionToken
        )
        let config = try SecretsManagerClient.SecretsManagerClientConfig(
            awsCredentialIdentityResolver: StaticAWSCredentialIdentityResolver(identity),
            region: region
        )
        return SecretsManagerClient(config: config)
    }
}
