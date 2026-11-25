import Foundation
import Testing
@testable import SSMConnectDomain
@testable import SSMConnectHelperCore
@testable import SSMConnectWorkflow

/// Saving an attached profile file replaces only that file, as on macOS: the folder the user keeps
/// it in (Documents, a team share) keeps its own access rules, and the file keeps its mode (T28,
/// AC-14).
@Suite("Attached profile file writer")
@MainActor
struct AttachedFileWriterTests {
    static func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("attached-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("Saving leaves the file's folder as it was")
    func folderUntouched() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #if os(Windows)
        // A temporary folder inherits the profile's rules, which also admit SYSTEM and Administrators.
        #expect(!OwnerOnlyFiles.windows.isOwnerOnly(folder, [:]))
        #else
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        #endif
        let file = folder.appendingPathComponent("workstation.json")
        let files = PortableProfileFiles(replace: AttachedFileWriter.replace)
        let document = try PortableProfileDocument(profile: HelperCommandTests.configured())
        let first = try files.save(document, to: file, expected: nil, beforeCommit: {})
        _ = try files.save(document, to: file, expected: first, beforeCommit: {})
        #if os(Windows)
        #expect(!OwnerOnlyFiles.windows.isOwnerOnly(folder, [:]))
        #else
        #expect((try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int) == 0o755)
        #endif
        #expect(try files.read(file).document.id == document.id)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["workstation.json"])
    }

    #if !os(Windows)
    @Test("Saving keeps the file's own mode")
    func modeKept() throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("workstation.json")
        let files = PortableProfileFiles(replace: AttachedFileWriter.replace)
        let document = try PortableProfileDocument(profile: HelperCommandTests.configured())
        let first = try files.save(document, to: file, expected: nil, beforeCommit: {})
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) == 0o600)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        let revision = try #require(try files.existingRevision(file))
        _ = try files.save(document, to: file, expected: revision, beforeCommit: {})
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) == 0o644)
        _ = first
    }
    #endif
}
