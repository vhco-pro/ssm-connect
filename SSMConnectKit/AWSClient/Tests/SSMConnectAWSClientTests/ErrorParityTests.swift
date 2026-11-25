import Foundation
import Testing
@testable import SSMConnectAWSClient

/// Error parity with the pinned aws-sdk-swift (Fixtures/errors, recorded on macOS by
/// ErrorFixtureRecording in the main package). The app's translation reads an AWS error's
/// type name, message and HTTP status (ConnectionStateMachine.message(from:httpStatus:),
/// AWSAuthProvider.isRejectedAuthorization, isRoleAccessDenied, isPermissionDenied, and
/// its checks for InvalidGrant, InvalidRequest, AuthorizationPending, SlowDown and
/// ResourceNotFound), so the client must yield the same three facts for each response.
/// The recorded app outputs stay in the fixtures for the macOS cutover (T36).
@Suite("Error parity")
struct ErrorParityTests {
    struct Fixture: Decodable {
        struct Response: Decodable { let status: Int; let headers: [[String]]; let body: String }
        struct Facts: Decodable { let swiftType: String; let typeName: String?; let message: String?; let httpStatus: Int? }
        let name: String
        let service: String
        let operation: String
        let response: Response
        let sdk: Facts
    }

    static let directory = Bundle.module.url(forResource: "Fixtures/errors", withExtension: nil)!

    static var names: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }.sorted()
    }

    static func fixture(_ name: String) throws -> Fixture {
        try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: directory.appendingPathComponent("\(name).json")))
    }

    static func call(_ fixture: Fixture, _ client: AWSClient) async throws {
        let id = "i-0123456789abcdef0"
        switch (fixture.service, fixture.operation) {
        case ("sso-oidc", "CreateToken"):
            _ = try await client.createToken(clientId: "client-id", clientSecret: "client-secret",
                                             grantType: "urn:ietf:params:oauth:grant-type:device_code", deviceCode: "device-code")
        case ("sso-oidc", "RegisterClient"):
            _ = try await client.registerClient(clientName: "SSM Connect", clientType: "public", scopes: ["sso:account:access"])
        case ("sso", "GetRoleCredentials"):
            _ = try await client.getRoleCredentials(accessToken: "access-token", accountId: "123456789012", roleName: "WorkstationUser")
        case ("ec2", "DescribeInstances"):
            _ = try await client.describeInstances(instanceIds: [id])
        case ("ec2", "StartInstances"):
            _ = try await client.startInstances(instanceIds: [id])
        case ("ssm", "StartSession"):
            _ = try await client.startSession(target: id, documentName: "AWS-StartSSHSession", parameters: ["portNumber": ["22"]])
        case ("ssm", "DescribeInstanceInformation"):
            _ = try await client.describeInstanceInformation(filters: [("InstanceIds", [id])])
        case ("secretsmanager", "GetSecretValue"):
            _ = try await client.getSecretValue(secretId: "dcv")
        case ("ec2-instance-connect", "SendSSHPublicKey"):
            _ = try await client.sendSSHPublicKey(instanceId: id, instanceOSUser: "ec2-user", sshPublicKey: "ssh-ed25519 AAAA test")
        default:
            Issue.record("no call for \(fixture.service) \(fixture.operation)")
        }
    }

    @Test("Every translated error family is recorded")
    func coverage() {
        #expect(Self.names.count == 27)
        let services = Set(Self.names.compactMap { try? Self.fixture($0).service })
        #expect(services == ["sso-oidc", "sso", "ec2", "ssm", "secretsmanager", "ec2-instance-connect"])
    }

    @Test("The client yields the SDK's type name, message and status", arguments: names)
    func parity(_ name: String) async throws {
        let fixture = try Self.fixture(name)
        let transport = ScriptedTransport([.response(HTTPResponse(
            status: fixture.response.status, headers: fixture.response.headers.map { ($0[0], $0[1]) }, body: Data(fixture.response.body.utf8)
        ))])
        let client = AWSClient(region: "eu-central-1", credentials: AWSCredentialSet(accessKeyID: "AKIDEXAMPLE", secretAccessKey: "secret", sessionToken: "token"),
                               transport: transport, retry: RetryPolicy(random: { 0 }, sleep: { _ in }))
        do {
            try await Self.call(fixture, client)
            Issue.record("\(name) did not fail")
        } catch let error as AWSServiceError {
            #expect(error.typeName == fixture.sdk.typeName, "type name")
            #expect(error.message == fixture.sdk.message, "message")
            #expect(error.httpStatus == fixture.sdk.httpStatus, "status")
        }
        #expect(transport.attempts == 1)
    }
}
