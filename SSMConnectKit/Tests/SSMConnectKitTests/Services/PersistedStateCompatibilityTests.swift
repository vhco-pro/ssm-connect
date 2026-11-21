import Foundation
import Testing
@testable import SSMConnectKit

/// State written by the current release (v0.7.1, recorded with Tools/PersistedStateRecorder) is
/// read by the refactored code and written back under the same keys, in the same versions and
/// with the same content (T11, AC-26, AC-14).
@Suite("Persisted state compatibility") @MainActor
struct PersistedStateCompatibilityTests {
    static let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/persisted-state")
    static let desktopID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    static let webID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    /// The release's key-value store contents.
    static func releaseStore() throws -> (InMemoryKeyValueStore, [String: Any]) {
        let dump = try JSONDecoder().decode([String: [String: String]].self,
                                            from: Data(contentsOf: fixtures.appendingPathComponent("defaults.json")))
        var values: [String: Any] = [:]
        for (key, entry) in dump {
            if let data = entry["data"].flatMap({ Data(base64Encoded: $0) }) { values[key] = data }
            else if let text = entry["string"] { values[key] = text }
        }
        return (InMemoryKeyValueStore(storage: values), values)
    }

    static func json(_ value: Any?) -> NSObject? {
        guard let data = value as? Data else { return value as? NSObject }
        return try? JSONSerialization.jsonObject(with: data) as? NSObject
    }

    @Test("Every key the release wrote is present")
    func releaseKeys() throws {
        let (_, values) = try Self.releaseStore()
        #expect(Set(values.keys) == ["ssmconnect.profiles.v1", "ssmconnect.activeProfileID.v1", "ssmconnect.settings.v1",
                                     "ssmconnect.portableDocuments.v1", "ssmconnect.attachments.v1", "ssmconnect.editorRecovery.v1"])
    }

    @Test("ProfileStore reads the release's profiles, active profile and settings")
    func profileStoreReads() throws {
        let (store, _) = try Self.releaseStore()
        let profiles = ProfileStore(store: store)
        #expect(profiles.profiles.map(\.id) == [Self.desktopID, Self.webID])
        #expect(profiles.activeProfileID == Self.webID)
        #expect(profiles.settings == AppSettings(autoConnect: true, autoReconnect: false, clipboardAutoClearSeconds: 45))
        #expect(profiles.operationError == nil)
        let web = try #require(profiles.profiles.last)
        #expect(web.webForwards?.localForwards.first?.remoteHost == "grafana.internal")
        #expect(web.webForwards?.browser == .zen && web.webForwards?.browserMode == .separate)
        #expect(web.remoteDevelopment == RemoteDevelopmentConfiguration(enabled: true, folder: "/home/ec2-user/src"))
        #expect(profiles.profiles.first?.connectMode == .multiUser)
    }

    @Test("ProfileStore writes the release's keys back with the same content")
    func profileStoreWritesBack() throws {
        let (store, release) = try Self.releaseStore()
        let profiles = ProfileStore(store: store)
        profiles.settings = profiles.settings // didSet saves every key
        for key in ["ssmconnect.profiles.v1", "ssmconnect.settings.v1", "ssmconnect.portableDocuments.v1", "ssmconnect.attachments.v1"] {
            #expect(Self.json(store.data(forKey: key)) == Self.json(release[key]), "\(key)")
        }
        #expect(store.string(forKey: "ssmconnect.activeProfileID.v1") == release["ssmconnect.activeProfileID.v1"] as? String)
    }

    @Test("EditorRecoveryStore reads the release's intent and writes it back in version 1")
    func editorRecovery() throws {
        let (store, release) = try Self.releaseStore()
        let recovery = EditorRecoveryStore(store: store)
        let intent = try #require(try recovery.intent(for: Self.webID))
        #expect(intent.instanceID == "i-0123456789abcdef0" && intent.user == "ec2-user" && intent.profile.id == Self.webID)
        try recovery.remember(intent)
        let written = Self.json(store.data(forKey: "ssmconnect.editorRecovery.v1"))
        #expect(written == Self.json(release["ssmconnect.editorRecovery.v1"]))
        #expect((written as? NSDictionary)?["version"] as? Int == 1)
    }

    @Test("BrowserBootstrap writes the release's routing record and preferences for the same profile")
    func browserRecords() async throws {
        let releaseRoot = "/tmp/ssm-v071/fixtures/browser"
        let releaseProfile = Self.fixtures.appendingPathComponent("browser/\(Self.webID.uuidString)/zen")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try BrowserPrivateFiles.directory(root)
        let (store, _) = try Self.releaseStore()
        let web = try #require(ProfileStore(store: store).profiles.last)
        let descriptor = BrowserDescriptor(choice: .zen, bundleID: "app.zen-browser.zen",
                                           applicationURL: URL(fileURLWithPath: "/tmp/TestBrowser.app"),
                                           executableURL: URL(fileURLWithPath: "/tmp/TestBrowser.app/Contents/MacOS/browser"),
                                           version: "1.23.1b")
        let browser = BrowserBootstrap(root: root, discover: { [descriptor] }, isRunning: { _ in false }, launch: { _, _ in })
        try await browser.open(profile: web)
        let profile = root.appendingPathComponent("\(Self.webID.uuidString)/zen")
        for name in ["ssm-connect-routing.json", "user.js"] {
            let release = try String(contentsOf: releaseProfile.appendingPathComponent(name), encoding: .utf8)
                .replacingOccurrences(of: releaseRoot.replacingOccurrences(of: "/", with: "\\/"), with: "<root>")
                .replacingOccurrences(of: releaseRoot, with: "<root>")
            let current = try String(contentsOf: profile.appendingPathComponent(name), encoding: .utf8)
                .replacingOccurrences(of: root.path.replacingOccurrences(of: "/", with: "\\/"), with: "<root>")
                .replacingOccurrences(of: root.path, with: "<root>")
            if name.hasSuffix(".json") {
                #expect(Self.json(Data(current.utf8)) == Self.json(Data(release.utf8)), "\(name)")
            } else {
                #expect(current == release, "\(name)")
            }
        }
        // The release's routing record decodes and re-encodes to the same content.
        let recorded = try Data(contentsOf: releaseProfile.appendingPathComponent("ssm-connect-routing.json"))
        let routing = try JSONDecoder().decode(BrowserRouting.self, from: recorded)
        #expect(Self.json(try JSONEncoder().encode(routing)) == Self.json(recorded))
    }
}
