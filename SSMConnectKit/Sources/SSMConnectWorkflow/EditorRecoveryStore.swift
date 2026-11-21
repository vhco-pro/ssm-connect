import Foundation
import SSMConnectDomain

extension ConnectionProfile {
    package func hasSameWorkstation(as other: ConnectionProfile) -> Bool {
        id == other.id && accountId == other.accountId && roleName == other.roleName
            && ssoStartUrl == other.ssoStartUrl && ssoRegion == other.ssoRegion
            && resourceRegion == other.resourceRegion && instanceTagKey == other.instanceTagKey
            && instanceTagValue == other.instanceTagValue
            && (webForwards?.sshUser?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
                == (other.webForwards?.sshUser?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }
}

package enum WorkstationRecoveryReadiness {
    package static func isPending(_ error: Error) -> Bool {
        if let error = error as? EC2Error, case .noMatchingInstance = error { return true }
        if let error = error as? SSMError, case .notOnlineInTime = error { return true }
        if let error = error as? RemoteSSHError, case .workstationNotReady = error { return true }
        if let error = error as? StageTimeoutError {
            return error.stage == "Editor SSM readiness" || error.stage == "Web forwards SSM readiness"
        }
        return false
    }
}

package struct EditorRecoveryIntent: Codable, Equatable, Sendable {
    package let profile: ConnectionProfile
    package let instanceID: String
    package let user: String

    package init(profile: ConnectionProfile, instanceID: String, user: String) {
        self.profile = profile
        self.instanceID = instanceID
        self.user = user
    }
}

@MainActor
package final class EditorRecoveryStore {
    private static let key = "ssmconnect.editorRecovery.v1"
    private let store: any KeyValueStoring
    private struct Document: Codable {
        package var version = 1
        package var intents: [String: EditorRecoveryIntent] = [:]
    }

    package init(store: any KeyValueStoring) { self.store = store }

    package func intent(for id: UUID) throws -> EditorRecoveryIntent? {
        let intent = try read().intents[id.uuidString.lowercased()]
        guard intent == nil || intent?.profile.id == id else { throw RemoteSSHError.invalidRecoveryState }
        return intent
    }

    package func remember(_ intent: EditorRecoveryIntent) throws {
        var document = try read()
        document.intents[intent.profile.id.uuidString.lowercased()] = intent
        try save(document)
    }

    package func forget(_ id: UUID) throws {
        var document = try read()
        document.intents.removeValue(forKey: id.uuidString.lowercased())
        try save(document)
    }

    package func forgetAll() { store.set(nil, forKey: Self.key) }

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

package struct EditorRecoveryRequest: Codable, Sendable {
    package enum Reason: String, Codable, Sendable { case targetChanged, authorization, expired }
    package let id: UUID
    package let profileID: UUID
    package let generation: UUID
    package let ownerPID: Int32
    package let ownerLaunchDate: Date
    package let ownerBundleID: String
    package let reason: Reason

    package init(lease: RemoteSSHLease, reason: Reason) {
        id = UUID()
        profileID = lease.profile.id
        generation = lease.generation
        ownerPID = lease.ownerPID
        ownerLaunchDate = lease.ownerLaunchDate
        ownerBundleID = lease.ownerBundleID
        self.reason = reason
    }

    package func matches(_ lease: RemoteSSHLease) -> Bool {
        profileID == lease.profile.id && generation == lease.generation && ownerPID == lease.ownerPID
            && ownerLaunchDate == lease.ownerLaunchDate && ownerBundleID == lease.ownerBundleID
    }

    package static func url(for leaseURL: URL) -> URL {
        leaseURL.deletingLastPathComponent().appendingPathComponent("recovery-request.json")
    }

    package static func read(from url: URL, files: OwnerOnlyFiles) throws -> EditorRecoveryRequest? {
        let attributes: [FileAttributeKey: Any]
        do { attributes = try FileManager.default.attributesOfItem(atPath: url.path) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { return nil }
        guard attributes[.type] as? FileAttributeType == .typeRegular, files.isOwnerOnly(url, attributes) else {
            throw RemoteSSHError.configurationConflict
        }
        guard (attributes[.size] as? NSNumber)?.intValue ?? Int.max < 4096 else {
            throw RemoteSSHError.invalidRecoveryState
        }
        let data = try Data(contentsOf: url)
        guard data.count < 4096 else { throw RemoteSSHError.invalidRecoveryState }
        do { return try JSONDecoder().decode(EditorRecoveryRequest.self, from: data) }
        catch { throw RemoteSSHError.invalidRecoveryState }
    }

    package func write(for leaseURL: URL) throws {
        try BrowserPrivateFiles.write(try JSONEncoder().encode(self), to: Self.url(for: leaseURL))
    }
}

package struct EditorReplacement: Equatable, Identifiable {
    package let id = UUID()
    package let profile: ConnectionProfile
    package let previousInstanceID: String
    package let instanceID: String
    package let user: String

    package init(profile: ConnectionProfile, previousInstanceID: String, instanceID: String, user: String) {
        self.profile = profile
        self.previousInstanceID = previousInstanceID
        self.instanceID = instanceID
        self.user = user
    }
}
