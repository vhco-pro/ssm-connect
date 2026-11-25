import Foundation
import Testing
@testable import SSMConnectWorkflow

/// Before every launch the exact file is checked: an executable must carry this build's ID and the
/// plugin must have the hash this build recorded. A replaced file is refused with the update
/// message and a removed one with the removal message (T22, AC-17).
@Suite("Installation check")
struct InstallationCheckTests {
    static func file(_ contents: Data) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ssm-check-" + UUID().uuidString)
        try contents.write(to: url)
        return url.path
    }

    static func executable(build: String) -> Data {
        Data("\u{7F}ELF padding ".utf8) + InstallationCheck.marker(for: build) + Data(" more bytes".utf8)
    }

    @Test("An executable carrying this build's ID passes")
    func sameBuild() throws {
        let path = try Self.file(Self.executable(build: "1.4.0+abc"))
        defer { try? FileManager.default.removeItem(atPath: path) }
        try InstallationCheck(build: "1.4.0+abc", pluginSHA256: nil).executable(at: path)
    }

    @Test("An executable of another build, or without a build ID, is refused as updated")
    func otherBuild() throws {
        for contents in [Self.executable(build: "1.5.0+def"), Data("no marker here".utf8),
                         Self.executable(build: "1.4.0+abcd")] {
            let path = try Self.file(contents)
            defer { try? FileManager.default.removeItem(atPath: path) }
            #expect(throws: InstallationChange.updated) {
                try InstallationCheck(build: "1.4.0+abc", pluginSHA256: nil).executable(at: path)
            }
        }
    }

    @Test("A missing executable or plugin is refused as removed")
    func removed() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("ssm-missing-" + UUID().uuidString).path
        let check = InstallationCheck(build: "1.4.0", pluginSHA256: String(repeating: "0", count: 64))
        #expect(throws: InstallationChange.removed) { try check.executable(at: missing) }
        #expect(throws: InstallationChange.removed) { try check.plugin(at: missing) }
        #expect(throws: InstallationChange.removed) { try InstallationCheck(build: "dev", pluginSHA256: nil).plugin(at: missing) }
    }

    @Test("The plugin passes only with the hash this build recorded")
    func pluginHash() throws {
        let path = try Self.file(Data("plugin bytes".utf8))
        defer { try? FileManager.default.removeItem(atPath: path) }
        let recorded = InstallationCheck.sha256(Data("plugin bytes".utf8))
        #expect(recorded == "9d1107dfd30c229b15fb8796ee2b74782f1e5e1ce9ab72756209257a000cf0a6")
        try InstallationCheck(build: "1.4.0", pluginSHA256: recorded.uppercased()).plugin(at: path)
        #expect(throws: InstallationChange.updated) {
            try InstallationCheck(build: "1.4.0", pluginSHA256: InstallationCheck.sha256(Data("other".utf8))).plugin(at: path)
        }
    }

    @Test("A development build records no plugin hash and accepts any present plugin")
    func developmentBuild() throws {
        let path = try Self.file(Data("any plugin".utf8))
        defer { try? FileManager.default.removeItem(atPath: path) }
        try InstallationCheck(build: "dev", pluginSHA256: nil).plugin(at: path)
    }

    @Test("The installed build is the ID inside its marker, and the messages are the design's")
    func installedBuild() {
        #expect(InstallationCheck.marker(for: InstalledBuild.current) == Data(InstalledBuild.marker.utf8))
        #expect(InstallationChange.updated.localizedDescription == "SSM Connect was updated; restart it.")
        #expect(InstallationChange.removed.localizedDescription == "SSM Connect was removed; quit it.")
    }
}
