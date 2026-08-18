import Foundation
import Testing
@testable import SSMConnectKit

/// Covers the portable profile document (spec §6.1, AC-03).
///
/// The important tests here are the ones that read `contracts/fixtures/profiles/*.json` rather than
/// a locally-authored string. Those files are the shared contract and the .NET client's fixture
/// loader reads the same three documents, so a change on either side that breaks interchange fails
/// here instead of at the first real cross-platform import.
@Suite("Portable profile document")
struct PortableProfileTests {
    static var profilesDirectory: URL {
        FixturePaths.contractsDirectory.appendingPathComponent("fixtures/profiles")
    }

    static func fixtureData(_ name: String) throws -> Data {
        try Data(contentsOf: profilesDirectory.appendingPathComponent("\(name).json"))
    }

    static let fixtureNames = ["single-user", "multi-user", "unconfigured"]

    // MARK: Importing the real contract fixtures

    @Test("every contract profile fixture imports", arguments: fixtureNames)
    func contractFixturesImport(name: String) throws {
        let document = try ProfilePortability.importDocument(from: Self.fixtureData(name))
        #expect(document.schemaVersion == 1)
        #expect(!document.name.isEmpty)
    }

    @Test("the single-user fixture maps onto the expected profile")
    func singleUserMapping() throws {
        let profile = try ProfilePortability.importProfile(from: Self.fixtureData("single-user"))

        #expect(profile.id == UUID(uuidString: "11111111-1111-4111-8111-111111111111"))
        #expect(profile.name == "Example Single-User Workstation")
        #expect(profile.ssoRegion == "eu-west-1")
        #expect(profile.accountId == "000000000000")
        #expect(profile.resourceRegion == "eu-central-1")
        #expect(profile.instanceTagValue == "example-workstation-su")
        #expect(profile.secretId == "example/dcv/password")
        #expect(profile.localPort == 8443)
        #expect(profile.remotePort == 8443)
        #expect(profile.resolvedConnectMode == .singleUser)
        // Not a multi-user profile, so the agent port stays at its default rather than being stored.
        #expect(profile.agentRemotePort == nil)
        #expect(profile.resolvedAgentRemotePort == 8444)
    }

    @Test("the multi-user fixture maps onto the expected profile")
    func multiUserMapping() throws {
        let profile = try ProfilePortability.importProfile(from: Self.fixtureData("multi-user"))

        #expect(profile.resolvedConnectMode == .multiUser)
        #expect(profile.agentRemotePort == 8444)
        // MU-00a: a multi-user host is identity-only. The fixture carries an explicit null.
        #expect(profile.secretId == nil)
        #expect(profile.instanceTagValue == "example-workstation-mu")
    }

    @Test("the unconfigured fixture imports and is correctly reported as not connectable")
    func unconfiguredMapping() throws {
        let profile = try ProfilePortability.importProfile(from: Self.fixtureData("unconfigured"))

        // An empty instanceTagValue is schema-valid: a profile can be exported before it is finished.
        #expect(profile.instanceTagValue.isEmpty)
        #expect(!profile.isConfigured)
    }

    // MARK: Round-trip

    @Test("import then export reproduces the contract fixture exactly", arguments: fixtureNames)
    func roundTripPreservesTheDocument(name: String) throws {
        let original = try Self.fixtureData(name)
        let document = try ProfilePortability.importDocument(from: original)
        let exported = try ProfilePortability.export(document.profile, unknownFields: document.unknownFields)

        let before = try JSONSerialization.jsonObject(with: original) as? [String: Any] ?? [:]
        let after = try JSONSerialization.jsonObject(with: exported) as? [String: Any] ?? [:]

        // Compared as parsed JSON, not as text: key order and whitespace are not contract.
        #expect(
            NSDictionary(dictionary: normalize(before)) == NSDictionary(dictionary: normalize(after)),
            "Round-tripping '\(name)' changed the document.\n  before: \(normalize(before))\n  after:  \(normalize(after))"
        )
    }

    /// An explicit `"secretId": null` and an absent `secretId` mean the same thing to both clients,
    /// so the comparison treats them as equal rather than forcing the exporter to write nulls.
    private func normalize(_ object: [String: Any]) -> [String: Any] {
        object.filter { !($0.value is NSNull) }
    }

    @Test("a profile with no connectMode round-trips without gaining one")
    func absentConnectModeStaysAbsent() throws {
        // This is the shape the shipping macOS app actually has stored: connectMode predates the
        // field, so a real export omits it. Resolving it to "singleUser" on export would silently
        // rewrite the document and make AC-03 pass against synthetic data only.
        var profile = ConnectionProfile.template
        profile.name = "Legacy"
        profile.ssoStartUrl = "https://d-0000000000.awsapps.com/start"
        profile.ssoRegion = "eu-west-1"
        profile.accountId = "000000000000"
        profile.roleName = "ExampleRole"
        profile.resourceRegion = "eu-central-1"
        profile.instanceTagValue = "example"
        profile.connectMode = nil

        let exported = try ProfilePortability.exportString(profile)
        #expect(!exported.contains("connectMode"))

        let reimported = try ProfilePortability.importProfile(from: Data(exported.utf8))
        #expect(reimported.connectMode == nil)
        #expect(reimported.resolvedConnectMode == .singleUser)
    }

    @Test("unknown optional properties survive a round-trip")
    func unknownFieldsArePreserved() throws {
        var object = try JSONSerialization.jsonObject(with: Self.fixtureData("single-user")) as! [String: Any]
        object["futureFieldFromANewerClient"] = "keep me"
        object["futureNumber"] = 7
        let data = try JSONSerialization.data(withJSONObject: object)

        let document = try ProfilePortability.importDocument(from: data)
        let exported = try ProfilePortability.export(document.profile, unknownFields: document.unknownFields)
        let result = try JSONSerialization.jsonObject(with: exported) as! [String: Any]

        #expect(result["futureFieldFromANewerClient"] as? String == "keep me")
        #expect((result["futureNumber"] as? NSNumber)?.intValue == 7)
    }

    // MARK: Export shape

    @Test("connectAction exports as a plain string, not a synthesized enum object")
    func connectActionEncodesAsAString() throws {
        // ConnectAction has no raw value, so ConnectionProfile's synthesized Codable would emit
        // {"dcvViewer":{}} here. That is schema-invalid, and it is the whole reason this document
        // is a separate type rather than a Codable conformance on the native model.
        let exported = try ProfilePortability.exportString(.template)
        #expect(exported.contains("\"connectAction\" : \"dcvViewer\""))
    }

    @Test("ports export as integers rather than floating-point numbers")
    func portsExportAsIntegers() throws {
        let exported = try ProfilePortability.exportString(.template)
        #expect(exported.contains("\"localPort\" : 8443"))
        #expect(!exported.contains("8443.0"))
    }

    @Test("an exported document always declares the current schema version")
    func exportDeclaresSchemaVersion() throws {
        let exported = try ProfilePortability.exportString(.template)
        #expect(exported.contains("\"schemaVersion\" : 1"))
    }

    // MARK: Rejections

    @Test("a newer schema version is refused with an actionable message")
    func futureSchemaVersionIsRefused() throws {
        var object = try JSONSerialization.jsonObject(with: Self.fixtureData("single-user")) as! [String: Any]
        object["schemaVersion"] = 2
        let data = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: ProfilePortabilityError.unsupportedSchemaVersion(found: 2)) {
            try ProfilePortability.importDocument(from: data)
        }
    }

    @Test(
        "a field that violates the schema is refused",
        arguments: [
            ("accountId", "12345678901" as Any),      // 11 digits
            ("accountId", "00000000000a" as Any),     // right length, not all digits
            ("resourceRegion", "eu-central-1-" as Any),
            ("ssoRegion", "" as Any),
            ("localPort", 0 as Any),
            ("remotePort", 70000 as Any),
            ("name", "" as Any),
            ("connectMode", "someOtherMode" as Any),
            ("connectAction", "rdp" as Any),
            ("id", "not-a-uuid" as Any),
        ]
    )
    func invalidFieldsAreRefused(field: String, value: Any) throws {
        var object = try JSONSerialization.jsonObject(with: Self.fixtureData("single-user")) as! [String: Any]
        object[field] = value
        let data = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: ProfilePortabilityError.self, "'\(field)' = \(value) should have been refused") {
            try ProfilePortability.importDocument(from: data)
        }
    }

    @Test("a required field that is missing is named in the error")
    func missingFieldIsNamed() throws {
        var object = try JSONSerialization.jsonObject(with: Self.fixtureData("single-user")) as! [String: Any]
        object.removeValue(forKey: "roleName")
        let data = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: ProfilePortabilityError.missingField("roleName")) {
            try ProfilePortability.importDocument(from: data)
        }
    }

    @Test("a multi-user profile carrying a secret ID is refused")
    func multiUserWithSecretIsRefused() throws {
        var object = try JSONSerialization.jsonObject(with: Self.fixtureData("multi-user")) as! [String: Any]
        object["secretId"] = "example/dcv/password"
        let data = try JSONSerialization.data(withJSONObject: object)

        #expect(throws: ProfilePortabilityError.self) {
            try ProfilePortability.importDocument(from: data)
        }
    }

    @Test("a document carrying credential material is refused outright", arguments: [
        "accessKeyId", "secretAccessKey", "sessionToken", "password", "authToken", "ssoAccessToken",
    ])
    func credentialBearingDocumentIsRefused(key: String) throws {
        var object = try JSONSerialization.jsonObject(with: Self.fixtureData("single-user")) as! [String: Any]
        object[key] = "should-never-be-imported"
        let data = try JSONSerialization.data(withJSONObject: object)

        // Without this, the unknown-field preservation above would happily carry a secret through.
        #expect(throws: ProfilePortabilityError.forbiddenField(key)) {
            try ProfilePortability.importDocument(from: data)
        }
    }

    @Test("malformed input is refused rather than crashing")
    func malformedInputIsRefused() {
        #expect(throws: ProfilePortabilityError.malformedJSON) {
            try ProfilePortability.importDocument(from: Data("{ not json".utf8))
        }
        #expect(throws: ProfilePortabilityError.notAnObject) {
            try ProfilePortability.importDocument(from: Data("[]".utf8))
        }
    }

    // MARK: The macOS half of AC-03

    @Test("a profile exported from the app re-imports to an identical profile")
    func exportedProfileReimportsIdentically() throws {
        for name in Self.fixtureNames {
            let original = try ProfilePortability.importProfile(from: Self.fixtureData(name))
            let exported = try ProfilePortability.export(original)
            let reimported = try ProfilePortability.importProfile(from: exported)

            #expect(reimported == original, "'\(name)' did not survive export → import unchanged.")
        }
    }
}
