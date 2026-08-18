import Foundation

/// The portable connection-profile document (spec §6.1, `contracts/connection-profile.schema.json`).
///
/// This is deliberately a **separate type from `ConnectionProfile`**, not a `Codable` conformance on
/// it. `ConnectionProfile`'s synthesized coding is the app's private `UserDefaults` representation
/// and is free to change; this document is a cross-client contract and is not. Two concrete places
/// where they already disagree, either of which would have shipped a schema-violating export:
///
/// - `ConnectAction` has no raw value, so synthesized encoding emits `{"dcvViewer":{}}` where the
///   schema requires the string `"dcvViewer"`.
/// - The document carries `schemaVersion`, which the native model has no reason to hold.
public struct PortableProfileDocument: Equatable, Sendable {
    /// The only version this client writes, and the only one it accepts (schema: `const: 1`).
    public static let currentSchemaVersion = 1

    /// The one `connectAction` v1 defines.
    public static let dcvViewerAction = "dcvViewer"

    public var schemaVersion: Int = currentSchemaVersion
    public var id: UUID
    public var name: String
    public var ssoStartUrl: String
    public var ssoRegion: String
    public var accountId: String
    public var roleName: String
    public var resourceRegion: String
    public var instanceTagKey: String
    public var instanceTagValue: String
    public var connectMode: ConnectMode?
    public var connectAction: String = dcvViewerAction
    public var localPort: Int
    public var remotePort: Int
    public var agentRemotePort: Int?
    public var secretId: String?

    /// Optional properties this client does not model, preserved verbatim so a document written by
    /// a newer or different client survives a round-trip through this one ("unknown optional
    /// properties are permitted and SHOULD be preserved on round-trip").
    ///
    /// Preservation is not unconditional: `ProfilePortability` rejects a document carrying any key
    /// on the schema's credential deny-list before it reaches here, so this can never become a
    /// smuggling channel for secrets.
    public var unknownFields: [String: JSONValue] = [:]
}

// MARK: - Mapping to and from the app's native model

public extension PortableProfileDocument {
    /// Build the portable document for a stored profile.
    ///
    /// - Parameter unknownFields: optional properties carried in from a previous import, so
    ///   export(import(x)) preserves them.
    public init(profile: ConnectionProfile, unknownFields: [String: JSONValue] = [:]) {
        self.id = profile.id
        self.name = profile.name
        self.ssoStartUrl = profile.ssoStartUrl
        self.ssoRegion = profile.ssoRegion
        self.accountId = profile.accountId
        self.roleName = profile.roleName
        self.resourceRegion = profile.resourceRegion
        self.instanceTagKey = profile.instanceTagKey
        self.instanceTagValue = profile.instanceTagValue
        self.connectMode = profile.connectMode
        self.localPort = profile.localPort
        self.remotePort = profile.remotePort
        self.agentRemotePort = profile.agentRemotePort
        self.secretId = profile.secretId
        self.unknownFields = unknownFields
    }

    /// The stored profile this document describes.
    ///
    /// `connectMode` and `agentRemotePort` stay optional rather than being resolved to their
    /// defaults here: the schema says absent means `singleUser` / 8444, and `ConnectionProfile`
    /// already encodes exactly that through `resolvedConnectMode` / `resolvedAgentRemotePort`.
    /// Resolving eagerly would rewrite a legacy profile's absent field into a present one and
    /// change what a re-export looks like.
    public var profile: ConnectionProfile {
        ConnectionProfile(
            id: id,
            name: name,
            ssoStartUrl: ssoStartUrl,
            ssoRegion: ssoRegion,
            accountId: accountId,
            roleName: roleName,
            resourceRegion: resourceRegion,
            instanceTagKey: instanceTagKey,
            instanceTagValue: instanceTagValue,
            secretId: secretId,
            localPort: localPort,
            remotePort: remotePort,
            connectAction: .dcvViewer,
            connectMode: connectMode,
            agentRemotePort: agentRemotePort
        )
    }
}

// MARK: - Errors

/// Why a portable profile document was rejected.
///
/// Every case names the offending field and value, for the same reason `ProfileConfigError` does:
/// an import failure the user cannot act on is barely better than a silent one.
public enum ProfilePortabilityError: LocalizedError, Equatable {
    case malformedJSON
    case notAnObject
    case unsupportedSchemaVersion(found: Int)
    case missingField(String)
    case invalidField(field: String, value: String, reason: String)
    case forbiddenField(String)

    public var errorDescription: String? {
        switch self {
        case .malformedJSON:
            "This file isn't valid JSON, so it can't be read as a connection profile."
        case .notAnObject:
            "A connection profile must be a single JSON object."
        case let .unsupportedSchemaVersion(found):
            "This profile uses format version \(found), but this version of SSM Connect only "
                + "understands version \(PortableProfileDocument.currentSchemaVersion). Update the app, "
                + "or export the profile again from a matching version."
        case let .missingField(field):
            "The profile is missing the required field \"\(field)\"."
        case let .invalidField(field, value, reason):
            "The profile's \"\(field)\" value \(value.isEmpty ? "\"\"" : "\"\(value)\"") is not valid: \(reason)"
        case let .forbiddenField(field):
            "The profile carries a \"\(field)\" field. A portable profile carries identifiers only, "
                + "never credentials or secrets — this file was not produced by SSM Connect and was not imported."
        }
    }
}

// MARK: - Encoding and decoding

/// Reads and writes the portable profile document (spec §6.1, AC-03).
///
/// The validation here intentionally duplicates `connection-profile.schema.json` rather than
/// deferring to it: the schema is checked in CI by `contracts/validate.py`, but a shipped client
/// has no JSON Schema validator and still must refuse a bad document with an actionable message.
/// `PortableProfileTests` pins the two together by round-tripping the real contract fixtures.
public enum ProfilePortability {
    /// Keys the schema's security clause forbids outright: live authentication material and
    /// machine-local paths (§6.1, §12). Rejected even though they would otherwise be "unknown
    /// optional properties", because preserving them is exactly the failure mode to avoid.
    public static let forbiddenKeys: Set<String> = [
        "accessKeyId", "secretAccessKey", "sessionToken", "credentials",
        "accessToken", "refreshToken", "ssoAccessToken",
        "password", "dcvPassword", "secretValue", "authToken", "presignedUrl",
        "sessionResponse", "ssmSession", "connectionFilePath", "tempFilePath",
    ]

    /// Properties this client models. Anything else is an unknown optional property.
    private static let knownKeys: Set<String> = [
        "schemaVersion", "id", "name", "ssoStartUrl", "ssoRegion", "accountId", "roleName",
        "resourceRegion", "instanceTagKey", "instanceTagValue", "connectMode", "connectAction",
        "localPort", "remotePort", "agentRemotePort", "secretId",
    ]

    // MARK: Export

    /// Encode a profile as a portable document.
    ///
    /// Keys are sorted and the output is pretty-printed: an exported profile is a file a human
    /// diffs and a reviewer reads, and stable key order is what makes that useful.
    public static func export(_ profile: ConnectionProfile, unknownFields: [String: JSONValue] = [:]) throws -> Data {
        let document = PortableProfileDocument(profile: profile, unknownFields: unknownFields)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(document.jsonObject())
    }

    /// Encode a profile as a portable document string.
    public static func exportString(_ profile: ConnectionProfile, unknownFields: [String: JSONValue] = [:]) throws -> String {
        String(decoding: try export(profile, unknownFields: unknownFields), as: UTF8.self)
    }

    // MARK: Import

    /// Decode and validate a portable document.
    ///
    /// Validation is total: the returned document has already been checked against every constraint
    /// this client can express, so callers do not re-validate.
    public static func importDocument(from data: Data) throws -> PortableProfileDocument {
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            throw ProfilePortabilityError.malformedJSON
        }
        guard case let .object(object) = value else {
            throw ProfilePortabilityError.notAnObject
        }

        // Version first: a document from a future schema must fail on the version, not on whichever
        // field happens to have changed shape.
        let version = try requiredInt(object, "schemaVersion")
        guard version == PortableProfileDocument.currentSchemaVersion else {
            throw ProfilePortabilityError.unsupportedSchemaVersion(found: version)
        }

        // Security boundary before anything else is trusted.
        for key in object.keys where forbiddenKeys.contains(key) {
            throw ProfilePortabilityError.forbiddenField(key)
        }

        let idText = try requiredString(object, "id")
        guard let id = UUID(uuidString: idText) else {
            throw ProfilePortabilityError.invalidField(field: "id", value: idText, reason: "it is not a UUID.")
        }

        let connectMode = try optionalConnectMode(object)
        let secretId = try optionalNullableString(object, "secretId")
        if connectMode == .multiUser, let secretId {
            throw ProfilePortabilityError.invalidField(
                field: "secretId",
                value: secretId,
                reason: "a multi-user workstation authenticates by identity and never uses a shared "
                    + "password, so it must not carry a secret ID."
            )
        }

        let action = try optionalString(object, "connectAction") ?? PortableProfileDocument.dcvViewerAction
        guard action == PortableProfileDocument.dcvViewerAction else {
            throw ProfilePortabilityError.invalidField(
                field: "connectAction",
                value: action,
                reason: "this version only supports \"\(PortableProfileDocument.dcvViewerAction)\"."
            )
        }

        var document = PortableProfileDocument(
            schemaVersion: version,
            id: id,
            name: try requiredNonEmptyString(object, "name"),
            ssoStartUrl: try requiredNonEmptyString(object, "ssoStartUrl"),
            ssoRegion: try requiredRegion(object, "ssoRegion"),
            accountId: try requiredAccountId(object),
            roleName: try requiredNonEmptyString(object, "roleName"),
            resourceRegion: try requiredRegion(object, "resourceRegion"),
            instanceTagKey: try requiredNonEmptyString(object, "instanceTagKey"),
            // Deliberately allowed to be empty: an exported but not-yet-configured profile is valid.
            instanceTagValue: try requiredString(object, "instanceTagValue"),
            connectMode: connectMode,
            connectAction: action,
            localPort: try requiredPort(object, "localPort"),
            remotePort: try requiredPort(object, "remotePort"),
            agentRemotePort: try optionalPort(object, "agentRemotePort"),
            secretId: secretId
        )

        document.unknownFields = object.filter { !knownKeys.contains($0.key) }

        return document
    }

    /// Decode and validate a portable document, returning the profile it describes.
    public static func importProfile(from data: Data) throws -> ConnectionProfile {
        try importDocument(from: data).profile
    }

    // MARK: Field readers

    private static func requiredValue(_ object: [String: JSONValue], _ key: String) throws -> JSONValue {
        guard let value = object[key], value != .null else {
            throw ProfilePortabilityError.missingField(key)
        }
        return value
    }

    private static func requiredString(_ object: [String: JSONValue], _ key: String) throws -> String {
        guard case let .string(text) = try requiredValue(object, key) else {
            throw ProfilePortabilityError.invalidField(field: key, value: "", reason: "it must be a string.")
        }
        return text
    }

    private static func requiredNonEmptyString(_ object: [String: JSONValue], _ key: String) throws -> String {
        let text = try requiredString(object, key)
        guard !text.isEmpty else {
            throw ProfilePortabilityError.invalidField(field: key, value: text, reason: "it must not be empty.")
        }
        return text
    }

    private static func optionalString(_ object: [String: JSONValue], _ key: String) throws -> String? {
        guard let value = object[key], value != .null else { return nil }
        guard case let .string(text) = value else {
            throw ProfilePortabilityError.invalidField(field: key, value: "", reason: "it must be a string.")
        }
        return text
    }

    /// `secretId` is explicitly nullable, so an explicit `null` is valid and means "absent".
    private static func optionalNullableString(_ object: [String: JSONValue], _ key: String) throws -> String? {
        try optionalString(object, key)
    }

    private static func requiredInt(_ object: [String: JSONValue], _ key: String) throws -> Int {
        guard case let .number(number) = try requiredValue(object, key), number == number.rounded() else {
            throw ProfilePortabilityError.invalidField(field: key, value: "", reason: "it must be a whole number.")
        }
        return Int(number)
    }

    private static func requiredRegion(_ object: [String: JSONValue], _ key: String) throws -> String {
        let value = try requiredString(object, key)
        guard AWSRegion.isValid(value) else {
            throw ProfilePortabilityError.invalidField(
                field: key,
                value: value,
                reason: "it is not a syntactically valid AWS region such as eu-central-1."
            )
        }
        return value
    }

    private static func requiredAccountId(_ object: [String: JSONValue]) throws -> String {
        let value = try requiredString(object, "accountId")
        guard value.count == 12, value.allSatisfy(\.isASCII), value.allSatisfy(\.isNumber) else {
            throw ProfilePortabilityError.invalidField(
                field: "accountId",
                value: value,
                reason: "an AWS account ID is exactly 12 digits."
            )
        }
        return value
    }

    private static func requiredPort(_ object: [String: JSONValue], _ key: String) throws -> Int {
        let value = try requiredInt(object, key)
        guard (1...65535).contains(value) else {
            throw ProfilePortabilityError.invalidField(
                field: key,
                value: String(value),
                reason: "a port must be between 1 and 65535."
            )
        }
        return value
    }

    private static func optionalPort(_ object: [String: JSONValue], _ key: String) throws -> Int? {
        guard let value = object[key], value != .null else { return nil }
        guard case let .number(number) = value, number == number.rounded() else {
            throw ProfilePortabilityError.invalidField(field: key, value: "", reason: "it must be a whole number.")
        }
        let port = Int(number)
        guard (1...65535).contains(port) else {
            throw ProfilePortabilityError.invalidField(
                field: key,
                value: String(port),
                reason: "a port must be between 1 and 65535."
            )
        }
        return port
    }

    private static func optionalConnectMode(_ object: [String: JSONValue]) throws -> ConnectMode? {
        guard let text = try optionalString(object, "connectMode") else { return nil }
        guard let mode = ConnectMode(rawValue: text) else {
            throw ProfilePortabilityError.invalidField(
                field: "connectMode",
                value: text,
                reason: "it must be either \"singleUser\" or \"multiUser\"."
            )
        }
        return mode
    }
}

// MARK: - Serialization

private extension PortableProfileDocument {
    /// The document as a JSON-serializable dictionary.
    ///
    /// Built by hand rather than through `Encodable` so optional-versus-absent is explicit: the
    /// schema distinguishes an absent `connectMode` (meaning "legacy profile, single user") from a
    /// present one, and a synthesized encoder would not preserve that distinction on re-export.
    public func jsonObject() -> [String: JSONValue] {
        var object: [String: JSONValue] = unknownFields
        object["schemaVersion"] = .number(Double(schemaVersion))
        object["id"] = .string(id.uuidString.lowercased())
        object["name"] = .string(name)
        object["ssoStartUrl"] = .string(ssoStartUrl)
        object["ssoRegion"] = .string(ssoRegion)
        object["accountId"] = .string(accountId)
        object["roleName"] = .string(roleName)
        object["resourceRegion"] = .string(resourceRegion)
        object["instanceTagKey"] = .string(instanceTagKey)
        object["instanceTagValue"] = .string(instanceTagValue)
        object["connectAction"] = .string(connectAction)
        object["localPort"] = .number(Double(localPort))
        object["remotePort"] = .number(Double(remotePort))

        // Absent stays absent. Writing an explicit null would be schema-valid for secretId but would
        // turn "this profile predates connectMode" into "this profile chose null", which is a
        // different statement and the exact thing AC-03 round-trips.
        if let connectMode { object["connectMode"] = .string(connectMode.rawValue) }
        if let agentRemotePort { object["agentRemotePort"] = .number(Double(agentRemotePort)) }
        if let secretId { object["secretId"] = .string(secretId) }

        return object
    }
}

/// A minimal JSON value, used only to carry unknown optional properties across a round-trip.
///
/// `Any` would have done the job in-process, but it is not `Sendable` or `Equatable`, and this
/// travels through a domain value that is both. It is also what keeps the import path off
/// `JSONSerialization`, whose `NSNumber` bridging (a `CFBoolean` check to tell `true` from `1`) is
/// Darwin-shaped — the wrong dependency for the type whose entire purpose is portability.
public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
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
        } else {
            self = .object(try container.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:               try container.encodeNil()
        case let .bool(value):    try container.encode(value)
        case let .number(value):
            // Emit whole numbers as integers so ports and versions round-trip as `8443`, not `8443.0`.
            if value == value.rounded(), abs(value) < 1e15 {
                try container.encode(Int(value))
            } else {
                try container.encode(value)
            }
        case let .string(value):  try container.encode(value)
        case let .array(value):   try container.encode(value)
        case let .object(value):  try container.encode(value)
        }
    }
}
