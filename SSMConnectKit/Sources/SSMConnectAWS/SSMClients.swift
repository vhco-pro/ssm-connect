// The aws-sdk-swift implementation, used on macOS until T36 switches it to SSM Connect's client.
#if os(macOS)
import AWSSSM
import Foundation
import SSMConnectDomain
import SSMConnectWorkflow
import SmithyIdentity

/// Thin seam over the `aws-sdk-swift` `SSMClient` so `SSMService` can be unit-tested with a
/// mocked client (D-tests, ADR-P2). The real `SSMClient` conforms via the extension below.
package protocol SSMClienting: Sendable {
    func describeInstanceInformation(_ input: DescribeInstanceInformationInput) async throws -> DescribeInstanceInformationOutput
    func startSession(_ input: StartSessionInput) async throws -> StartSessionOutput
}

extension SSMClient: SSMClienting {
    package func describeInstanceInformation(_ input: DescribeInstanceInformationInput) async throws -> DescribeInstanceInformationOutput {
        try await describeInstanceInformation(input: input)
    }
    package func startSession(_ input: StartSessionInput) async throws -> StartSessionOutput {
        try await startSession(input: input)
    }
}

/// Builds a real `SSMClient` bound to explicit SSO STS credentials and the resource region.
package enum SSMClientFactory {
    package static func make(credentials: AWSCredentials, region: String) throws -> SSMClienting {
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
#endif
