import Foundation
import Testing
@testable import SSMConnectKit

final class WebEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    func append(_ event: String) { lock.lock(); defer { lock.unlock() }; events.append(event) }
    var values: [String] { lock.lock(); defer { lock.unlock() }; return events }
}

struct FakeSSHKeyGenerator: SSHKeyGenerating {
    let recorder: WebEventRecorder
    func generate() async throws -> SSHKeyMaterial {
        recorder.append("key")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let publicKey = "ssh-ed25519 \(UUID().uuidString)"
        try BrowserPrivateFiles.write(Data("fixture-private-key".utf8), to: directory.appendingPathComponent("key"))
        try BrowserPrivateFiles.write(Data(publicKey.utf8), to: directory.appendingPathComponent("key.pub"))
        return SSHKeyMaterial(directory: directory, publicKey: publicKey)
    }
}

final class FakeInstanceConnect: InstanceConnectProviding, @unchecked Sendable {
    let recorder: WebEventRecorder
    var fail = false
    private(set) var publicKeys: [String] = []
    private(set) var user: String?
    init(_ recorder: WebEventRecorder) { self.recorder = recorder }
    func sendPublicKey(instanceId: String, user: String, publicKey: String,
                       region: String, credentials: AWSCredentials) async throws {
        recorder.append("push")
        if fail { throw WebForwardsError.keyPushFailed }
        publicKeys.append(publicKey)
        self.user = user
    }
}

final class FakeSSHTunnel: SSHTunnelProviding, @unchecked Sendable {
    let recorder: WebEventRecorder
    private(set) var handles: [MockTunnelHandle] = []
    private(set) var keyPaths: [String] = []
    init(_ recorder: WebEventRecorder) { self.recorder = recorder }
    func start(session: SSMSessionResponse, region: String, instanceId: String, user: String,
               keyPath: String, configuration: WebForwardsConfiguration) async throws -> TunnelHandle {
        recorder.append("ssh")
        let handle = MockTunnelHandle()
        handles.append(handle)
        keyPaths.append(keyPath)
        return handle
    }
}

@MainActor final class FakeBrowserOpening: BrowserOpening {
    var launchCount = 0
    var fail = false
    func preflight(profile: ConnectionProfile) throws {}
    func open(profile: ConnectionProfile) async throws {
        launchCount += 1
        if fail { throw BrowserBootstrapError.launchFailed }
    }
    func restore(profile: ConnectionProfile) throws {}
}

@Suite("Web forwards supervision")
@MainActor
struct WebForwardsStateMachineTests {
    @Test("WF-6 and WF-13: quitting runs both independent shutdown handlers")
    func multipleShutdownHandlers() {
        let shutdown = AppQuitHandler()
        var dcvStopped = false
        var webStopped = false
        shutdown.register { dcvStopped = true }
        shutdown.register { webStopped = true }
        shutdown.runShutdown()
        #expect(dcvStopped)
        #expect(webStopped)
    }

    func machine(recorder: WebEventRecorder, connector: FakeInstanceConnect, tunnel: FakeSSHTunnel,
                 ssm: MockSSMService, mappedUser: Bool = false) -> WebForwardsStateMachine {
        var profile = ConnectionProfile.example
        profile.webForwards = .init(enabled: true, sshUser: mappedUser ? nil : "alice")
        ssm.onStartSSHSession = { recorder.append("session") }
        return WebForwardsStateMachine(profile: profile, auth: MockAuthProvider(), ec2: MockEC2Service(),
            ssm: ssm, instanceConnect: connector, keyGenerator: FakeSSHKeyGenerator(recorder: recorder),
            tunnel: tunnel, resolveUser: { _, _ in "mapped-user" },
            writePAC: { _, _ in URL(fileURLWithPath: "/tmp/test.pac") }, sleep: { _ in })
    }

    func wait(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
        #expect(condition())
        try #require(condition())
    }

    @Test("AC-B1 and AC-B13: repeated Open waits for one SSH connection; browser failure keeps SSH")
    func browserOrchestration() async throws {
        let recorder = WebEventRecorder()
        let connector = FakeInstanceConnect(recorder)
        let tunnel = FakeSSHTunnel(recorder)
        let ssm = MockSSMService()
        let web = machine(recorder: recorder, connector: connector, tunnel: tunnel, ssm: ssm)
        let browser = FakeBrowserOpening()
        web.openBrowser(using: browser)
        web.openBrowser(using: browser)
        await web.awaitBrowserOpened()
        #expect(web.state == .on)
        #expect(ssm.startSSHSessionCount == 1)
        #expect(browser.launchCount == 1)
        #expect(ssm.startSessionCount == 0)
        browser.fail = true
        web.openBrowser(using: browser)
        await web.awaitBrowserOpened()
        #expect(web.browserErrorMessage != nil)
        #expect(web.isActive)
        #expect(web.state == .on)
        web.stop()
        await web.awaitStopped()
    }

    @Test("AC-B7: saved routing stays pending until Apply; staging does not stop SSH")
    func pendingRouting() async throws {
        let recorder = WebEventRecorder()
        let tunnel = FakeSSHTunnel(recorder)
        let web = machine(recorder: recorder, connector: FakeInstanceConnect(recorder), tunnel: tunnel, ssm: MockSSMService())
        web.connect()
        try await wait { web.state == .on }
        let applied = web.profile
        var saved = applied
        saved.webForwards?.socksPort = 1081
        web.apply(profile: saved, settings: .default)
        #expect(web.pendingProfile == saved)
        #expect(web.profile == applied)
        #expect(web.isActive)
        let browser = FakeBrowserOpening()
        web.openBrowser(using: browser)
        await web.awaitBrowserOpened()
        #expect(browser.launchCount == 0)
        #expect(web.isActive)
        await web.applyPendingConfiguration()
        try await wait { web.state == .on }
        #expect(web.profile == saved)
        #expect(tunnel.handles.count == 2)
        web.stop()
        await web.awaitStopped()
    }

    @Test("AC-3: generate key, SendSSHPublicKey, StartSession, spawn SSH in that order")
    func connectOrder() async throws {
        let recorder = WebEventRecorder()
        let connector = FakeInstanceConnect(recorder)
        let tunnel = FakeSSHTunnel(recorder)
        let ssm = MockSSMService()
        let machine = machine(recorder: recorder, connector: connector, tunnel: tunnel, ssm: ssm, mappedUser: true)
        machine.connect()
        try await wait { machine.state == .on || machine.state == .error }
        #expect(machine.state == .on)
        #expect(recorder.values == ["key", "push", "session", "ssh"])
        #expect(connector.user == "mapped-user")
        #expect(ssm.startSessionCount == 0)
        machine.stop()
        await machine.awaitStopped()
        #expect(tunnel.handles.first?.isActive == false)
        #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: tunnel.keyPaths[0]).deletingLastPathComponent().path))
    }

    @Test("AC-3: key authorization failure names SendSSHPublicKey and does not start a session")
    func permissionError() async throws {
        let recorder = WebEventRecorder()
        let connector = FakeInstanceConnect(recorder)
        connector.fail = true
        let tunnel = FakeSSHTunnel(recorder)
        let ssm = MockSSMService()
        let machine = machine(recorder: recorder, connector: connector, tunnel: tunnel, ssm: ssm)
        machine.connect()
        await machine.awaitStopped()
        #expect(machine.state == .error)
        #expect(machine.errorMessage?.contains("ec2-instance-connect:SendSSHPublicKey") == true)
        #expect(ssm.startSSHSessionCount == 0)
        #expect(tunnel.handles.isEmpty)
    }

    @Test("AC-4: web forwards do not launch DCV; disconnecting DCV leaves SSH active")
    func independentDCV() async throws {
        let recorder = WebEventRecorder()
        let connector = FakeInstanceConnect(recorder)
        let tunnel = FakeSSHTunnel(recorder)
        let ssm = MockSSMService()
        let web = machine(recorder: recorder, connector: connector, tunnel: tunnel, ssm: ssm)
        let viewer = MockDCVLauncher()
        let desktop = ConnectionStateMachine(authProvider: MockAuthProvider(), ec2: MockEC2Service(),
            ssm: MockSSMService(), tunnel: RecordingTunnelProvider(handles: [MockTunnelHandle()]),
            secrets: MockSecretsService(), dcv: viewer, readiness: StubReadinessProbe(),
            tunnelListener: StubTunnelListenerProbe(), instanceIds: MockInstanceIdStore(),
            clipboard: ClipboardManager(pasteboard: FakePasteboard(), autoClearAfter: nil),
            notifier: MockNotifier(), profile: .example)
        web.connect()
        try await wait { web.state == .on }
        #expect(viewer.launchCount == 0)
        #expect(desktop.state == .disconnected)
        desktop.connect()
        await desktop.awaitInFlightTask()
        #expect(desktop.state == .connected)
        #expect(viewer.launchCount == 1)
        desktop.disconnect()
        await desktop.awaitInFlightTask()
        #expect(desktop.state == .disconnected)
        #expect(web.isActive)
        #expect(web.state == .on)
        web.stop()
        await web.awaitStopped()
    }

    @Test("AC-5: unexpected SSH exit pushes a fresh key; user stop never reconnects")
    func reconnect() async throws {
        let recorder = WebEventRecorder()
        let connector = FakeInstanceConnect(recorder)
        let tunnel = FakeSSHTunnel(recorder)
        let ssm = MockSSMService()
        let machine = machine(recorder: recorder, connector: connector, tunnel: tunnel, ssm: ssm)
        machine.connect()
        try await wait { machine.state == .on }
        tunnel.handles[0].simulateDrop()
        try await wait { tunnel.handles.count == 2 && machine.state == .on }
        #expect(connector.publicKeys.count == 2)
        #expect(connector.publicKeys[0] != connector.publicKeys[1])
        machine.stop()
        await machine.awaitStopped()
        #expect(machine.state == .off)
        #expect(tunnel.handles.count == 2)
        #expect(tunnel.handles[1].terminateCount == 1)
    }
}