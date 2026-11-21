// The aws-sdk-swift implementation, used on macOS until T36 switches it to SSM Connect's client.
#if os(macOS)
import AWSEC2InstanceConnect
import Foundation
import SSMConnectDomain
import SSMConnectWorkflow
import SmithyIdentity


package struct InstanceConnectService: InstanceConnectProviding {
    package func sendPublicKey(instanceId: String, user: String, publicKey: String,
                       region: String, credentials: AWSCredentials) async throws {
        let identity = AWSCredentialIdentity(accessKey: credentials.accessKeyId,
            secret: credentials.secretAccessKey, sessionToken: credentials.sessionToken)
        let config = try await EC2InstanceConnectClient.EC2InstanceConnectClientConfig(
            awsCredentialIdentityResolver: StaticAWSCredentialIdentityResolver(identity), region: region)
        let client = EC2InstanceConnectClient(config: config)
        do {
            let output = try await client.sendSSHPublicKey(input: SendSSHPublicKeyInput(
                instanceId: instanceId, instanceOSUser: user, sshPublicKey: publicKey))
            guard output.success == true else { throw WebForwardsError.keyPushFailed }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw WebForwardsError.keyPushFailed
        }
    }

    package init() {}
}
#endif
