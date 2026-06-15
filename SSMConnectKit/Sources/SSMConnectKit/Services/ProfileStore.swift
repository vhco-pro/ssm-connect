import Foundation
import Observation

/// Persists connection profiles + global settings to `UserDefaults` (G3, F-18, NF-01).
///
/// **No secrets are ever stored** — only the Secrets Manager *id*, never a password.
/// Nothing about any AWS environment is baked into the app: there are no profiles until the
/// user creates one (the menu/Settings guide first-launch users to import from `~/.aws/config`).
/// The active profile drives the `ConnectionStateMachine`.
@MainActor
@Observable
public final class ProfileStore {
    private(set) var profiles: [ConnectionProfile]
    var activeProfileID: UUID?
    public var settings: AppSettings {
        didSet { save() }
    }

    private let defaults: UserDefaults
    private static let profilesKey = "ssmconnect.profiles.v1"
    private static let activeKey = "ssmconnect.activeProfileID.v1"
    private static let settingsKey = "ssmconnect.settings.v1"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.profiles = Self.decode([ConnectionProfile].self, from: defaults, key: Self.profilesKey) ?? []
        self.settings = Self.decode(AppSettings.self, from: defaults, key: Self.settingsKey) ?? .default
        if let raw = defaults.string(forKey: Self.activeKey) {
            self.activeProfileID = UUID(uuidString: raw)
        }
    }

    // MARK: Active profile

    /// The active profile, falling back to the first stored profile or a blank template
    /// (when no profile has been configured yet).
    public var activeProfile: ConnectionProfile {
        if let id = activeProfileID, let match = profiles.first(where: { $0.id == id }) {
            return match
        }
        return profiles.first ?? .template
    }

    /// Whether the user has configured at least one profile (drives first-launch guidance).
    var hasProfiles: Bool { !profiles.isEmpty }

    func setActiveProfile(_ id: UUID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        activeProfileID = id
        defaults.set(id.uuidString, forKey: Self.activeKey)
    }

    // MARK: CRUD

    func addProfile(_ profile: ConnectionProfile) {
        profiles.append(profile)
        if activeProfileID == nil { setActiveProfile(profile.id) }
        save()
    }

    func updateProfile(_ profile: ConnectionProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
        save()
    }

    /// Duplicate a profile (new id, " Copy" suffix) and return the copy.
    @discardableResult
    func duplicateProfile(_ id: UUID) -> ConnectionProfile? {
        guard let original = profiles.first(where: { $0.id == id }) else { return nil }
        var copy = original
        copy.id = UUID()
        copy.name = "\(original.name) Copy"
        profiles.append(copy)
        save()
        return copy
    }

    func deleteProfile(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        if activeProfileID == id {
            activeProfileID = profiles.first?.id
            defaults.set(activeProfileID?.uuidString, forKey: Self.activeKey)
        }
        save()
    }

    // MARK: Import from ~/.aws/config (F-18)

    /// Profiles available to import from `~/.aws/config` (SSO start URL + regions/account/role
    /// pre-filled; instance tag value + secret left for the user). Nothing is auto-seeded — the
    /// user explicitly picks one. Returns an empty list if there's no usable config.
    func importableProfiles(parser: AWSConfigParser? = AWSConfigParser.loadDefault()) -> [ConnectionProfile] {
        guard let parser else { return [] }
        return parser.resolvedProfiles().map { ConnectionProfile(name: $0.name, awsConfig: $0.resolved) }
    }

    // MARK: Persistence

    private func save() {
        Self.encode(profiles, to: defaults, key: Self.profilesKey)
        Self.encode(settings, to: defaults, key: Self.settingsKey)
        defaults.set(activeProfileID?.uuidString, forKey: Self.activeKey)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from defaults: UserDefaults, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func encode<T: Encodable>(_ value: T, to defaults: UserDefaults, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}
