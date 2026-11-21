// Records the persisted state the current release writes (T11). This file compiles against the
// release's own sources, not this tree: copy it into Tests/SSMConnectKitTests/ of a checkout of
// the release tag and run
//   SSM_PERSISTED_FIXTURES=<dir> swift test --package-path SSMConnectKit --filter PersistedStateRecorder
// It writes `defaults.json` (every key the release's stores wrote, data as base64) and the
// browser profile tree under `browser/`, which PersistedStateCompatibilityTests read.
import Foundation
import Testing
@testable import SSMConnectKit

@Suite("Persisted state recorder") @MainActor struct PersistedStateRecorder {
    static let keys = ["ssmconnect.profiles.v1", "ssmconnect.activeProfileID.v1", "ssmconnect.settings.v1",
                       "ssmconnect.portableDocuments.v1", "ssmconnect.attachments.v1", "ssmconnect.editorRecovery.v1"]

    @Test func record() async throws {
        guard let out = ProcessInfo.processInfo.environment["SSM_PERSISTED_FIXTURES"] else { return }
        let directory = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var desktop = ConnectionProfile.example
        desktop.id = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        desktop.name = "Desktop"
        desktop.connectMode = .multiUser
        desktop.agentRemotePort = 8444
        var web = ConnectionProfile.example
        web.id = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        web.name = "Web and editor"
        web.connectAction = .tunnelOnly
        web.webForwards = .init(enabled: true, sshUser: "ec2-user", socksPort: 1081, proxySuffixes: [".internal.example.com"],
                                localForwards: [.init(name: "Grafana", localPort: 3000, remoteHost: "grafana.internal",
                                                      remotePort: 443, openPath: "/d")],
                                browser: .zen, browserMode: .separate)
        web.remoteDevelopment = .init(enabled: true, folder: "/home/ec2-user/src")

        let store = InMemoryKeyValueStore()
        let profiles = ProfileStore(store: store)
        profiles.addProfile(desktop)
        profiles.addProfile(web)
        profiles.setActiveProfile(web.id)
        profiles.settings = AppSettings(autoConnect: true, autoReconnect: false, clipboardAutoClearSeconds: 45)
        try EditorRecoveryStore(store: store).remember(EditorRecoveryIntent(profile: web, instanceID: "i-0123456789abcdef0",
                                                                            user: "ec2-user"))
        var dump: [String: [String: String]] = [:]
        for key in Self.keys {
            if let data = store.data(forKey: key) { dump[key] = ["data": data.base64EncodedString()] }
            else if let text = store.string(forKey: key) { dump[key] = ["string": text] }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(dump).write(to: directory.appendingPathComponent("defaults.json"))

        // The browser records: a Separate Browser launch writes the routing record in its profile.
        let root = directory.appendingPathComponent("browser", isDirectory: true)
        try? FileManager.default.removeItem(at: root)
        try BrowserPrivateFiles.directory(root)
        let descriptor = BrowserDescriptor(choice: .zen, bundleID: "app.zen-browser.zen",
                                           applicationURL: URL(fileURLWithPath: "/tmp/TestBrowser.app"),
                                           executableURL: URL(fileURLWithPath: "/tmp/TestBrowser.app/Contents/MacOS/browser"),
                                           version: "1.23.1b")
        let browser = BrowserBootstrap(root: root, discover: { [descriptor] }, isRunning: { _ in false },
                                       launch: { _, _ in })
        try await browser.open(profile: web)
    }
}
