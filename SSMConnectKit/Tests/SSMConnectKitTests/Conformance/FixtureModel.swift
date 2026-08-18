import Foundation

// MARK: - Minimal JSON tree
//
// Port outcomes are shaped per method ("what does resolveInstance return?"), so they cannot be
// decoded into one static type. A small JSON tree keeps the fixture readable at the point of use
// without dragging a dependency in.

indirect enum JSONValue: Decodable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON value.")
        }
    }

    subscript(key: String) -> JSONValue? {
        if case let .object(fields) = self { return fields[key] }
        return nil
    }

    var stringValue: String? {
        if case let .string(value) = self { return value }
        return nil
    }

    var boolValue: Bool? {
        if case let .bool(value) = self { return value }
        return nil
    }

    var intValue: Int? {
        if case let .number(value) = self { return Int(value) }
        return nil
    }

    /// How an argument is rendered when matched against a fixture's `with` clause. Numbers render
    /// without a decimal point so `8444` in JSON matches an `Int` argument.
    var comparableText: String? {
        switch self {
        case .null:                 return nil
        case let .bool(value):      return String(value)
        case let .number(value):    return value == value.rounded() ? String(Int(value)) : String(value)
        case let .string(value):    return value
        case .array, .object:       return nil
        }
    }
}

// MARK: - Fixture document

/// Note on the hand-written initialisers below: Swift's synthesized `Decodable` requires a key for
/// every non-optional property regardless of its default value, so every field the schema marks
/// optional-with-a-default needs decoding explicitly. The defaults here mirror
/// `contracts/state-machine.schema.json`; if one drifts, fixtures silently change meaning.
struct Fixture: Decodable {
    let id: String
    let title: String
    let profile: ProfileReference
    var settings: SettingsOverride?
    var harness: HarnessOverride?
    var given: Given = Given()
    let when: [Step]
    let expect: Expect

    private enum CodingKeys: String, CodingKey {
        case id, title, profile, settings, harness, given, when, expect
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        profile = try container.decode(ProfileReference.self, forKey: .profile)
        settings = try container.decodeIfPresent(SettingsOverride.self, forKey: .settings)
        harness = try container.decodeIfPresent(HarnessOverride.self, forKey: .harness)
        given = try container.decodeIfPresent(Given.self, forKey: .given) ?? Given()
        when = try container.decode([Step].self, forKey: .when)
        expect = try container.decode(Expect.self, forKey: .expect)
    }
}

struct ProfileReference: Decodable {
    var ref: String?
    var overrides: [String: JSONValue]?

    private enum CodingKeys: String, CodingKey {
        case ref = "$ref"
        case overrides
    }
}

struct SettingsOverride: Decodable {
    var autoConnect: Bool?
    var autoReconnect: Bool?
    var clipboardAutoClearSeconds: Int?
}

struct HarnessOverride: Decodable {
    var maxReconnectAttempts: Int?
    var reconnectBackoffSeconds: Double?
    var establishRetryAttempts: Int?
    var stageTimeoutSeconds: [String: Double]?
}

struct Given: Decodable {
    var lastInstanceId: String?
    var viewerInstalled: Bool = true
    var ports: [String: [String: [Outcome]]] = [:]
    var events: [FixtureEvent] = []

    private enum CodingKeys: String, CodingKey {
        case lastInstanceId, viewerInstalled, ports, events
    }

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lastInstanceId = try container.decodeIfPresent(String.self, forKey: .lastInstanceId) ?? nil
        viewerInstalled = try container.decodeIfPresent(Bool.self, forKey: .viewerInstalled) ?? true
        ports = try container.decodeIfPresent([String: [String: [Outcome]]].self, forKey: .ports) ?? [:]
        events = try container.decodeIfPresent([FixtureEvent].self, forKey: .events) ?? []
    }
}

struct Outcome: Decodable {
    var result: JSONValue?
    var error: OutcomeError?
}

struct OutcomeError: Decodable {
    let kind: String
    var message: String?
}

struct FixtureEvent: Decodable {
    let kind: String
    let afterState: String
    var reason: EventReason?
}

struct EventReason: Decodable {
    var kind: String?
    var exitCode: Int?
    var stderr: String?
}

struct Step: Decodable {
    let action: String
    var afterState: String?
}

struct Expect: Decodable {
    var states: [String] = []
    var statesAreExact: Bool = true
    var calls: [ExpectedCall] = []
    var forbiddenCalls: [ExpectedCall] = []
    let terminal: Terminal

    private enum CodingKeys: String, CodingKey {
        case states, statesAreExact, calls, forbiddenCalls, terminal
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        states = try container.decodeIfPresent([String].self, forKey: .states) ?? []
        statesAreExact = try container.decodeIfPresent(Bool.self, forKey: .statesAreExact) ?? true
        calls = try container.decodeIfPresent([ExpectedCall].self, forKey: .calls) ?? []
        forbiddenCalls = try container.decodeIfPresent([ExpectedCall].self, forKey: .forbiddenCalls) ?? []
        terminal = try container.decode(Terminal.self, forKey: .terminal)
    }
}

struct ExpectedCall: Decodable, CustomStringConvertible {
    let port: String
    let method: String
    var times: Int?
    var with: [String: JSONValue]?

    var description: String { "\(port).\(method)" }
}

struct Terminal: Decodable {
    let state: String
    var errorCategory: String?
    var errorMessageContains: String?
    var warningPresent: Bool?
    var tunnelActive: Bool?
    var passwordInMemory: Bool?

    /// `instanceId` and `localPort` are decoded as double optionals on purpose: a fixture that
    /// writes `"instanceId": null` is asserting the field was *cleared*, which is a different
    /// claim from not mentioning it at all. `.some(nil)` is the former, `nil` the latter.
    var instanceId: String??
    var localPort: Int??

    private enum CodingKeys: String, CodingKey {
        case state, errorCategory, errorMessageContains, warningPresent
        case tunnelActive, passwordInMemory, instanceId, localPort
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decode(String.self, forKey: .state)
        errorCategory = try container.decodeIfPresent(String.self, forKey: .errorCategory)
        errorMessageContains = try container.decodeIfPresent(String.self, forKey: .errorMessageContains)
        warningPresent = try container.decodeIfPresent(Bool.self, forKey: .warningPresent)
        tunnelActive = try container.decodeIfPresent(Bool.self, forKey: .tunnelActive)
        passwordInMemory = try container.decodeIfPresent(Bool.self, forKey: .passwordInMemory)
        instanceId = container.contains(.instanceId)
            ? .some(try container.decodeIfPresent(String.self, forKey: .instanceId))
            : nil
        localPort = container.contains(.localPort)
            ? .some(try container.decodeIfPresent(Int.self, forKey: .localPort))
            : nil
    }
}
