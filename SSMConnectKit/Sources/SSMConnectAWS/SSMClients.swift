import AWSSSM
import Foundation
import SmithyIdentity
import SSMConnectDomain
import SSMConnectWorkflow

/// Thin seam over the `aws-sdk-swift` `SSMClient` so `SSMService` can be unit-tested with a
/// mocked client (D-tests, ADR-P2). The real `SSMClient` conforms via the extension below.
public protocol SSMClienting: Sendable {
    func describeInstanceInformation(_ input: DescribeInstanceInformationInput) async throws -> DescribeInstanceInformationOutput
    func startSession(_ input: StartSessionInput) async throws -> StartSessionOutput
}

extension SSMClient: SSMClienting {
    public func describeInstanceInformation(_ input: DescribeInstanceInformationInput) async throws -> DescribeInstanceInformationOutput {
        try await describeInstanceInformation(input: input)
    }
    public func startSession(_ input: StartSessionInput) async throws -> StartSessionOutput {
        try await startSession(input: input)
    }
}

/// Builds a real `SSMClient` bound to explicit SSO STS credentials and the resource region.
public enum SSMClientFactory {
    public static func make(credentials: AWSCredentials, region: String) throws -> SSMClienting {
        let identity = AWSCredentialIdentity(
            accessKey: credentials.accessKeyId,
            secret: credentials.secretAccessKey,
            sessionToken: credentials.sessionToken
        )
        let config = try SSMClient.SSMClientConfig(
            awsCredentialIdentityResolver: StaticAWSCredentialIdentityResolver(identity),
            region: region
        )
        return SSMClient(config: config)
    }
}
