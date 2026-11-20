@_spi(UnknownAWSHTTPServiceError) import AWSClientRuntime
import AWSEC2
import AWSEC2InstanceConnect
import AWSSecretsManager
import AWSSSM
import AWSSSO
import AWSSSOOIDC
import ClientRuntime
import Foundation
import Smithy
import SmithyHTTPAPI
import SmithyIdentity
import Testing
@testable import SSMConnectKit

/// Records, for the AWS client parity tests (cross-platform-client spec, AC-28, T40),
/// what the current SDK-based app makes of each service error it translates: the error
/// facts the SDK decodes from a canned response, and the app's own translation of them.
/// It runs only when SSM_ERROR_FIXTURES names an output directory, on macOS, because the
/// translation lives in this macOS-only package. The SDK clients use a stub HTTP engine,
/// so no server or credentials are involved.
@Suite("Error fixture recording", .enabled(if: ProcessInfo.processInfo.environment["SSM_ERROR_FIXTURES"] != nil))
struct ErrorFixtureRecording {
    struct Fixture: Encodable {
        struct Response: Encodable { let status: Int; let headers: [[String]]; let body: String }
        struct Facts: Encodable {
            let swiftType: String
            let typeName: String?
            let message: String?
            let httpStatus: Int?
        }
        struct App: Encodable {
            let renderedMessage: String?
            let isRejectedAuthorization: Bool
            let isRoleAccessDenied: Bool
            let isPermissionDenied: Bool
        }
        let name: String
        let service: String
        let operation: String
        let response: Response
        let sdk: Facts
        let app: App
    }

    /// Returns one canned response for every request.
    struct StubEngine: SmithyHTTPAPI.HTTPClient {
        let status: Int
        let headers: [[String]]
        let body: String
        func send(request: SmithyHTTPAPI.HTTPRequest) async throws -> SmithyHTTPAPI.HTTPResponse {
            var values = Headers()
            for header in headers { values.add(name: header[0], value: header[1]) }
            return HTTPResponse(headers: values, body: .data(Data(body.utf8)), statusCode: HTTPStatusCode(rawValue: status) ?? .badRequest)
        }
    }

    struct Case {
        let name: String
        let service: String
        let operation: String
        let status: Int
        let headers: [[String]]
        let body: String
    }

    static func restJSON(_ name: String, _ service: String, _ operation: String, _ status: Int, _ type: String, _ body: String) -> Case {
        Case(name: name, service: service, operation: operation, status: status,
             headers: [["Content-Type", "application/json"], ["x-amzn-ErrorType", type], ["x-amzn-RequestId", "req-1234"]], body: body)
    }
    static func awsJSON(_ name: String, _ service: String, _ operation: String, _ type: String, message: String?) -> Case {
        let body = message.map { #"{"__type":"\#(type)","message":"\#($0)"}"# } ?? #"{"__type":"\#(type)"}"#
        return Case(name: name, service: service, operation: operation, status: 400,
                    headers: [["Content-Type", "application/x-amz-json-1.1"], ["x-amzn-RequestId", "req-1234"]], body: body)
    }
    static func ec2(_ name: String, _ operation: String, _ status: Int, _ code: String) -> Case {
        Case(name: name, service: "ec2", operation: operation, status: status, headers: [["Content-Type", "text/xml;charset=UTF-8"]],
             body: "<?xml version=\"1.0\" encoding=\"UTF-8\"?><Response><Errors><Error><Code>\(code)</Code><Message>EC2 says \(code)</Message></Error></Errors><RequestID>req-1234</RequestID></Response>")
    }
    static func oidc(_ name: String, _ status: Int, _ type: String, _ error: String) -> Case {
        restJSON(name, "sso-oidc", "CreateToken", status, type, #"{"error":"\#(error)","error_description":"OIDC says \#(error)"}"#)
    }

    static let cases: [Case] = [
        oidc("sso-oidc-invalid-grant", 400, "InvalidGrantException", "invalid_grant"),
        oidc("sso-oidc-invalid-request", 400, "InvalidRequestException", "invalid_request"),
        oidc("sso-oidc-authorization-pending", 400, "AuthorizationPendingException", "authorization_pending"),
        oidc("sso-oidc-slow-down", 400, "SlowDownException", "slow_down"),
        oidc("sso-oidc-expired-token", 400, "ExpiredTokenException", "expired_token"),
        oidc("sso-oidc-unauthorized-client", 400, "UnauthorizedClientException", "unauthorized_client"),
        oidc("sso-oidc-invalid-client", 401, "InvalidClientException", "invalid_client"),
        oidc("sso-oidc-access-denied", 400, "AccessDeniedException", "access_denied"),
        restJSON("sso-oidc-register-invalid-metadata", "sso-oidc", "RegisterClient", 400, "InvalidClientMetadataException",
                 #"{"error":"invalid_client_metadata","error_description":"OIDC says invalid_client_metadata"}"#),
        restJSON("sso-unauthorized", "sso", "GetRoleCredentials", 401, "UnauthorizedException", #"{"message":"Session token not found or invalid"}"#),
        restJSON("sso-forbidden", "sso", "GetRoleCredentials", 403, "ForbiddenException", #"{"message":"No access"}"#),
        restJSON("sso-resource-not-found", "sso", "GetRoleCredentials", 404, "ResourceNotFoundException", #"{"message":"Could not find role"}"#),
        ec2("ec2-unauthorized-operation", "DescribeInstances", 403, "UnauthorizedOperation"),
        ec2("ec2-instance-not-found", "DescribeInstances", 400, "InvalidInstanceID.NotFound"),
        ec2("ec2-auth-failure", "DescribeInstances", 401, "AuthFailure"),
        ec2("ec2-incorrect-instance-state", "StartInstances", 400, "IncorrectInstanceState"),
        awsJSON("ssm-access-denied", "ssm", "StartSession", "AccessDeniedException", message: "User is not authorized to perform ssm:StartSession"),
        awsJSON("ssm-access-denied-no-message", "ssm", "StartSession", "AccessDeniedException", message: nil),
        awsJSON("ssm-target-not-connected", "ssm", "StartSession", "TargetNotConnected", message: "i-0123456789abcdef0 is not connected."),
        awsJSON("ssm-invalid-document", "ssm", "StartSession", "InvalidDocument", message: "Document is not supported"),
        awsJSON("ssm-expired-token", "ssm", "StartSession", "ExpiredTokenException", message: "The security token included in the request is expired"),
        awsJSON("ssm-invalid-instance-id", "ssm", "DescribeInstanceInformation", "InvalidInstanceId", message: "Invalid instance id"),
        awsJSON("secretsmanager-resource-not-found", "secretsmanager", "GetSecretValue", "ResourceNotFoundException", message: "Secrets Manager can't find the specified secret."),
        awsJSON("secretsmanager-access-denied", "secretsmanager", "GetSecretValue", "AccessDeniedException", message: "not authorized"),
        awsJSON("secretsmanager-decryption-failure", "secretsmanager", "GetSecretValue", "DecryptionFailure", message: "KMS denied"),
        awsJSON("ec2-instance-connect-instance-not-found", "ec2-instance-connect", "SendSSHPublicKey", "EC2InstanceNotFoundException", message: "Instance not found"),
        awsJSON("ec2-instance-connect-auth", "ec2-instance-connect", "SendSSHPublicKey", "AuthException", message: "Authorization failed"),
    ]

    static func call(_ c: Case) async throws {
        let engine = StubEngine(status: c.status, headers: c.headers, body: c.body)
        let region = "eu-central-1"
        let resolver = StaticAWSCredentialIdentityResolver(AWSCredentialIdentity(accessKey: "AKIDEXAMPLE", secret: "secret", sessionToken: "token"))
        let id = "i-0123456789abcdef0"
        switch (c.service, c.operation) {
        case ("sso-oidc", "CreateToken"):
            let client = SSOOIDCClient(config: try await SSOOIDCClient.SSOOIDCClientConfig(awsCredentialIdentityResolver: resolver, region: region, httpClientEngine: engine))
            _ = try await client.createToken(input: CreateTokenInput(clientId: "client-id", clientSecret: "client-secret", deviceCode: "device-code",
                                                                     grantType: "urn:ietf:params:oauth:grant-type:device_code"))
        case ("sso-oidc", "RegisterClient"):
            let client = SSOOIDCClient(config: try await SSOOIDCClient.SSOOIDCClientConfig(awsCredentialIdentityResolver: resolver, region: region, httpClientEngine: engine))
            _ = try await client.registerClient(input: RegisterClientInput(clientName: "SSM Connect", clientType: "public", scopes: ["sso:account:access"]))
        case ("sso", _):
            let client = SSOClient(config: try await SSOClient.SSOClientConfig(awsCredentialIdentityResolver: resolver, region: region, httpClientEngine: engine))
            _ = try await client.getRoleCredentials(input: GetRoleCredentialsInput(accessToken: "access-token", accountId: "123456789012", roleName: "WorkstationUser"))
        case ("ec2", "DescribeInstances"):
            let client = EC2Client(config: try await EC2Client.EC2ClientConfig(awsCredentialIdentityResolver: resolver, region: region, httpClientEngine: engine))
            _ = try await client.describeInstances(input: DescribeInstancesInput(instanceIds: [id]))
        case ("ec2", "StartInstances"):
            let client = EC2Client(config: try await EC2Client.EC2ClientConfig(awsCredentialIdentityResolver: resolver, region: region, httpClientEngine: engine))
            _ = try await client.startInstances(input: StartInstancesInput(instanceIds: [id]))
        case ("ssm", "StartSession"):
            let client = SSMClient(config: try await SSMClient.SSMClientConfig(awsCredentialIdentityResolver: resolver, region: region, httpClientEngine: engine))
            _ = try await client.startSession(input: StartSessionInput(documentName: "AWS-StartSSHSession", parameters: ["portNumber": ["22"]], target: id))
        case ("ssm", "DescribeInstanceInformation"):
            let client = SSMClient(config: try await SSMClient.SSMClientConfig(awsCredentialIdentityResolver: resolver, region: region, httpClientEngine: engine))
            _ = try await client.describeInstanceInformation(input: DescribeInstanceInformationInput(filters: [.init(key: "InstanceIds", values: [id])]))
        case ("secretsmanager", _):
            let client = SecretsManagerClient(config: try await SecretsManagerClient.SecretsManagerClientConfig(awsCredentialIdentityResolver: resolver, region: region, httpClientEngine: engine))
            _ = try await client.getSecretValue(input: GetSecretValueInput(secretId: "dcv"))
        case ("ec2-instance-connect", _):
            let client = EC2InstanceConnectClient(config: try await EC2InstanceConnectClient.EC2InstanceConnectClientConfig(awsCredentialIdentityResolver: resolver, region: region, httpClientEngine: engine))
            _ = try await client.sendSSHPublicKey(input: SendSSHPublicKeyInput(instanceId: id, instanceOSUser: "ec2-user", sshPublicKey: "ssh-ed25519 AAAA test"))
        default:
            Issue.record("no call for \(c.service) \(c.operation)")
        }
    }

    @MainActor
    @Test("Record the SDK's errors and the app's translation of them")
    func record() async throws {
        let directory = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SSM_ERROR_FIXTURES"]!)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        for c in Self.cases {
            var caught: (any Error)?
            do { try await Self.call(c) } catch { caught = error }
            let error = try #require(caught, "\(c.name) did not fail")
            let service = error as? ServiceError
            let status = (error as? HTTPError).map { Int($0.httpResponse.statusCode.rawValue) }
            let fixture = Fixture(
                name: c.name, service: c.service, operation: c.operation,
                response: .init(status: c.status, headers: c.headers, body: c.body),
                sdk: .init(swiftType: String(reflecting: type(of: error)), typeName: service?.typeName, message: service?.message, httpStatus: status),
                app: .init(
                    renderedMessage: service.map { ConnectionStateMachine.message(from: $0, httpStatus: (error as? HTTPError)?.httpResponse.statusCode) },
                    isRejectedAuthorization: AWSAuthProvider.isRejectedAuthorization(error),
                    isRoleAccessDenied: AWSAuthProvider.isRoleAccessDenied(error),
                    isPermissionDenied: AWSAuthProvider.isPermissionDenied(error)
                )
            )
            try encoder.encode(fixture).write(to: directory.appendingPathComponent("\(c.name).json"))
        }
    }
}
