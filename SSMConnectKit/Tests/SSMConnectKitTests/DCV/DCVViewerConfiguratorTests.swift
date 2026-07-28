import Foundation
import Testing
@testable import SSMConnectKit

@Suite("GLibKeyfileDCVViewerConfigurator (HiDPI, CL-06)")
struct DCVViewerConfiguratorTests {
    private let group = "[com/nicesoftware/DcvViewer]"
    private let line = "enable-high-pixel-density=true"

    private func tempKeyfile(_ contents: String? = nil) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("hidpi-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent("keyfile")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let contents { try contents.write(to: url, atomically: true, encoding: .utf8) }
        return url
    }

    // MARK: pure merge logic (enableHiDPIIfAbsent)

    @Test("adds group + key to an empty/absent keyfile")
    func addsToEmpty() throws {
        let out = try #require(GLibKeyfileDCVViewerConfigurator.enableHiDPIIfAbsent(in: ""))
        #expect(out.contains(group))
        #expect(out.contains(line))
    }

    @Test("inserts the key under an existing group, preserving other keys")
    func insertsUnderExistingGroup() throws {
        let input = "\(group)\nquality=smooth\n"
        let out = try #require(GLibKeyfileDCVViewerConfigurator.enableHiDPIIfAbsent(in: input))
        #expect(out.contains(line))
        #expect(out.contains("quality=smooth"))     // HDPI-5: preserved
    }

    @Test("no-op when the key is already present (respects user choice), true or false")
    func respectsExistingChoice() {
        for existing in ["enable-high-pixel-density=true", "enable-high-pixel-density=false"] {
            let input = "\(group)\n\(existing)\n"
            #expect(GLibKeyfileDCVViewerConfigurator.enableHiDPIIfAbsent(in: input) == nil)
        }
    }

    @Test("preserves unrelated groups")
    func preservesOtherGroups() throws {
        let input = "[org/gnome/other]\nfoo=bar\n"
        let out = try #require(GLibKeyfileDCVViewerConfigurator.enableHiDPIIfAbsent(in: input))
        #expect(out.contains("[org/gnome/other]"))
        #expect(out.contains("foo=bar"))
        #expect(out.contains(group))
        #expect(out.contains(line))
    }

    // MARK: ensurePreferredSettings (I/O + scale gate)

    @Test("writes the key on a 2x display when absent")
    func writesOnRetina() throws {
        let url = try tempKeyfile()
        var sut = GLibKeyfileDCVViewerConfigurator(); sut.keyfileURL = url
        sut.ensurePreferredSettings(backingScale: 2)
        let written = try String(contentsOf: url, encoding: .utf8)
        #expect(written.contains(group))
        #expect(written.contains(line))
    }

    @Test("does nothing on a 1x display")
    func skipsOnNonRetina() throws {
        let url = try tempKeyfile("[keep]\nx=1\n")
        var sut = GLibKeyfileDCVViewerConfigurator(); sut.keyfileURL = url
        sut.ensurePreferredSettings(backingScale: 1)
        #expect(try String(contentsOf: url, encoding: .utf8) == "[keep]\nx=1\n")   // unchanged
    }

    @Test("leaves an already-configured keyfile byte-for-byte unchanged")
    func leavesConfiguredUnchanged() throws {
        let original = "\(group)\nenable-high-pixel-density=false\n"
        let url = try tempKeyfile(original)
        var sut = GLibKeyfileDCVViewerConfigurator(); sut.keyfileURL = url
        sut.ensurePreferredSettings(backingScale: 2)
        #expect(try String(contentsOf: url, encoding: .utf8) == original)
    }
}
