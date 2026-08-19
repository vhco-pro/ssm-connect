import Foundation
import Testing
@testable import SSMConnectDomain

/// Pins the documents in `contracts/fixtures/exchange/` to what this client's exporter produces.
///
/// These files exist so the *other* client can import something macOS really wrote (AC-03). Both
/// clients already round-trip the shared profile fixtures, but that only proves each agrees with
/// the schema — not with the other. A document neither side authored by hand is what closes that.
///
/// The comparison is on parsed JSON rather than bytes: key order and whitespace are formatting, not
/// contract, and pinning them would make the test fail on an encoder change that broke nothing.
/// What is pinned is every value, and the presence or absence of every optional field — which is
/// where the interchange traps actually are.
@Suite("Exported profile exchange (AC-03)")
struct ExportedProfileExchangeTests {
    static var exchangeDirectory: URL {
        FixturePaths.contractsDirectory.appendingPathComponent("fixtures/exchange")
    }

    static func document(_ name: String) throws -> Data {
        try Data(contentsOf: exchangeDirectory.appendingPathComponent("\(name).json"))
    }

    /// The single-user profile the committed document describes.
    static var singleUser: ConnectionProfile {
        ConnectionProfile(
            id: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!,
            name: "Exported From macOS",
            ssoStartUrl: "https://d-0000000000.awsapps.com/start",
            ssoRegion: "eu-west-1",
            accountId: "000000000000",
            roleName: "ExampleWorkstationRole",
            resourceRegion: "eu-central-1",
            instanceTagKey: "Name",
            instanceTagValue: "example-workstation-su",
            secretId: "example/dcv/password",
            localPort: 8443,
            remotePort: 8443,
            connectMode: .singleUser
        )
    }

    /// The multi-user profile the committed document describes. Identity-only, so no `secretId`
    /// at all — the exporter omits it rather than writing an explicit null.
    static var multiUser: ConnectionProfile {
        ConnectionProfile(
            id: UUID(uuidString: "55555555-5555-4555-8555-555555555555")!,
            name: "Exported From macOS (Multi-User)",
            ssoStartUrl: "https://d-0000000000.awsapps.com/start",
            ssoRegion: "eu-west-1",
            accountId: "000000000000",
            roleName: "ExampleWorkstationRole",
            resourceRegion: "eu-central-1",
            instanceTagKey: "Name",
            instanceTagValue: "example-workstation-mu",
            localPort: 8443,
            remotePort: 8443,
            connectMode: .multiUser,
            agentRemotePort: 8444
        )
    }

    static var cases: [(String, ConnectionProfile)] {
        [("macos-exported-single-user", singleUser), ("macos-exported-multi-user", multiUser)]
    }

    @Test("the committed document is exactly what this client's exporter emits", arguments: cases)
    func documentMatchesExporterOutput(name: String, profile: ConnectionProfile) throws {
        let committed = try JSONSerialization.jsonObject(with: Self.document(name)) as? [String: Any] ?? [:]
        let produced = try JSONSerialization.jsonObject(
            with: ProfilePortability.export(profile)) as? [String: Any] ?? [:]

        #expect(
            NSDictionary(dictionary: committed) == NSDictionary(dictionary: produced),
            """
            '\(name).json' is no longer what the exporter produces. Regenerate it rather than \
            editing it by hand — the other client imports this file expecting real exporter output.
              committed: \(committed.sorted { $0.key < $1.key })
              produced:  \(produced.sorted { $0.key < $1.key })
            """
        )
    }

    @Test("the committed document imports back to the profile it describes", arguments: cases)
    func documentImportsBack(name: String, profile: ConnectionProfile) throws {
        #expect(try ProfilePortability.importProfile(from: Self.document(name)) == profile)
    }

    @Test("a multi-user export omits secretId entirely rather than writing null")
    func multiUserOmitsSecretId() throws {
        let object = try JSONSerialization.jsonObject(
            with: Self.document("macos-exported-multi-user")) as? [String: Any] ?? [:]

        // MU-00a: a multi-user host is identity-only. Absent and null both mean "no secret" to
        // this client, but they are different documents, and an importer that only handles one of
        // them fails against real output rather than against a fixture.
        #expect(object["secretId"] == nil)
        #expect(object["agentRemotePort"] as? NSNumber == 8444)
    }

    @Test("every exchange document declares schema version 1 and a string connectAction")
    func exchangeDocumentsAreSchemaShaped() throws {
        for (name, _) in Self.cases {
            let object = try JSONSerialization.jsonObject(with: Self.document(name)) as? [String: Any] ?? [:]
            #expect(object["schemaVersion"] as? NSNumber == 1, "\(name) schemaVersion")
            // The trap this exists for: an enum serialized as a number. Swift's synthesized coding
            // would emit an object here, and System.Text.Json defaults to an integer.
            #expect(object["connectAction"] as? String == "dcvViewer", "\(name) connectAction")
            #expect(object["connectMode"] is String, "\(name) connectMode")
        }
    }
}
