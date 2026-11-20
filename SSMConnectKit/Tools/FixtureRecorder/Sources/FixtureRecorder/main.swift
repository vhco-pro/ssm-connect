import AWSEC2
import AWSEC2InstanceConnect
import AWSSecretsManager
import AWSSSM
import AWSSSO
import AWSSSOOIDC
import AWSSTS
import Foundation

// Usage: FixtureRecorder endpoints <output.json> | requests <directory> | retries <directory>
//
// endpoints: each client's default endpoint resolver, without an endpoint override,
// for every service the app calls and a set of standard, China and GovCloud regions.

let regions = [
    "us-east-1", "us-west-2", "ca-central-1", "sa-east-1", "eu-west-1", "eu-central-1",
    "ap-southeast-2", "ap-east-1", "me-south-1", "af-south-1",
    "cn-north-1", "cn-northwest-1",
    "us-gov-west-1", "us-gov-east-1",
]

func endpoint(_ resolve: () throws -> String) -> String {
    do { return try resolve() } catch { return "error: \(error)" }
}


func recordEndpoints(to path: String) async throws {
    let base = "us-east-1"
    let oidc = try await SSOOIDCClient.SSOOIDCClientConfig(region: base).endpointResolver
    let sso = try await SSOClient.SSOClientConfig(region: base).endpointResolver
    let ec2 = try await EC2Client.EC2ClientConfig(region: base).endpointResolver
    let ssm = try await SSMClient.SSMClientConfig(region: base).endpointResolver
    let secrets = try await SecretsManagerClient.SecretsManagerClientConfig(region: base).endpointResolver
    let eic = try await EC2InstanceConnectClient.EC2InstanceConnectClientConfig(region: base).endpointResolver
    let sts = try await STSClient.STSClientConfig(region: base).endpointResolver

    var result: [String: [String: String]] = [:]
    for region in regions {
        result["sso-oidc", default: [:]][region] = endpoint { try oidc.resolve(params: AWSSSOOIDC.EndpointParams(region: region)).uri.url?.absoluteString ?? "unresolved" }
        result["sso", default: [:]][region] = endpoint { try sso.resolve(params: AWSSSO.EndpointParams(region: region)).uri.url?.absoluteString ?? "unresolved" }
        result["ec2", default: [:]][region] = endpoint { try ec2.resolve(params: AWSEC2.EndpointParams(region: region)).uri.url?.absoluteString ?? "unresolved" }
        result["ssm", default: [:]][region] = endpoint { try ssm.resolve(params: AWSSSM.EndpointParams(region: region)).uri.url?.absoluteString ?? "unresolved" }
        result["secretsmanager", default: [:]][region] = endpoint { try secrets.resolve(params: AWSSecretsManager.EndpointParams(region: region)).uri.url?.absoluteString ?? "unresolved" }
        result["ec2-instance-connect", default: [:]][region] = endpoint { try eic.resolve(params: AWSEC2InstanceConnect.EndpointParams(region: region)).uri.url?.absoluteString ?? "unresolved" }
        result["sts", default: [:]][region] = endpoint { try sts.resolve(params: AWSSTS.EndpointParams(region: region)).uri.url?.absoluteString ?? "unresolved" }
    }
    let document: [String: Any] = [
        "recorder": "SSMConnectKit/Tools/FixtureRecorder endpoints",
        "sdk": "aws-sdk-swift 1.7.62",
        "endpoints": result,
    ]
    let data = try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: URL(fileURLWithPath: path))
}

let arguments = CommandLine.arguments
switch (arguments.count, arguments.count > 1 ? arguments[1] : "") {
case (3, "endpoints"): try await recordEndpoints(to: arguments[2])
case (3, "requests"): try await recordRequests(to: arguments[2])
case (3, "retries"): try await recordRetries(to: arguments[2])
default:
    FileHandle.standardError.write(Data("usage: FixtureRecorder endpoints <output.json> | requests <directory> | retries <directory>\n".utf8))
    exit(2)
}
