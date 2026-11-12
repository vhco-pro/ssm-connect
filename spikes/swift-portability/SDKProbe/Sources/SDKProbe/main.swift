import AWSEC2
import AWSEC2InstanceConnect
import AWSSecretsManager
import AWSSSM
import AWSSSO
import AWSSSOOIDC
import Yams

struct Header: Decodable {
    let schemaVersion: Int
}

enum ProbeError: Error {
    case unexpectedYAML
}

let header = try YAMLDecoder().decode(Header.self, from: "schemaVersion: 2")
guard header.schemaVersion == 2 else {
    throw ProbeError.unexpectedYAML
}

let clientTypes: [Any.Type] = [
    EC2Client.self, EC2InstanceConnectClient.self, SecretsManagerClient.self,
    SSMClient.self, SSOClient.self, SSOOIDCClient.self,
]
print("SDK modules linked: \(clientTypes.count); YAML schemaVersion: \(header.schemaVersion)")
