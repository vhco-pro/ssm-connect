import Foundation
import Testing
@testable import SSMConnectDomain
@testable import SSMConnectHelperCore
@testable import SSMConnectHelperProtocol
@testable import SSMConnectWorkflow

/// The helper commands behind the Windows and Linux shells' macOS parity (T54, AC-29): every command
/// the parity inventory names exists, and each keeps the rule the macOS interface applies.
@Suite("macOS parity commands")
@MainActor
struct ParityCommandTests {
    typealias Fixture = HelperCommandTests.Fixture

    /// `contracts/macos-parity.json`, found from this file's place in the repository.
    static func inventoryCommands() throws -> Set<String> {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("contracts/macos-parity.json"))
        let document = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entries = try #require(document["entries"] as? [[String: Any]])
        var names: Set<String> = []
        for entry in entries {
            guard let helper = entry["helper"] as? [String: Any] else { continue }
            if let command = helper["command"] as? String { names.insert(command) }
            if let commands = helper["commands"] as? [String] { names.formUnion(commands) }
            if let cancel = helper["cancel"] as? [String: Any], let otherwise = cancel["otherwise"] as? String { names.insert(otherwise) }
        }
        return names
    }

    static func outcome(_ f: Fixture, _ id: String) -> String {
        switch f.outbox.result(id) {
        case .completed: return "completed"
        case let .failed(error): return "failed:\(error.code)"
        case .cancelled: return "cancelled"
        case nil: return f.outbox.rejection(id).map { "rejected:\($0.code)" } ?? "none"
        }
    }

    static func second() -> ConnectionProfile {
        var profile = HelperCommandTests.configured()
        profile.id = UUID(uuidString: "66666666-6666-4666-8666-666666666666")!
        profile.name = "Second"
        return profile
    }

    @Test("Every command the parity inventory names is in the helper's command table")
    func inventoryNamesOnlyKnownCommands() async throws {
        let f = try await HelperCommandTests.fixture()
        let table = f.runtime.commands()
        let names = try Self.inventoryCommands()
        #expect(names.count > 20)
        for name in names.sorted() { #expect(table[name] != nil, "no helper command \(name)") }
    }

    @Test("Deleting the active profile makes the first remaining one active, and the last profile cannot be deleted")
    func deleteRules() async throws {
        let f = try await HelperCommandTests.fixture()
        try await HelperCommandTests.save(f, Self.second())
        try await HelperCommandTests.save(f, HelperCommandTests.configured())
        await HelperCommandTests.run(f, "d1", "deleteProfile", ["id": HelperCommandTests.configured().id.uuidString])
        #expect(Self.outcome(f, "d1") == "completed")
        #expect(f.runtime.profiles.activeProfile.id == Self.second().id)
        await HelperCommandTests.run(f, "d2", "deleteProfile", ["id": Self.second().id.uuidString])
        #expect(Self.outcome(f, "d2") == "failed:lastProfile")
        #expect(f.runtime.profiles.profiles.map(\.id) == [Self.second().id])
    }

    @Test("Deleting an attached profile leaves its file untouched")
    func deleteKeepsAttachedFile() async throws {
        let f = try await HelperCommandTests.fixture(profileFiles: PortableProfileFiles(replace: { data, url in try data.write(to: url, options: .atomic) }))
        try await HelperCommandTests.save(f, Self.second())
        let file = f.root.appendingPathComponent("workstation.json")
        try ProfileDocumentCodec.write(try PortableProfileDocument(profile: HelperCommandTests.configured()), format: .json).write(to: file)
        let bytes = try Data(contentsOf: file)
        await HelperCommandTests.run(f, "i", "importProfile", ["path": file.path, "attach": "true"])
        guard case let .completed(imported) = f.outbox.result("i"), let id = imported["id"] else { Issue.record("import failed"); return }
        await HelperCommandTests.run(f, "d", "deleteProfile", ["id": id])
        #expect(Self.outcome(f, "d") == "completed")
        #expect(try Data(contentsOf: file) == bytes)
        #expect(f.runtime.profiles.attachments[try #require(UUID(uuidString: id))] == nil)
    }

    @Test("Duplicating a profile adds a copy with a new identity, as on macOS")
    func duplicate() async throws {
        let f = try await HelperCommandTests.fixture()
        try await HelperCommandTests.save(f, HelperCommandTests.configured())
        await HelperCommandTests.run(f, "c", "duplicateProfile", ["id": HelperCommandTests.configured().id.uuidString])
        guard case let .completed(value) = f.outbox.result("c") else { Issue.record("duplicate: \(Self.outcome(f, "c"))"); return }
        let copy = try #require(f.runtime.profiles.profiles.first { $0.id.uuidString == value["id"] })
        #expect(copy.id != HelperCommandTests.configured().id && copy.name == "Workstation Copy")
    }

    @Test("With no command running, cancelEditorRecovery clears a replacement waiting for review and leaves the desktop connected")
    func cancelPendingReplacement() async throws {
        let f = try await HelperCommandTests.fixture()
        try await HelperCommandTests.save(f, HelperCommandTests.configured(webForwards: true, editor: true))
        await HelperCommandTests.run(f, "c", "connect")
        await HelperCommandTests.run(f, "setup", "installEditorSetup", ["consent": "true"])
        await HelperCommandTests.run(f, "e1", "openEditor")
        #expect(Self.outcome(f, "e1") == "completed")
        f.ec2.resolveResult = .success(EC2Instance(id: "i-0fedcba9876543210", state: .running, privateIpAddress: "10.0.0.2"))
        await HelperCommandTests.run(f, "e2", "openEditor")
        #expect(f.runtime.editor.pendingReplacement != nil)
        await HelperCommandTests.run(f, "x", "cancelEditorRecovery")
        #expect(Self.outcome(f, "x") == "completed")
        #expect(f.runtime.editor.pendingReplacement == nil && !f.runtime.editor.isRecovering)
        #expect(f.runtime.connection.state == .connected)
    }

    @Test("With no command running, cancelEditorRecovery ends editor recovery started by the workflow")
    func cancelRunningRecovery() async throws {
        let f = try await HelperCommandTests.fixture()
        try await HelperCommandTests.save(f, HelperCommandTests.configured(editor: true))
        await HelperCommandTests.run(f, "setup", "installEditorSetup", ["consent": "true"])
        await HelperCommandTests.run(f, "e", "openEditor")
        #expect(Self.outcome(f, "e") == "completed")
        f.ec2.resolveDelay = .seconds(5)
        f.runtime.editor.reconnectExistingWorkspace()
        #expect(f.runtime.editor.isRecovering)
        await HelperCommandTests.run(f, "x", "cancelEditorRecovery")
        #expect(Self.outcome(f, "x") == "completed")
        #expect(!f.runtime.editor.isRecovering)
    }

    @Test("With no command running, cancelForwardingRecovery stops web forwards and leaves the desktop connected")
    func cancelForwarding() async throws {
        let f = try await HelperCommandTests.fixture()
        try await HelperCommandTests.save(f, HelperCommandTests.configured(webForwards: true))
        await HelperCommandTests.run(f, "c", "connect")
        await HelperCommandTests.run(f, "w", "startWebForwards")
        #expect(Self.outcome(f, "w") == "completed")
        await HelperCommandTests.run(f, "x", "cancelForwardingRecovery")
        #expect(Self.outcome(f, "x") == "completed")
        #expect(f.runtime.web.state == .off && f.runtime.web.pendingReplacement == nil)
        #expect(f.runtime.connection.state == .connected)
    }

    @Test("Until Zen arrives on Windows and Linux, Apply Browser Setup and Restore Browser Settings refuse naming the browser and change nothing")
    func zenActionsRefuse() async throws {
        let f = try await HelperCommandTests.fixture()
        var profile = HelperCommandTests.configured(webForwards: true)
        profile.webForwards?.browserMode = .existing
        try await HelperCommandTests.save(f, profile)
        let before = try FileManager.default.subpathsOfDirectory(atPath: f.root.path).sorted()
        for (id, command) in [("a", "applyBrowserSetup"), ("r", "restoreBrowserSettings")] {
            await HelperCommandTests.run(f, id, command)
            guard case let .failed(error) = f.outbox.result(id) else { Issue.record("\(command): \(Self.outcome(f, id))"); continue }
            #expect(error.code == "browserUnavailable", "\(command) failed with \(error.code)")
            #expect(error.message.contains("Zen"), "\(command): \(error.message)")
        }
        #expect(try FileManager.default.subpathsOfDirectory(atPath: f.root.path).sorted() == before)
        #expect(f.outbox.launches("browser").isEmpty)
    }

    // MARK: Waking from sleep (T70, AC-18)

    static func connects(_ f: Fixture) -> Int {
        f.runtime.log.entries.filter { $0.message.hasPrefix("Connecting to") }.count
    }

    static func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<400 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test("systemWake reconnects a connected desktop whose tunnel no longer answers, as macOS does on wake")
    func wakeReconnectsADeadTunnel() async throws {
        let f = try await HelperCommandTests.fixture()
        try await HelperCommandTests.save(f, HelperCommandTests.configured())
        await HelperCommandTests.run(f, "c", "connect")
        #expect(f.runtime.connection.state == .connected)
        f.readiness.answering = false
        await HelperCommandTests.run(f, "w", "systemWake")
        #expect(Self.outcome(f, "w") == "completed")
        f.readiness.answering = true
        await Self.waitUntil { Self.connects(f) == 2 && f.runtime.connection.state == .connected }
        #expect(Self.connects(f) == 2, "the desktop was not reconnected")
        #expect(f.runtime.connection.state == .connected)
        #expect(f.runtime.log.entries.contains { $0.message.contains("after wake from sleep") })
    }

    @Test("systemWake leaves a connected desktop whose tunnel still answers alone")
    func wakeLeavesAHealthyTunnel() async throws {
        let f = try await HelperCommandTests.fixture()
        try await HelperCommandTests.save(f, HelperCommandTests.configured())
        await HelperCommandTests.run(f, "c", "connect")
        await HelperCommandTests.run(f, "w", "systemWake")
        #expect(Self.outcome(f, "w") == "completed")
        try? await Task.sleep(for: .milliseconds(200))
        #expect(Self.connects(f) == 1)
        #expect(f.runtime.connection.state == .connected)
    }
}
