import Foundation
import Testing
@testable import SSMConnectKit

func portableExample() -> ConnectionProfile {
    var profile = ConnectionProfile.example
    profile.connectAction = .tunnelOnly
    profile.webForwards = .init(enabled: true, sshUser: "example", socksPort: 1080,
        proxySuffixes: [".example.invalid"],
        localForwards: [.init(name: "Application", localPort: 8080, remoteHost: "localhost", remotePort: 3000, openPath: "/")],
        browser: .zen, browserMode: .existing, browserProfilePath: "/local-only/browser")
    profile.remoteDevelopment = .init(enabled: true, folder: "/home/example/code")
    return profile
}

@Suite("Portable profile document")
struct ProfileDocumentTests {
    private struct InvalidCase: Decodable {
        struct Mutation: Decodable { let path: [String]; let value: ProfileValue }
        let name: String
        let mutations: [Mutation]
    }

    @Test("CFG-02 and CFG-09: Shared schema-invalid shapes fail on both clients")
    func sharedInvalidShapes() throws {
        let cases = try JSONDecoder().decode([InvalidCase].self,
            from: Data(contentsOf: fixtures.appendingPathComponent("v2-invalid-cases.json")))
        let original = try ProfileDocumentCodec.read(
            Data(contentsOf: fixtures.appendingPathComponent("v2-current.json")), format: .json)
        func replacing(_ value: ProfileValue, path: ArraySlice<String>, with replacement: ProfileValue) throws -> ProfileValue {
            guard let key = path.first else { return replacement }
            switch value {
            case var .object(object):
                object[key] = try replacing(#require(object[key]), path: path.dropFirst(), with: replacement)
                return .object(object)
            case var .array(array):
                let index = try #require(Int(key))
                array[index] = try replacing(array[index], path: path.dropFirst(), with: replacement)
                return .array(array)
            default: throw PortableProfileError.invalid("Invalid test mutation path.")
            }
        }
        for test in cases {
            var mutated = ProfileValue.object(original.fields)
            for mutation in test.mutations {
                mutated = try replacing(mutated, path: mutation.path[...], with: mutation.value)
            }
            let data = try JSONEncoder().encode(mutated)
            #expect(throws: PortableProfileError.self, "\(test.name)") {
                try ProfileDocumentCodec.read(data, format: .json)
            }
        }
    }

    @Test("CFG-02: Scientific optional numbers survive canonical JSON and YAML saves",
          arguments: ["1e127", "1e-128", "1.0e-128", "9007199254740993", "12345678901234567890123456789012345678"])
    func scientificNumbersRoundTrip(text: String) throws {
        let base = try ProfileDocumentCodec.write(PortableProfileDocument(profile: .example), format: .yaml)
        let imported = try ProfileDocumentCodec.read(base + Data(("\nfutureNumber: " + text).utf8), format: .yaml)
        for format in [ProfileFileFormat.json, .yaml] {
            let exported = try ProfileDocumentCodec.write(imported, format: format)
            let reloaded = try ProfileDocumentCodec.read(exported, format: format)
            #expect(reloaded.fields["futureNumber"] == imported.fields["futureNumber"])
        }
    }

    private var fixtures: URL {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }
        return root.appendingPathComponent("contracts/fixtures/profiles")
    }

    @Test("CFG-03: Shared v1/v2 contract and migration fixtures",
          arguments: ["v1-multi-user.json", "v1-legacy.json", "v2-current.json"])
    func sharedContractFixtures(name: String) throws {
        let data = try Data(contentsOf: fixtures.appendingPathComponent(name))
        let document = try ProfileDocumentCodec.read(data, format: .json)
        let profile = try document.profile(localID: UUID())
        #expect(profile.accountId == "000000000000")
        if name == "v1-multi-user.json" { #expect(profile.resolvedConnectMode == .multiUser) }
        if name == "v1-legacy.json" { #expect(profile.resolvedConnectMode == .singleUser) }
        let saved = try document.updating(profile: profile)
        #expect(saved.fields["schemaVersion"] == .number(2))
        #expect(saved.fields["futureOptional"] == document.fields["futureOptional"])
        #expect(try saved.id == document.id)
    }

    @Test("CFG-02: Shared YAML and JSON fixtures normalize identically")
    func sharedRepresentationFixtures() throws {
        let json = try ProfileDocumentCodec.read(Data(contentsOf: fixtures.appendingPathComponent("v2-current.json")), format: .json)
        let yaml = try ProfileDocumentCodec.read(Data(contentsOf: fixtures.appendingPathComponent("v2-current.yaml")), format: .yaml)
        #expect(json == yaml)
        var root = fixtures
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let output = root.appendingPathComponent("SSMConnectKit/.build/test-artifacts/profile-exchange")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let exported = try json.updating(profile: json.profile(localID: UUID()))
        try ProfileDocumentCodec.write(exported, format: .json)
            .write(to: output.appendingPathComponent("macos-v2-current.json"), options: .atomic)
    }

    @Test("CFG-02: Actual .NET v2 export survives Swift GUI mapping and explicit save")
    func actualDotnetExport() throws {
        var root = fixtures
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let data = try Data(contentsOf: root.appendingPathComponent("contracts/fixtures/exchange-v2/dotnet-v2-current.json"))
        let document = try ProfileDocumentCodec.read(data, format: .json)
        var native = try document.profile(localID: UUID())
        #expect(native.connectAction == .tunnelOnly)
        #expect(native.webForwards?.enabled == true)
        #expect(native.remoteDevelopment?.enabled == true)
        native.name = "Edited on macOS"
        let updated = try document.updating(profile: native)
        #expect(try updated.id == document.id)
        #expect(updated.fields["futureOptional"] == document.fields["futureOptional"])
        let saved = try ProfileDocumentCodec.write(updated, format: .yaml)
        #expect(try ProfileDocumentCodec.read(saved, format: .yaml).profile(localID: native.id).name == native.name)
    }

    @Test("CFG-01: Export and open a current profile", arguments: [ProfileFileFormat.json, .yaml])
    func allCapabilitiesRoundTrip(format: ProfileFileFormat) throws {
        let profile = portableExample()
        let document = try PortableProfileDocument(profile: profile)
        let bytes = try ProfileDocumentCodec.write(document, format: format)
        #expect(!String(decoding: bytes, as: UTF8.self).contains("local-only"))
        #expect(!String(decoding: bytes, as: UTF8.self).contains("browserProfilePath"))
        let loaded = try ProfileDocumentCodec.read(bytes, format: format)
        let mapped = try loaded.profile(localID: profile.id, localBrowserProfilePath: profile.webForwards?.browserProfilePath)
        #expect(mapped == profile)
        #expect(try loaded.id != profile.id)
        #expect(loaded.fields["requiredCapabilities"] == .array([
            .string("browserBootstrap"), .string("remoteDevelopment"), .string("tunnelOnly"), .string("webForwards")
        ]))
    }

    @Test("CFG-02: Equivalent YAML/JSON on Swift and .NET")
    func normalizedRepresentationsMatch() throws {
        let document = try PortableProfileDocument(profile: portableExample())
        let json = try ProfileDocumentCodec.read(ProfileDocumentCodec.write(document, format: .json), format: .json)
        let yaml = try ProfileDocumentCodec.read(ProfileDocumentCodec.write(document, format: .yaml), format: .yaml)
        #expect(json == yaml)
        let source = String(decoding: try ProfileDocumentCodec.write(document, format: .yaml), as: UTF8.self)
        let unquoted = source.replacingOccurrences(of: "\"111122223333\"", with: "111122223333")
        #expect(throws: PortableProfileError.self) { try ProfileDocumentCodec.read(Data(unquoted.utf8), format: .yaml) }
    }

    @Test("CFG-03: Existing v1 JSON")
    func legacyJSONRetainsMeaningUntilExplicitSave() throws {
        var profile = ConnectionProfile.example
        profile.connectMode = nil
        var fields = try PortableProfileDocument(profile: profile).fields
        fields["schemaVersion"] = .number(1)
        fields.removeValue(forKey: "connectMode")
        let bytes = try JSONEncoder().encode(fields)
        let loaded = try ProfileDocumentCodec.read(bytes, format: .json)
        #expect(loaded.fields["schemaVersion"] == .number(1))
        let native = try loaded.profile(localID: profile.id)
        #expect(native == profile)
        #expect(try loaded.updating(profile: native).fields["schemaVersion"] == .number(2))
        fields["schemaVersion"] = .number(999)
        #expect(throws: PortableProfileError.self) { try ProfileDocumentCodec.read(JSONEncoder().encode(fields), format: .json) }
    }

    @Test("CFG-04: GUI edits an attached file")
    func editingPreservesNestedUnknownValuesAndDocumentIdentity() throws {
        let profile = portableExample()
        var fields = try PortableProfileDocument(profile: profile).fields
        fields["future"] = .object(["largeInteger": .number(9_007_199_254_740_993), "label": .string("preserve me")])
        var web = try #require(fields["webForwards"]?.object)
        web["futureBrowserOption"] = .bool(true)
        if case var .array(forwards) = web["localForwards"], var first = forwards.first?.object {
            first["futureForwardOption"] = .string("keep")
            forwards[0] = .object(first)
            web["localForwards"] = .array(forwards)
        }
        fields["webForwards"] = .object(web)
        let original = try PortableProfileDocument(fields: fields)
        var edited = try original.profile(localID: UUID())
        edited.name = "Edited"
        edited.webForwards?.localForwards[0].name = "Renamed"
        let updated = try original.updating(profile: edited)
        let bytes = try ProfileDocumentCodec.write(updated, format: .yaml)
        let reloaded = try ProfileDocumentCodec.read(bytes, format: .yaml)
        #expect(try reloaded.id == original.id)
        #expect(reloaded.fields["future"] == original.fields["future"])
        #expect(reloaded.fields["webForwards"]?.object?["futureBrowserOption"] == .bool(true))
        #expect(try ProfileDocumentCodec.write(reloaded, format: .yaml) == bytes)
        if case let .array(forwards) = reloaded.fields["webForwards"]?.object?["localForwards"] {
            #expect(forwards[0].object?["futureForwardOption"] == .string("keep"))
        } else { Issue.record("Expected the retained forward") }
    }

    @Test("CFG-04: Port edits, swaps, reordering and persistence retain each forward's unknown values")
    func forwardMetadataFollowsTheEditedItem() throws {
        var profile = portableExample()
        profile.webForwards?.localForwards.append(.init(name: "Second", localPort: 8081, remoteHost: "localhost", remotePort: 3001))
        var fields = try PortableProfileDocument(profile: profile).fields
        var web = try #require(fields["webForwards"]?.object)
        guard case var .array(forwards) = web["localForwards"] else { Issue.record("Missing forwards"); return }
        for index in forwards.indices {
            var value = try #require(forwards[index].object)
            value["futureOwner"] = .string("forward-\(index)")
            forwards[index] = .object(value)
        }
        web["localForwards"] = .array(forwards)
        fields["webForwards"] = .object(web)
        let document = try PortableProfileDocument(fields: fields)
        for swapPorts in [false, true] {
            var edited = try document.profile(localID: UUID())
            edited.webForwards?.localForwards[0].localPort = swapPorts ? 8081 : 9090
            if swapPorts { edited.webForwards?.localForwards[1].localPort = 8080 }
            edited.webForwards?.localForwards.reverse()
            edited = try JSONDecoder().decode(ConnectionProfile.self, from: JSONEncoder().encode(edited))
            let updated = try document.updating(profile: edited)
            let data = try ProfileDocumentCodec.write(updated, format: .yaml)
            #expect(!String(decoding: data, as: UTF8.self).contains("portableOptions"))
            let loaded = try ProfileDocumentCodec.read(data, format: .yaml)
            guard case let .array(result) = loaded.fields["webForwards"]?.object?["localForwards"] else {
                Issue.record("Missing saved forwards"); return
            }
            #expect(result[0].object?["futureOwner"] == .string("forward-1"))
            #expect(result[1].object?["futureOwner"] == .string("forward-0"))
            #expect(result[1].object?["localPort"] == .number(Decimal(swapPorts ? 8081 : 9090)))
        }
    }

    @Test("CFG-09: Unsafe/oversized YAML, duplicate or credential fields",
          arguments: ["password: secret", "x: !execute command", "x: &owned value\ny: *owned",
                      "x: 1\nx: 2", "x: [1, 2]\nx: 3", "---\nx: 1\n---\nx: 2"])
    func rejectsUnsafeYAML(extra: String) throws {
        let bytes = try ProfileDocumentCodec.write(PortableProfileDocument(profile: .example), format: .yaml)
        #expect(throws: PortableProfileError.self) {
            try ProfileDocumentCodec.read(bytes + Data(("\n" + extra).utf8), format: .yaml)
        }
    }

    @Test("CFG-09: JSON duplicates, nested credentials and parser limits are rejected")
    func rejectsDuplicateJSONAndResourceExhaustion() throws {
        let document = try PortableProfileDocument(profile: .example)
        let json = String(decoding: try ProfileDocumentCodec.write(document, format: .json), as: UTF8.self)
        let duplicate = json.replacingOccurrences(of: "{", with: "{\"name\":\"first\",", range: json.range(of: "{"))
        #expect(throws: PortableProfileError.self) { try ProfileDocumentCodec.read(Data(duplicate.utf8), format: .json) }
        var fields = document.fields
        fields["future"] = .object(["Session_Token": .string("do-not-log")])
        #expect(throws: PortableProfileError.self) { try PortableProfileDocument(fields: fields) }
        #expect(throws: PortableProfileError.self) {
            try ProfileDocumentCodec.read(Data(repeating: 32, count: ProfileDocumentCodec.maximumBytes + 1), format: .yaml)
        }
        let deep = "x: " + String(repeating: "[", count: 2048) + "0" + String(repeating: "]", count: 2048)
        #expect(throws: PortableProfileError.self) { try ProfileDocumentCodec.read(Data(deep.utf8), format: .yaml) }
        let many = "x: [" + Array(repeating: "0", count: ProfileDocumentCodec.maximumNodes + 1).joined(separator: ",") + "]"
        #expect(throws: PortableProfileError.self) { try ProfileDocumentCodec.read(Data(many.utf8), format: .yaml) }
    }

    @Test("CFG-10: Another OS lacks a configured capability")
    func unsupportedRequiredCapabilitiesAreExplicit() throws {
        var fields = try PortableProfileDocument(profile: portableExample()).fields
        fields["requiredCapabilities"] = .array([.string("unsupported-editor")])
        #expect(throws: PortableProfileError.self) { try PortableProfileDocument(fields: fields) }
        fields.removeValue(forKey: "requiredCapabilities")
        #expect(throws: PortableProfileError.self) { try PortableProfileDocument(fields: fields) }
        fields["schemaVersion"] = .number(1)
        #expect(throws: PortableProfileError.self) { try PortableProfileDocument(fields: fields) }
    }

    @Test("CFG-09: File, depth and node limits accept the boundary and reject the next value")
    func exactResourceLimits() throws {
        let document = try PortableProfileDocument(profile: .example)
        let json = try ProfileDocumentCodec.write(document, format: .json)
        let padded = json + Data(repeating: 32, count: ProfileDocumentCodec.maximumBytes - json.count)
        #expect(try ProfileDocumentCodec.read(padded, format: .json) == document)
        #expect(throws: PortableProfileError.self) {
            try ProfileDocumentCodec.read(padded + Data(" ".utf8), format: .json)
        }
        let yaml = try ProfileDocumentCodec.write(document, format: .yaml)
        func nested(_ arrays: Int) -> Data {
            yaml + Data(("\nbudget: " + String(repeating: "[", count: arrays) + "0"
                + String(repeating: "]", count: arrays)).utf8)
        }
        #expect(try ProfileDocumentCodec.read(nested(ProfileDocumentCodec.maximumDepth - 1), format: .yaml)
            .fields["budget"] != nil)
        #expect(throws: PortableProfileError.self) {
            try ProfileDocumentCodec.read(nested(ProfileDocumentCodec.maximumDepth), format: .yaml)
        }
        let available = ProfileDocumentCodec.maximumNodes - (1 + document.fields.count * 2) - 2
        func collection(_ count: Int) -> Data {
            yaml + Data(("\nbudget: [" + Array(repeating: "0", count: count).joined(separator: ",") + "]").utf8)
        }
        #expect(try ProfileDocumentCodec.read(collection(available), format: .yaml).fields["budget"] != nil)
        #expect(throws: PortableProfileError.self) {
            try ProfileDocumentCodec.read(collection(available + 1), format: .yaml)
        }
    }
}
