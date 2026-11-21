import Foundation
import SSMConnectDomain

package enum WebForwardsError: LocalizedError {
    case invalidConfiguration(String)
    case keyGenerationFailed
    case keyPushFailed
    case sshNotReady

    package var errorDescription: String? {
        switch self {
        case let .invalidConfiguration(message): return message
        case .keyGenerationFailed: return "Could not generate the temporary SSH key."
        case .keyPushFailed:
            return "Could not authorize the SSH key. Check ec2-instance-connect:SendSSHPublicKey permission and the SSH OS user."
        case .sshNotReady: return "SSH did not open the configured ports. Check the SSH user and host SSH service."
        }
    }
}

package protocol SSHTunnelProviding: Sendable {
    func start(session: SSMSessionResponse, region: String, instanceId: String, user: String,
               keyPath: String, configuration: WebForwardsConfiguration) async throws -> TunnelHandle
}

package final class SSHKeyMaterial: @unchecked Sendable {
    package let directory: URL
    package let publicKey: String
    package var privateKeyPath: String { directory.appendingPathComponent("key").path }

    package init(directory: URL, publicKey: String) {
        self.directory = directory
        self.publicKey = publicKey
    }

    package func remove() { try? FileManager.default.removeItem(at: directory) }
    deinit { remove() }
}

package protocol SSHKeyGenerating: Sendable {
    func generate() async throws -> SSHKeyMaterial
}

package protocol InstanceConnectProviding: Sendable {
    func sendPublicKey(instanceId: String, user: String, publicKey: String,
                       region: String, credentials: AWSCredentials) async throws
}
