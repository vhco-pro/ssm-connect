import Foundation
import Observation

/// Persists connection profiles + global settings to `UserDefaults` (G3, F-18, NF-01).
///
/// **No secrets are ever stored** — only the Secrets Manager *id*, never a password.
/// On first launch (`seedIfEmpty`) the store bootstraps a single default profile from
/// `~/.aws/config` (G5). The active profile drives the `ConnectionStateMachine`.
@MainActor
@Observable
final class ProfileStore {
    private(set) var profiles: [ConnectionProfile]
    var activeProfileID: UUID?
    var settings: AppSettings {
        didSet { save() }
    }

    private let defaults: UserDefaults
    private static let profilesKey = "ssmconnect.profiles.v1"
    private static let activeKey = "ssmconnect.activeProfileID.v1"
    private static let settingsKey = "ssmconnect.settings.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.profiles = Self.decode([ConnectionProfile].self, from: defaults, key: Self.profilesKey) ?? []
        self.settings = Self.decode(AppSettings.self, from: defaults, key: Self.settingsKey) ?? .default
        if let raw = defaults.string(forKey: Self.activeKey) {
            self.activeProfileID = UUID(uuidString: raw)
        }
    }

    // MARK: Active profile

    /// The active profile, falling back to the first stored profile or the factory default.
    var activeProfile: ConnectionProfile {
        if let id = activeProfileID, let match = profiles.first(where: { $0.id == id }) {
            return match
        }
        return profiles.first ?? .factoryDefault
    }

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

    // MARK: First-launch seeding (G5)

    /// If no profiles exist yet, seed a single default profile. SSO start URL + regions are
    /// taken from `~/.aws/config` when available (G4), falling back to the factory defaults.
    func seedIfEmpty(parser: AWSConfigParser? = AWSConfigParser.loadDefault(), awsProfileName: String = "workstation-prd") {
        guard profiles.isEmpty else { return }

        var seed = ConnectionProfile.factoryDefault
        if let resolved = parser?.resolvedProfile(named: awsProfileName) {
            if let url = resolved.startUrl, !url.isEmpty { seed.ssoStartUrl = url }
            if let region = resolved.ssoRegion, !region.isEmpty { seed.ssoRegion = region }
            if let account = resolved.accountId, !account.isEmpty { seed.accountId = account }
            if let role = resolved.roleName, !role.isEmpty { seed.roleName = role }
            if let resource = resolved.resourceRegion, !resource.isEmpty { seed.resourceRegion = resource }
        }
        addProfile(seed)
        setActiveProfile(seed.id)
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
