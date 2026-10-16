import Foundation

enum PortableProfileError: LocalizedError, Equatable {
    case invalid(String)
    case conflict
    case formattingConsentRequired

    var errorDescription: String? {
        switch self {
        case let .invalid(message): return message
        case .conflict: return "The profile file changed since it was loaded. Reload and review the changes, or save a local copy. Nothing was overwritten."
        case .formattingConsentRequired:
            return "Saving this attached file uses canonical formatting and may remove YAML comments. Confirm this policy before saving, or save a local copy."
        }
    }
}

enum ProfileFileFormat: String, Codable {
    case json, yaml

    init(url: URL) throws {
        switch url.pathExtension.lowercased() {
        case "json": self = .json
        case "yaml", "yml": self = .yaml
        default: throw PortableProfileError.invalid("Choose a .json, .yaml or .yml profile file.")
        }
    }
}

indirect enum ProfileValue: Equatable, Codable, Sendable {
    case object([String: ProfileValue]), array([ProfileValue]), string(String), number(Decimal), bool(Bool), null

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let bool = try? value.decode(Bool.self) { self = .bool(bool) }
        else if let number = try? value.decode(Decimal.self) { self = .number(number) }
        else if let text = try? value.decode(String.self) { self = .string(text) }
        else if let array = try? value.decode([ProfileValue].self) { self = .array(array) }
        else { self = .object(try value.decode([String: ProfileValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case let .object(object): try value.encode(object)
        case let .array(array): try value.encode(array)
        case let .string(text): try value.encode(text)
        case let .number(number): try value.encode(number)
        case let .bool(bool): try value.encode(bool)
        case .null: try value.encodeNil()
        }
    }

    var object: [String: ProfileValue]? { if case let .object(value) = self { return value }; return nil }
    var string: String? { if case let .string(value) = self { return value }; return nil }
}

struct PortableProfileDocument: Equatable, Codable, Sendable {
    static let schemaVersion = 2
    private(set) var fields: [String: ProfileValue]

    var id: UUID {
        // Construction validates this invariant; persisted documents are revalidated by the store.
        get throws {
            guard let text = fields["id"]?.string, let id = UUID(uuidString: text) else {
                throw PortableProfileError.invalid("The profile's id must be a UUID.")
            }
            return id
        }
    }

    init(fields: [String: ProfileValue]) throws {
        self.fields = fields
        _ = try profile(localID: UUID())
    }

    init(profile: ConnectionProfile, documentID: UUID = UUID()) throws {
        fields = ["id": .string(documentID.uuidString.lowercased())]
        self = try updating(profile: profile)
    }

    func profile(localID: UUID, localBrowserProfilePath: String? = nil) throws -> ConnectionProfile {
        try Self.checkSecurity(.object(fields), path: "profile")
        let version = try integer("schemaVersion")
        guard version == 1 || version == Self.schemaVersion else {
            throw PortableProfileError.invalid("Unsupported profile schemaVersion. This client reads versions 1 and 2.")
        }
        _ = try id
        if let required = fields["requiredCapabilities"] {
            guard version == 2, case let .array(capabilities) = required else {
                throw PortableProfileError.invalid("requiredCapabilities must be a version-2 array of strings.")
            }
            for capability in capabilities {
                guard let name = capability.string,
                      ["tunnelOnly", "webForwards", "browserBootstrap", "remoteDevelopment"].contains(name) else {
                    throw PortableProfileError.invalid("This profile requires a capability this client does not support.")
                }
            }
        }
        guard fields["connectAction"] != .null else {
            throw PortableProfileError.invalid("connectAction must be a supported string, not null.")
        }
        let action = try optionalString("connectAction") ?? "dcvViewer"
        guard action == "dcvViewer" || (version == 2 && action == "tunnelOnly") else {
            throw PortableProfileError.invalid("connectAction is not supported by this schema version.")
        }
        let nativeAction: ConnectAction = action == "dcvViewer" ? .dcvViewer : .tunnelOnly
        if version == 1, fields["webForwards"] != nil || fields["remoteDevelopment"] != nil {
            throw PortableProfileError.invalid("Web, browser and editor settings require schemaVersion 2.")
        }
        let account = try string("accountId")
        guard account.utf8.count == 12, account.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw PortableProfileError.invalid("accountId must be a quoted string of exactly 12 digits.")
        }
        let startURL = try string("ssoStartUrl")
        guard let url = URL(string: startURL), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw PortableProfileError.invalid("ssoStartUrl must be an HTTPS URL without credentials, a query or a fragment.")
        }
        let ssoRegion = try string("ssoRegion")
        let resourceRegion = try string("resourceRegion")
        guard AWSRegion.isValid(ssoRegion), AWSRegion.isValid(resourceRegion) else {
            throw PortableProfileError.invalid("ssoRegion and resourceRegion must be valid AWS regions.")
        }
        let modeText = try optionalString("connectMode")
        let mode = modeText.flatMap(ConnectMode.init(rawValue:))
        guard modeText == nil || mode != nil else {
            throw PortableProfileError.invalid("connectMode must be singleUser or multiUser.")
        }
        let secretID = try optionalString("secretId")
        guard mode != .multiUser || secretID == nil else {
            throw PortableProfileError.invalid("Multi-user profiles cannot carry a shared-password secretId.")
        }
        var web: WebForwardsConfiguration?
        if let value = fields["webForwards"], value != .null {
            try validateBlockShape(value, field: "webForwards")
            web = try decode(WebForwardsConfiguration.self, value: value, field: "webForwards")
            if let web, web.enabled, let error = ProfileEditorValidation.webForwardsError(web) {
                throw PortableProfileError.invalid("webForwards: \(error)")
            }
            web?.browserProfilePath = localBrowserProfilePath
        }
        var remote: RemoteDevelopmentConfiguration?
        if let value = fields["remoteDevelopment"], value != .null {
            try validateBlockShape(value, field: "remoteDevelopment")
            remote = try decode(RemoteDevelopmentConfiguration.self, value: value, field: "remoteDevelopment")
            if let folder = remote?.folder, !folder.isEmpty {
                do { _ = try RemoteSSHConfiguration.folderURI(alias: "portable-profile", folder: folder) }
                catch { throw PortableProfileError.invalid("remoteDevelopment.folder must be an absolute remote path.") }
            }
        }
        if version == 2 {
            let needed = Self.capabilities(action: nativeAction, web: web, remote: remote)
            let declared: Set<String>
            if case let .array(values) = fields["requiredCapabilities"] {
                declared = Set(values.compactMap(\.string))
            } else { declared = [] }
            guard needed.isSubset(of: declared) else {
                throw PortableProfileError.invalid("requiredCapabilities must declare every enabled tunnel, web/browser and editor capability.")
            }
        }
        return ConnectionProfile(id: localID, name: try string("name"), ssoStartUrl: startURL,
            ssoRegion: ssoRegion, accountId: account, roleName: try string("roleName"),
            resourceRegion: resourceRegion, instanceTagKey: try string("instanceTagKey"),
            instanceTagValue: try string("instanceTagValue", allowEmpty: true), secretId: secretID,
            localPort: try port("localPort"), remotePort: try port("remotePort"),
            connectAction: nativeAction,
            connectMode: mode, agentRemotePort: try optionalPort("agentRemotePort"),
            webForwards: web, remoteDevelopment: remote)
    }

    func updating(profile: ConnectionProfile) throws -> Self {
        var object = fields
        let values: [String: ProfileValue] = [
            "schemaVersion": .number(Decimal(Self.schemaVersion)),
            "name": .string(profile.name), "ssoStartUrl": .string(profile.ssoStartUrl),
            "ssoRegion": .string(profile.ssoRegion), "accountId": .string(profile.accountId),
            "roleName": .string(profile.roleName), "resourceRegion": .string(profile.resourceRegion),
            "instanceTagKey": .string(profile.instanceTagKey), "instanceTagValue": .string(profile.instanceTagValue),
            "localPort": .number(Decimal(profile.localPort)), "remotePort": .number(Decimal(profile.remotePort)),
            "connectAction": .string(profile.connectAction == .dcvViewer ? "dcvViewer" : "tunnelOnly")
        ]
        object.merge(values) { _, new in new }
        object["connectMode"] = profile.connectMode.map { .string($0.rawValue) }
        object["agentRemotePort"] = profile.agentRemotePort.map { .number(Decimal($0)) }
        object["secretId"] = profile.secretId.map(ProfileValue.string)
        var required: Set<String> = []
        if case let .array(existing) = fields["requiredCapabilities"] {
            required.formUnion(existing.compactMap(\.string))
        }
        required.formUnion(Self.capabilities(action: profile.connectAction, web: profile.webForwards,
                                            remote: profile.remoteDevelopment))
        if !required.isEmpty { object["requiredCapabilities"] = .array(required.sorted().map(ProfileValue.string)) }
        if let web = profile.webForwards {
            var encoded = try encode(web)
            encoded.removeValue(forKey: "browserProfilePath")
            var merged = merge(fields["webForwards"]?.object ?? [:], encoded, known: [
                "enabled", "sshUser", "socksPort", "proxySuffixes", "localForwards", "browser", "browserMode"
            ])
            if case let .array(oldForwards) = fields["webForwards"]?.object?["localForwards"],
               case let .array(newForwards) = encoded["localForwards"] {
                merged["localForwards"] = .array(newForwards.map { new in
                    guard let newObject = new.object else { return new }
                    let old = oldForwards.first { $0.object?["localPort"] == newObject["localPort"] }?.object ?? [:]
                    return .object(merge(old, newObject, known: ["name", "localPort", "remoteHost", "remotePort", "openPath"]))
                })
            }
            object["webForwards"] = .object(merged)
        } else { object.removeValue(forKey: "webForwards") }
        if let remote = profile.remoteDevelopment {
            object["remoteDevelopment"] = .object(merge(fields["remoteDevelopment"]?.object ?? [:],
                try encode(remote), known: ["enabled", "folder"]))
        } else { object.removeValue(forKey: "remoteDevelopment") }
        return try Self(fields: object)
    }

    func withNewIdentity() throws -> Self {
        var fields = fields
        fields["id"] = .string(UUID().uuidString.lowercased())
        return try Self(fields: fields)
    }

    private func merge(_ old: [String: ProfileValue], _ new: [String: ProfileValue],
                       known: Set<String>) -> [String: ProfileValue] {
        old.filter { !known.contains($0.key) }.merging(new) { _, new in new }
    }

    private static func capabilities(action: ConnectAction, web: WebForwardsConfiguration?,
                                     remote: RemoteDevelopmentConfiguration?) -> Set<String> {
        var required: Set<String> = []
        if action == .tunnelOnly { required.insert("tunnelOnly") }
        if web?.enabled == true {
            required.insert("webForwards")
            if web?.browserMode != nil { required.insert("browserBootstrap") }
        }
        if remote?.enabled == true { required.insert("remoteDevelopment") }
        return required
    }

    private func encode<T: Encodable>(_ value: T) throws -> [String: ProfileValue] {
        try JSONDecoder().decode([String: ProfileValue].self, from: JSONEncoder().encode(value))
    }

    private func decode<T: Decodable>(_ type: T.Type, value: ProfileValue, field: String) throws -> T {
        do { return try JSONDecoder().decode(type, from: JSONEncoder().encode(value)) }
        catch { throw PortableProfileError.invalid("\(field) contains an invalid or unsupported value.") }
    }

    private func validateBlockShape(_ value: ProfileValue, field: String) throws {
        guard let block = value.object else { throw PortableProfileError.invalid("\(field) must be an object.") }
        if let enabled = block["enabled"] {
            guard case .bool = enabled else {
                throw PortableProfileError.invalid("\(field).enabled must be a boolean.")
            }
        }
        guard field == "webForwards" else { return }
        func checkedPort(_ value: ProfileValue?, _ name: String) throws {
            guard case let .number(number) = value,
                  let port = Int(NSDecimalNumber(decimal: number).stringValue), (1...65535).contains(port) else {
                throw PortableProfileError.invalid("\(name) must be an integer between 1 and 65535.")
            }
        }
        if let socks = block["socksPort"], socks != .null { try checkedPort(socks, "socksPort") }
        if let suffixes = block["proxySuffixes"] {
            guard case let .array(values) = suffixes, values.allSatisfy({ $0.string != nil }) else {
                throw PortableProfileError.invalid("proxySuffixes must be an array of strings.")
            }
        }
        if let forwards = block["localForwards"] {
            guard case let .array(values) = forwards else {
                throw PortableProfileError.invalid("localForwards must be an array of objects.")
            }
            for value in values {
                guard let forward = value.object, let name = forward["name"]?.string, !name.isEmpty,
                      let host = forward["remoteHost"]?.string, !host.isEmpty else {
                    throw PortableProfileError.invalid("Each local forward needs a name, remote host and ports.")
                }
                try checkedPort(forward["localPort"], "localPort")
                try checkedPort(forward["remotePort"], "remotePort")
            }
        }
    }

    private func string(_ key: String, allowEmpty: Bool = false) throws -> String {
        guard let text = fields[key]?.string, allowEmpty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PortableProfileError.invalid("\(key) must be \(allowEmpty ? "a" : "a non-empty") string.")
        }
        return text
    }

    private func optionalString(_ key: String) throws -> String? {
        guard let value = fields[key], value != .null else { return nil }
        guard let text = value.string else { throw PortableProfileError.invalid("\(key) must be a string or null.") }
        return text
    }

    private func integer(_ key: String) throws -> Int {
        guard case let .number(number) = fields[key],
              let value = Int(NSDecimalNumber(decimal: number).stringValue) else {
            throw PortableProfileError.invalid("\(key) must be an integer.")
        }
        return value
    }

    private func port(_ key: String) throws -> Int {
        let port = try integer(key)
        guard (1...65535).contains(port) else { throw PortableProfileError.invalid("\(key) must be between 1 and 65535.") }
        return port
    }

    private func optionalPort(_ key: String) throws -> Int? {
        guard let value = fields[key], value != .null else { return nil }
        return try port(key)
    }

    private static func checkSecurity(_ value: ProfileValue, path: String) throws {
        let forbidden: Set<String> = [
            "accesskeyid", "secretaccesskey", "sessiontoken", "credentials", "accesstoken", "refreshtoken",
            "ssoaccesstoken", "clientsecret", "password", "dcvpassword", "secretvalue", "authtoken", "presignedurl",
            "sessionresponse", "ssmsession", "connectionfilepath", "tempfilepath", "privatekey", "privatekeypath",
            "keypath", "browserprofilepath", "helperpath", "executablepath", "attachmentpath", "knownhosts",
            "cookies", "history", "generation", "lease", "ownerpid", "ownerlaunchdate", "consent", "restorejournal"
        ]
        switch value {
        case let .object(object):
            for (key, child) in object {
                let normalized = key.lowercased().filter { $0.isLetter || $0.isNumber }
                guard !forbidden.contains(normalized) else {
                    throw PortableProfileError.invalid("The profile document contains a forbidden credential or machine-local field.")
                }
                try checkSecurity(child, path: path + "." + key)
            }
        case let .array(array):
            for child in array { try checkSecurity(child, path: path) }
        case let .string(text):
            let lower = text.lowercased()
            guard !lower.contains("private key-----"), !lower.contains("x-amz-signature="),
                  !lower.contains("x-amz-credential=") else {
                throw PortableProfileError.invalid("The profile contains private authentication material.")
            }
        case let .number(number):
            guard !number.isNaN else { throw PortableProfileError.invalid("Profile numbers must be finite.") }
        case .bool, .null: break
        }
    }
}
