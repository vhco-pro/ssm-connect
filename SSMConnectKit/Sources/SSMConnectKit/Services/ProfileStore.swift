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

    private let defaults: any KeyValueStoring
    private let fallbackProfile = ConnectionProfile.template
    private static let profilesKey = "ssmconnect.profiles.v1"
    private static let activeKey = "ssmconnect.activeProfileID.v1"
    private static let settingsKey = "ssmconnect.settings.v1"
    private static let documentsKey = "ssmconnect.portableDocuments.v1"
    private static let attachmentsKey = "ssmconnect.attachments.v1"
    private var documents: [UUID: PortableProfileDocument] = [:]
    private(set) var attachments: [UUID: ProfileAttachment] = [:]
    private(set) var pendingFiles: [UUID: ProfileFileSnapshot] = [:]
    private(set) var fileErrors: [UUID: String] = [:]
    private(set) var operationError: String?
    public var configurationDidChange: ((ConnectionProfile, AppSettings) -> Void)?
    private var fileMonitor: Task<Void, Never>?

    public convenience init(defaults: UserDefaults = .standard) {
        self.init(store: defaults)
    }

    /// Designated initializer. Takes the storage seam so tests can stay off disk entirely.
    init(store: any KeyValueStoring) {
        self.defaults = store
        self.profiles = Self.decode([ConnectionProfile].self, from: store, key: Self.profilesKey) ?? []
        self.settings = Self.decode(AppSettings.self, from: store, key: Self.settingsKey) ?? .default
        if let raw = store.string(forKey: Self.activeKey) {
            self.activeProfileID = UUID(uuidString: raw)
        }
        do {
            if let data = store.data(forKey: Self.documentsKey) {
                documents = try JSONDecoder().decode([UUID: PortableProfileDocument].self, from: data)
                for document in documents.values { _ = try document.profile(localID: UUID()) }
            }
            if let data = store.data(forKey: Self.attachmentsKey) {
                attachments = try JSONDecoder().decode([UUID: ProfileAttachment].self, from: data)
            }
            startFileMonitor()
        } catch {
            operationError = "Saved profile attachments could not be loaded. Existing local profiles were retained."
        }
        AppQuitHandler.shared.register { [weak self] in self?.fileMonitor?.cancel() }
    }

    // MARK: Active profile

    /// The active profile, falling back to the first stored profile or a blank template
    /// (when no profile has been configured yet).
    public var activeProfile: ConnectionProfile {
        if let id = activeProfileID, let match = profiles.first(where: { $0.id == id }) {
            return match
        }
        return profiles.first ?? fallbackProfile
    }

    /// Whether the user has configured at least one profile (drives first-launch guidance).
    var hasProfiles: Bool { !profiles.isEmpty }

    func setActiveProfile(_ id: UUID) {
        guard profiles.contains(where: { $0.id == id }) else { return }
        activeProfileID = id
        defaults.set(id.uuidString, forKey: Self.activeKey)
        configurationDidChange?(activeProfile, settings)
    }

    // MARK: CRUD

    func addProfile(_ profile: ConnectionProfile) {
        profiles.append(profile)
        if activeProfileID == nil { setActiveProfile(profile.id) }
        save()
    }

    @discardableResult
    func updateProfile(_ profile: ConnectionProfile) -> Bool {
        guard attachments[profile.id] == nil else {
            operationError = "This profile is attached to a file. Edit and save that file in Settings, or save a local copy."
            return false
        }
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else {
            operationError = "The profile no longer exists."
            return false
        }
        profiles[index] = profile
        save()
        return true
    }

    /// Duplicate a profile (new id, " Copy" suffix) and return the copy.
    @discardableResult
    func duplicateProfile(_ id: UUID) -> ConnectionProfile? {
        guard let original = profiles.first(where: { $0.id == id }) else { return nil }
        var copy = original
        copy.id = UUID()
        copy.name = "\(original.name) Copy"
        if let document = documents[id] {
            do { documents[copy.id] = try document.withNewIdentity() }
            catch { operationError = error.localizedDescription; return nil }
        }
        profiles.append(copy)
        save()
        return copy
    }

    func deleteProfile(_ id: UUID) {
        attachments.removeValue(forKey: id)
        documents.removeValue(forKey: id)
        pendingFiles.removeValue(forKey: id)
        fileErrors.removeValue(forKey: id)
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
        do {
            defaults.set(try JSONEncoder().encode(documents), forKey: Self.documentsKey)
            defaults.set(try JSONEncoder().encode(attachments), forKey: Self.attachmentsKey)
        } catch { operationError = "The profile attachment metadata could not be saved." }
        defaults.set(activeProfileID?.uuidString, forKey: Self.activeKey)
        configurationDidChange?(activeProfile, settings)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from defaults: any KeyValueStoring, key: String) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func encode<T: Encodable>(_ value: T, to defaults: any KeyValueStoring, key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        defaults.set(data, forKey: key)
    }
}

extension ProfileStore {
    @discardableResult
    func saveLocalCopy(_ profile: ConnectionProfile, preservingFrom originalID: UUID) throws -> ConnectionProfile {
        var copy = profile
        copy.id = UUID()
        copy.name += " Copy"
        if let original = documents[originalID] {
            documents[copy.id] = try original.updating(profile: copy).withNewIdentity()
        }
        addProfile(copy)
        return copy
    }

    @discardableResult
    func importFile(_ preview: ProfileFileSnapshot, attach: Bool) throws -> ConnectionProfile {
        let current = try ProfileFileIO.read(preview.url)
        guard current.revision == preview.revision else { throw PortableProfileError.conflict }
        if attach, attachments.values.contains(where: { $0.url == current.url }) {
            throw PortableProfileError.invalid("This file is already attached. Select its existing local profile.")
        }
        let profile = try current.document.profile(localID: UUID())
        documents[profile.id] = current.document
        if attach { attachments[profile.id] = .init(url: current.url, revision: current.revision) }
        addProfile(profile)
        startFileMonitor()
        return profile
    }

    func saveEditedProfile(_ profile: ConnectionProfile, expected: ProfileFileRevision?,
                           acceptCanonicalFormatting: Bool) throws {
        guard var attachment = attachments[profile.id] else {
            guard updateProfile(profile) else { throw PortableProfileError.invalid("The local profile no longer exists.") }
            return
        }
        guard let expected, expected == attachment.revision else { throw PortableProfileError.conflict }
        guard attachment.canonicalSaveAccepted || acceptCanonicalFormatting else {
            throw PortableProfileError.formattingConsentRequired
        }
        guard let original = documents[profile.id], let index = profiles.firstIndex(where: { $0.id == profile.id }) else {
            throw PortableProfileError.invalid("The attached profile metadata is missing. Save a local copy.")
        }
        let document = try original.updating(profile: profile)
        attachment.revision = try ProfileFileIO.save(document, to: attachment.url, expected: expected)
        attachment.canonicalSaveAccepted = true
        attachments[profile.id] = attachment
        documents[profile.id] = document
        profiles[index] = profile
        pendingFiles.removeValue(forKey: profile.id)
        fileErrors.removeValue(forKey: profile.id)
        operationError = nil
        save()
    }

    func exportDocument(_ id: UUID) throws -> PortableProfileDocument {
        guard let profile = profiles.first(where: { $0.id == id }) else {
            throw PortableProfileError.invalid("Select a local profile to export.")
        }
        let document = try documents[id]?.updating(profile: profile) ?? PortableProfileDocument(profile: profile)
        documents[id] = document
        save()
        return document
    }

    func detachFile(_ id: UUID) {
        attachments.removeValue(forKey: id)
        pendingFiles.removeValue(forKey: id)
        fileErrors.removeValue(forKey: id)
        save()
    }

    func locateFile(_ id: UUID, at url: URL) throws {
        guard var attachment = attachments[id], let original = documents[id] else {
            throw PortableProfileError.invalid("Select an attached profile first.")
        }
        let snapshot = try ProfileFileIO.read(url)
        guard try snapshot.document.id == original.id else {
            throw PortableProfileError.invalid("This is a different document. Attach it as a new profile instead.")
        }
        guard !attachments.contains(where: { $0.key != id && $0.value.url == snapshot.url }) else {
            throw PortableProfileError.invalid("That file is already attached to another local profile.")
        }
        attachment.url = snapshot.url
        attachments[id] = attachment
        pendingFiles[id] = snapshot
        fileErrors.removeValue(forKey: id)
        save()
    }

    func refreshAttachedFiles() {
        for (id, attachment) in attachments {
            do {
                let current = try ProfileFileIO.read(attachment.url)
                guard let original = documents[id], try current.document.id == original.id else {
                    throw PortableProfileError.invalid("The file's document identity changed. Attach it as a new profile; existing access was retained.")
                }
                fileErrors.removeValue(forKey: id)
                if current.revision != attachment.revision { pendingFiles[id] = current }
                else { pendingFiles.removeValue(forKey: id) }
            } catch {
                pendingFiles.removeValue(forKey: id)
                fileErrors[id] = "Profile file unavailable or invalid: \(error.localizedDescription) Locate it, detach it, or save a local copy. Existing access was retained."
            }
        }
    }

    func applyPendingFile(_ id: UUID) throws {
        guard let pending = pendingFiles[id], var attachment = attachments[id],
              let index = profiles.firstIndex(where: { $0.id == id }) else {
            throw PortableProfileError.invalid("There are no validated external changes to apply.")
        }
        let current = try ProfileFileIO.read(attachment.url)
        guard current.revision == pending.revision else { throw PortableProfileError.conflict }
        let profile = try current.document.profile(localID: id,
            localBrowserProfilePath: profiles[index].webForwards?.browserProfilePath)
        profiles[index] = profile
        documents[id] = current.document
        attachment.revision = current.revision
        attachments[id] = attachment
        pendingFiles.removeValue(forKey: id)
        fileErrors.removeValue(forKey: id)
        save()
    }

    private func startFileMonitor() {
        guard fileMonitor == nil, !attachments.isEmpty else { return }
        fileMonitor = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) }
                catch is CancellationError { return }
                catch {
                    self?.operationError = "Profile file monitoring stopped. Use Reload to check attached files."
                    return
                }
                guard let self else { return }
                self.refreshAttachedFiles()
            }
        }
    }
}
