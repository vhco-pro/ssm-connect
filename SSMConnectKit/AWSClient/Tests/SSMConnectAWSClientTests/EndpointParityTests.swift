import Foundation
import Testing
@testable import SSMConnectAWSClient

#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#elseif canImport(ucrt)
import ucrt
#endif

/// Endpoint parity with the pinned aws-sdk-swift (Fixtures/endpoints.json, written by
/// SSMConnectKit/Tools/FixtureRecorder from each client's default resolver without an
/// override), and the spec's rule that configured endpoint settings change nothing.
@Suite("Endpoint parity", .serialized)
struct EndpointParityTests {
    struct Fixture: Decodable {
        let sdk: String
        let endpoints: [String: [String: String]]
    }

    static let fixture: Fixture = {
        let url = Bundle.module.url(forResource: "Fixtures/endpoints", withExtension: "json")!
        return try! JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }()

    static let services: [(String, AWSService)] = [
        ("sso-oidc", .ssoOIDC), ("sso", .sso), ("ec2", .ec2), ("ssm", .ssm),
        ("secretsmanager", .secretsManager), ("ec2-instance-connect", .ec2InstanceConnect), ("sts", .sts),
    ]

    static var cases: [String] {
        services.flatMap { name, _ in fixture.endpoints[name]!.keys.sorted().map { "\(name) \($0)" } }
    }

    static func resolve(_ testCase: String) throws -> (expected: String, actual: String) {
        let parts = testCase.split(separator: " ").map(String.init)
        let service = services.first { $0.0 == parts[0] }!.1
        let expected = fixture.endpoints[parts[0]]![parts[1]]!
        return (expected, try AWSEndpoints.url(for: service, region: parts[1]).absoluteString)
    }

    @Test("An invalid region is refused with a readable message, as the SDK's invalid-value error read")
    func invalidRegionMessage() {
        #expect(throws: AWSEndpoints.ResolveError.invalidRegion("x x")) { try AWSEndpoints.url(for: .ec2, region: "x x") }
        #expect(AWSEndpoints.ResolveError.invalidRegion("xx").localizedDescription == "Invalid region: xx")
    }

    @Test("Every service and region the SDK resolves is covered")
    func coverage() {
        #expect(Self.fixture.endpoints.keys.sorted() == Self.services.map(\.0).sorted())
        #expect(Self.cases.count == 98)
        let regions = Set(Self.fixture.endpoints["ssm"]!.keys)
        #expect(regions.contains("cn-north-1") && regions.contains("us-gov-west-1"))
    }

    @Test("The client resolves the SDK's production endpoint", arguments: cases)
    func matchesSDK(_ testCase: String) throws {
        let result = try Self.resolve(testCase)
        #expect(result.actual == result.expected)
    }

    @Test("Configured endpoint settings change nothing", arguments: cases)
    func ignoresConfiguredEndpoints(_ testCase: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config")
        try Data("""
        [default]
        endpoint_url = http://127.0.0.1:9/
        ignore_configured_endpoint_urls = false
        [services local]
        ssm =
          endpoint_url = http://127.0.0.1:9/ssm
        """.utf8).write(to: config)
        let variables = [
            "AWS_ENDPOINT_URL": "http://127.0.0.1:9/",
            "AWS_ENDPOINT_URL_SSM": "http://127.0.0.1:9/ssm",
            "AWS_ENDPOINT_URL_EC2": "http://127.0.0.1:9/ec2",
            "AWS_ENDPOINT_URL_STS": "http://127.0.0.1:9/sts",
            "AWS_ENDPOINT_URL_SSO": "http://127.0.0.1:9/sso",
            "AWS_ENDPOINT_URL_SSO_OIDC": "http://127.0.0.1:9/oidc",
            "AWS_ENDPOINT_URL_SECRETS_MANAGER": "http://127.0.0.1:9/secrets",
            "AWS_ENDPOINT_URL_EC2_INSTANCE_CONNECT": "http://127.0.0.1:9/eic",
            "AWS_IGNORE_CONFIGURED_ENDPOINT_URLS": "false",
            "AWS_CONFIG_FILE": config.path,
        ]
        for (name, value) in variables { Self.setVariable(name, value) }
        defer { for name in variables.keys { Self.setVariable(name, nil) } }
        let result = try Self.resolve(testCase)
        #expect(result.actual == result.expected)
    }

    static func setVariable(_ name: String, _ value: String?) {
        #if os(Windows)
        _ = _putenv_s(name, value ?? "")
        #else
        if let value { setenv(name, value, 1) } else { unsetenv(name) }
        #endif
    }
}
