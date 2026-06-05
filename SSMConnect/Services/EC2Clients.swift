import AWSEC2
import Foundation
import SmithyIdentity

/// Thin seam over the `aws-sdk-swift` `EC2Client` so `EC2Service` can be unit-tested with a
/// mocked client (C5, ADR-P2). The real `EC2Client` conforms via the extension below.
protocol EC2Clienting: Sendable {
    func describeInstances(_ input: DescribeInstancesInput) async throws -> DescribeInstancesOutput
    func startInstances(_ input: StartInstancesInput) async throws -> StartInstancesOutput
    func stopInstances(_ input: StopInstancesInput) async throws -> StopInstancesOutput
}

extension EC2Client: EC2Clienting {
    func describeInstances(_ input: DescribeInstancesInput) async throws -> DescribeInstancesOutput {
        try await describeInstances(input: input)
    }
    func startInstances(_ input: StartInstancesInput) async throws -> StartInstancesOutput {
        try await startInstances(input: input)
    }
    func stopInstances(_ input: StopInstancesInput) async throws -> StopInstancesOutput {
        try await stopInstances(input: input)
    }
}

/// Builds a real `EC2Client` bound to explicit SSO STS credentials and the resource region.
enum EC2ClientFactory {
    static func make(credentials: AWSCredentials, region: String) throws -> EC2Clienting {
        let identity = AWSCredentialIdentity(
            accessKey: credentials.accessKeyId,
            secret: credentials.secretAccessKey,
            sessionToken: credentials.sessionToken
        )
        let config = try EC2Client.EC2ClientConfig(
            awsCredentialIdentityResolver: StaticAWSCredentialIdentityResolver(identity),
            region: region
        )
        return EC2Client(config: config)
    }
}
