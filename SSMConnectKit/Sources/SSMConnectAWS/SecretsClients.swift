import AWSSecretsManager
import Foundation
import SmithyIdentity
import SSMConnectDomain
import SSMConnectWorkflow

/// Thin seam over `aws-sdk-swift`'s `SecretsManagerClient` so `SecretsService` is unit-testable
/// with a mocked client (E1, ADR-P2).
public protocol SecretsClienting: Sendable {
    func getSecretValue(_ input: GetSecretValueInput) async throws -> GetSecretValueOutput
}

extension SecretsManagerClient: SecretsClienting {
    public func getSecretValue(_ input: GetSecretValueInput) async throws -> GetSecretValueOutput {
        try await getSecretValue(input: input)
    }
}

/// Builds a real `SecretsManagerClient` bound to SSO STS credentials and the resource region.
public enum SecretsClientFactory {
    public static func make(credentials: AWSCredentials, region: String) throws -> SecretsClienting {
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
