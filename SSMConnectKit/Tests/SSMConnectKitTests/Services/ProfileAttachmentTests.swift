import Darwin
import Foundation
import Testing
@testable import SSMConnectKit

@Suite("Attached profile files")
@MainActor
struct ProfileAttachmentTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("ssm-profile-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func clean(_ directory: URL) {
        do { try FileManager.default.removeItem(at: directory) }
        catch { Issue.record("Could not remove owned profile fixture: \(error.localizedDescription)") }
    }

    private func fixture(_ directory: URL, name: String = "profile.yaml") throws -> ProfileFileSnapshot {
        let url = directory.appendingPathComponent(name)
        _ = try ProfileFileIO.save(PortableProfileDocument(profile: portableExample()), to: url, expected: nil)
        return try ProfileFileIO.read(url)
    }

    @Test("CFG-04: GUI edits an attached file")
    func checkedSaveAndLocalPathsSurviveRestart() throws {
        let directory = try directory()
        defer { clean(directory) }
        let initial = try fixture(directory)
        let commented = Data("# Human-authored comment\n".utf8) + (try Data(contentsOf: initial.url))
        try commented.write(to: initial.url)
        let preview = try ProfileFileIO.read(initial.url)
        let defaults = InMemoryKeyValueStore()
        let store = ProfileStore(store: defaults)
        var profile = try store.importFile(preview, attach: true)
        #expect(try Data(contentsOf: preview.url) == commented)
        profile.name = "Saved in GUI"
        profile.webForwards?.browserProfilePath = "/local/device/browser"
        #expect(throws: PortableProfileError.formattingConsentRequired) {
            try store.saveEditedProfile(profile, expected: preview.revision, acceptCanonicalFormatting: false)
        }
        try store.saveEditedProfile(profile, expected: preview.revision, acceptCanonicalFormatting: true)
        #expect(try ProfileFileIO.read(preview.url).document.profile(localID: profile.id).name == "Saved in GUI")
        #expect(!String(decoding: try Data(contentsOf: preview.url), as: UTF8.self).contains("/local/device"))
        #expect(!String(decoding: try Data(contentsOf: preview.url), as: UTF8.self).contains("Human-authored"))
        #expect(try ProfileFileIO.read(preview.url).revision.permissions == preview.revision.permissions)
        let reloaded = ProfileStore(store: defaults)
        #expect(reloaded.profiles == store.profiles)
        #expect(reloaded.attachments == store.attachments)
        #expect(reloaded.profiles[0].webForwards?.browserProfilePath == "/local/device/browser")
    }

    @Test("CFG-05: Automation edits the attached file")
    func validExternalChangesRemainPendingUntilApply() throws {
        let directory = try directory()
        defer { clean(directory) }
        let preview = try fixture(directory)
        let store = ProfileStore(store: InMemoryKeyValueStore())
        let original = try store.importFile(preview, attach: true)
        var changed = original
        changed.instanceTagValue = "new-workstation"
        _ = try ProfileFileIO.save(preview.document.updating(profile: changed), to: preview.url, expected: preview.revision)
        store.refreshAttachedFiles()
        #expect(store.profiles[0] == original)
        #expect(store.pendingFiles[original.id] != nil)
        try store.applyPendingFile(original.id)
        #expect(store.profiles[0].instanceTagValue == "new-workstation")
        #expect(store.profiles[0].id == original.id)
        #expect(store.pendingFiles[original.id] == nil)
    }

    @Test("CFG-06: Invalid, partial, missing or read-only file")
    func invalidAndMissingFilesRetainLastGoodProfile() throws {
        let directory = try directory()
        defer { clean(directory) }
        let preview = try fixture(directory)
        let store = ProfileStore(store: InMemoryKeyValueStore())
        let original = try store.importFile(preview, attach: true)
        try Data("schemaVersion: [partial".utf8).write(to: preview.url)
        store.refreshAttachedFiles()
        #expect(store.profiles[0] == original)
        #expect(store.fileErrors[original.id] != nil)
        #expect(store.pendingFiles[original.id] == nil)
        try FileManager.default.removeItem(at: preview.url)
        store.refreshAttachedFiles()
        #expect(store.profiles[0] == original)
        #expect(store.attachments[original.id] != nil)
        #expect(store.fileErrors[original.id] != nil)
        let copy = try store.saveLocalCopy(original, preservingFrom: original.id)
        #expect(copy.id != original.id)
        #expect(store.attachments[copy.id] == nil)
    }

    @Test("CFG-06: Read-only and symbolic-link files are not overwritten")
    func readOnlyAndSymlinkRefusal() throws {
        let directory = try directory()
        defer { clean(directory) }
        let preview = try fixture(directory)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: preview.url.path)
        let readOnly = try ProfileFileIO.read(preview.url)
        #expect(!readOnly.isWritable)
        #expect(throws: PortableProfileError.self) {
            try ProfileFileIO.save(readOnly.document, to: readOnly.url, expected: readOnly.revision)
        }
        let link = directory.appendingPathComponent("link.yaml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: readOnly.url)
        #expect(throws: PortableProfileError.self) { try ProfileFileIO.read(link) }
        #expect(throws: PortableProfileError.self) {
            try ProfileFileIO.save(readOnly.document, to: link, expected: readOnly.revision)
        }
    }

    @Test("CFG-07: External edit races GUI Save")
    func conflictsPreserveBothExternalBytesAndGuiDraft() throws {
        let directory = try directory()
        defer { clean(directory) }
        let preview = try fixture(directory)
        let store = ProfileStore(store: InMemoryKeyValueStore())
        var draft = try store.importFile(preview, attach: true)
        draft.name = "GUI draft"
        var external = draft
        external.name = "External edit"
        let externalBytes = try ProfileDocumentCodec.write(preview.document.updating(profile: external), format: .yaml)
        #expect(throws: PortableProfileError.conflict) {
            try ProfileFileIO.save(preview.document.updating(profile: draft), to: preview.url, expected: preview.revision) {
                try externalBytes.write(to: preview.url)
            }
        }
        #expect(try Data(contentsOf: preview.url) == externalBytes)
        #expect(draft.name == "GUI draft")
        #expect(throws: PortableProfileError.conflict) {
            try store.saveEditedProfile(draft, expected: preview.revision, acceptCanonicalFormatting: true)
        }
        let copy = try store.saveLocalCopy(draft, preservingFrom: draft.id)
        #expect(copy.name == "GUI draft Copy")
        #expect(try Data(contentsOf: preview.url) == externalBytes)
    }

    @Test("CFG-08: Shared identity collides with an existing profile")
    func portableUUIDNeverBecomesLocalOwnership() throws {
        let directory = try directory()
        defer { clean(directory) }
        let preview = try fixture(directory)
        let store = ProfileStore(store: InMemoryKeyValueStore())
        var existing = ConnectionProfile.example
        existing.id = try preview.document.id
        store.addProfile(existing)
        let imported = try store.importFile(preview, attach: true)
        #expect(imported.id != existing.id)
        #expect(store.profiles[0] == existing)
        #expect(store.attachments[existing.id] == nil)
        #expect(throws: PortableProfileError.self) { try store.importFile(preview, attach: true) }
        let secondURL = directory.appendingPathComponent("second.yaml")
        try Data(contentsOf: preview.url).write(to: secondURL)
        let second = try store.importFile(ProfileFileIO.read(secondURL), attach: true)
        #expect(second.id != imported.id)
        #expect(try store.exportDocument(imported.id).id == preview.document.id)
    }

    @Test("CFG-11: Attach/import with default app settings")
    func attachImportDetachDoNotOptIntoConnections() throws {
        let directory = try directory()
        defer { clean(directory) }
        let preview = try fixture(directory)
        let store = ProfileStore(store: InMemoryKeyValueStore())
        let settings = store.settings
        let before = try Data(contentsOf: preview.url)
        let imported = try store.importFile(preview, attach: true)
        #expect(store.settings == settings)
        #expect(try Data(contentsOf: preview.url) == before)
        store.detachFile(imported.id)
        #expect(store.profiles.first == imported)
        #expect(store.settings == settings)
        #expect(store.attachments.isEmpty)
        #expect(try Data(contentsOf: preview.url) == before)
    }

    @Test("AUTH-05: Configuration changes notify recovery without opening the menu")
    func configurationNotificationIsImmediate() throws {
        let store = ProfileStore(store: InMemoryKeyValueStore())
        var profile = ConnectionProfile.example
        store.addProfile(profile)
        var selected: [ConnectionProfile] = []
        store.configurationDidChange = { profile, _ in selected.append(profile) }
        profile.instanceTagValue = "different-workstation"
        #expect(store.updateProfile(profile))
        #expect(selected.last == profile)
        var second = profile
        second.id = UUID()
        store.addProfile(second)
        store.setActiveProfile(second.id)
        #expect(selected.last?.id == second.id)
    }

    @Test("CFG-04: Stored GUI save and re-export retain unknown optional fields")
    func storePreservesUnknownValuesAcrossGuiAndExport() throws {
        let directory = try directory()
        defer { clean(directory) }
        let url = directory.appendingPathComponent("future.json")
        var fields = try PortableProfileDocument(profile: portableExample()).fields
        fields["futureConfiguration"] = .object(["numeric": .number(9_007_199_254_740_993), "enabled": .bool(true)])
        let document = try PortableProfileDocument(fields: fields)
        _ = try ProfileFileIO.save(document, to: url, expected: nil)
        let preview = try ProfileFileIO.read(url)
        let store = ProfileStore(store: InMemoryKeyValueStore())
        var profile = try store.importFile(preview, attach: true)
        profile.name = "Changed by GUI"
        try store.saveEditedProfile(profile, expected: preview.revision, acceptCanonicalFormatting: true)
        let saved = try ProfileFileIO.read(url).document
        let exported = try store.exportDocument(profile.id)
        #expect(saved.fields["futureConfiguration"] == fields["futureConfiguration"])
        #expect(exported.fields["futureConfiguration"] == fields["futureConfiguration"])
        #expect(try exported.id == document.id)
        #expect(try saved.id == document.id)
    }

    @Test("CFG-05: File monitoring detects and stages an external edit without manual Reload")
    func automaticMonitoringStagesOnly() async throws {
        let directory = try directory()
        defer { clean(directory) }
        let preview = try fixture(directory)
        let store = ProfileStore(store: InMemoryKeyValueStore())
        let original = try store.importFile(preview, attach: true)
        var external = original
        external.name = "Detected automatically"
        _ = try ProfileFileIO.save(preview.document.updating(profile: external), to: preview.url, expected: preview.revision)
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while store.pendingFiles[original.id] == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(store.pendingFiles[original.id] != nil)
        #expect(store.profiles[0] == original)
    }
}
