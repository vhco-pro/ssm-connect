import Darwin
import Foundation

extension ConnectionProfile {
    func hasSameWorkstation(as other: ConnectionProfile) -> Bool {
        id == other.id && accountId == other.accountId && roleName == other.roleName
            && ssoStartUrl == other.ssoStartUrl && ssoRegion == other.ssoRegion
            && resourceRegion == other.resourceRegion && instanceTagKey == other.instanceTagKey
            && instanceTagValue == other.instanceTagValue
            && (webForwards?.sshUser?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
                == (other.webForwards?.sshUser?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }
}

struct EditorRecoveryIntent: Codable, Equatable, Sendable {
    let profile: ConnectionProfile
    let instanceID: String
    let user: String
}

@MainActor
final class EditorRecoveryStore {
    private static let key = "ssmconnect.editorRecovery.v1"
    private let store: any KeyValueStoring
    private struct Document: Codable {
        var version = 1
        var intents: [String: EditorRecoveryIntent] = [:]
    }

    init(store: any KeyValueStoring) { self.store = store }

    func intent(for id: UUID) throws -> EditorRecoveryIntent? {
        let intent = try read().intents[id.uuidString.lowercased()]
        guard intent == nil || intent?.profile.id == id else { throw RemoteSSHError.invalidRecoveryState }
        return intent
    }

    func remember(_ intent: EditorRecoveryIntent) throws {
        var document = try read()
        document.intents[intent.profile.id.uuidString.lowercased()] = intent
        try save(document)
    }

    func forget(_ id: UUID) throws {
        var document = try read()
        document.intents.removeValue(forKey: id.uuidString.lowercased())
        try save(document)
    }

    func forgetAll() { store.set(nil, forKey: Self.key) }

    private func read() throws -> Document {
        guard let data = store.data(forKey: Self.key) else { return Document() }
        guard data.count <= 256 * 1024 else { throw RemoteSSHError.invalidRecoveryState }
        do {
            let document = try JSONDecoder().decode(Document.self, from: data)
            guard document.version == 1 else { throw RemoteSSHError.invalidRecoveryState }
            return document
        } catch { throw RemoteSSHError.invalidRecoveryState }
    }

    private func save(_ document: Document) throws {
        let data = try JSONEncoder().encode(document)
        guard data.count <= 256 * 1024 else { throw RemoteSSHError.invalidRecoveryState }
        store.set(data, forKey: Self.key)
    }
}

struct EditorRecoveryRequest: Codable, Sendable {
    enum Reason: String, Codable, Sendable { case targetChanged, authorization, expired }
    let id: UUID
    let profileID: UUID
    let generation: UUID
    let ownerPID: Int32
    let ownerLaunchDate: Date
    let ownerBundleID: String
    let reason: Reason

    init(lease: RemoteSSHLease, reason: Reason) {
        id = UUID()
        profileID = lease.profile.id
        generation = lease.generation
        ownerPID = lease.ownerPID
        ownerLaunchDate = lease.ownerLaunchDate
        ownerBundleID = lease.ownerBundleID
        self.reason = reason
    }

    func matches(_ lease: RemoteSSHLease) -> Bool {
        profileID == lease.profile.id && generation == lease.generation && ownerPID == lease.ownerPID
            && ownerLaunchDate == lease.ownerLaunchDate && ownerBundleID == lease.ownerBundleID
    }

    static func url(for leaseURL: URL) -> URL {
        leaseURL.deletingLastPathComponent().appendingPathComponent("recovery-request.json")
    }

    static func read(from url: URL) throws -> EditorRecoveryRequest? {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { return nil }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              attributes[.ownerAccountID] as? UInt32 == getuid(),
              ((attributes[.posixPermissions] as? Int ?? 0) & 0o077) == 0 else {
            throw RemoteSSHError.configurationConflict
        }
        let data = try Data(contentsOf: url)
        guard data.count < 4096 else { throw RemoteSSHError.invalidRecoveryState }
        do { return try JSONDecoder().decode(EditorRecoveryRequest.self, from: data) }
        catch { throw RemoteSSHError.invalidRecoveryState }
    }

    func write(for leaseURL: URL) throws {
        try BrowserPrivateFiles.write(try JSONEncoder().encode(self), to: Self.url(for: leaseURL))
    }
}

struct EditorReplacement: Equatable, Identifiable {
    let id = UUID()
    let profile: ConnectionProfile
    let previousInstanceID: String
    let instanceID: String
    let user: String
}
