import Foundation
import Testing
@testable import SSMConnectKit

/// AC-25: an action whose required capability is missing is refused with a message naming it,
/// before any AWS call, process launch or configuration write, and never switches mode. The
/// Session Manager plugin is required for every action, OpenSSH and VS Code for the editor, and
/// a supported browser for managed browsing; DCV Viewer is not (the tunnel stays up with the
/// current warning).
@Suite("Capability preflight")
@MainActor
struct CapabilityPreflightTests {
    static func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    }

    // MARK: Desktop and tunnel-only

    @Test("A missing plugin refuses desktop and tunnel-only connections before any effect",
          arguments: [ConnectAction.dcvViewer, .tunnelOnly])
    func pluginForConnection(_ action: ConnectAction) async {
        let auth = MockAuthProvider()
        let ec2 = MockEC2Service()
        ec2.resolveResult = .success(.stub(state: .running))
        let ssm = MockSSMService()
        let tunnel = MockTunnelProvider()
        tunnel.availability = .pluginMissing(path: "/missing/session-manager-plugin")
        let secrets = MockSecretsService()
        let dcv = MockDCVLauncher()
        let instanceIds = MockInstanceIdStore()
        var profile = ConnectionProfile.example
        profile.connectAction = action
        let machine = ConnectionStateMachine(authProvider: auth, ec2: ec2, ssm: ssm, tunnel: tunnel, secrets: secrets,
            dcv: dcv, readiness: StubReadinessProbe(), tunnelListener: StubTunnelListenerProbe(), instanceIds: instanceIds,
            clipboard: ClipboardManager(pasteboard: FakePasteboard(), autoClearAfter: nil), notifier: MockNotifier(),
            profile: profile, reconnectBackoff: .zero, reconnectSleep: { _ in })
        machine.connect()
        await machine.awaitInFlightTask()
        #expect(machine.state == .error)
        #expect(machine.errorMessage == CapabilityError.missing(.sessionManagerPlugin).errorDescription)
        #expect(machine.errorMessage?.contains("Session Manager plugin") == true)
        #expect(auth.authenticateCallCount == 0 && ec2.resolveCount == 0 && ec2.startCount == 0)
        #expect(ssm.waitCount == 0 && ssm.startSessionCount == 0 && tunnel.startCount == 0)
        #expect(dcv.launchCount == 0 && instanceIds.lastInstanceId(forProfile: profile.id) == nil)
    }

    @Test("A missing DCV Viewer keeps the desktop tunnel up with the current warning")
    func viewerIsOptional() async {
        let ec2 = MockEC2Service()
        ec2.resolveResult = .success(.stub(state: .running))
        let dcv = MockDCVLauncher()
        dcv.installed = false
        let machine = ConnectionStateMachine(authProvider: MockAuthProvider(), ec2: ec2, ssm: MockSSMService(),
            tunnel: MockTunnelProvider(), secrets: MockSecretsService(), dcv: dcv, readiness: StubReadinessProbe(),
            tunnelListener: StubTunnelListenerProbe(), instanceIds: MockInstanceIdStore(),
            clipboard: ClipboardManager(pasteboard: FakePasteboard(), autoClearAfter: nil), notifier: MockNotifier(),
            profile: .example, reconnectBackoff: .zero, reconnectSleep: { _ in })
        machine.connect()
        await machine.awaitInFlightTask()
        #expect(machine.state == .connected)
        #expect(machine.warningMessage == DCVError.viewerNotInstalled.errorDescription)
        #expect(dcv.launchCount == 0)
    }

    // MARK: Web forwards and managed browsing

    func webMachine(recorder: WebEventRecorder, tunnel: FakeSSHTunnel, auth: MockAuthProvider, ssm: MockSSMService,
                    pacWrites: @escaping @Sendable () -> Void) -> WebForwardsStateMachine {
        var profile = ConnectionProfile.example
        profile.webForwards = .init(enabled: true, sshUser: "alice")
        ssm.onStartSSHSession = { recorder.append("session") }
        let ec2 = MockEC2Service()
        ec2.resolveResult = .success(.stub(state: .running))
        return WebForwardsStateMachine(profile: profile, auth: auth, ec2: ec2, ssm: ssm,
            instanceConnect: FakeInstanceConnect(recorder), keyGenerator: FakeSSHKeyGenerator(recorder: recorder),
            tunnel: tunnel, resolveUser: { _, _ in "mapped-user" },
            writePAC: { _, _ in pacWrites(); return URL(fileURLWithPath: "/tmp/test.pac") }, sleep: { _ in })
    }

    @Test("A missing plugin or OpenSSH refuses web forwards before any effect",
          arguments: [Capability.sessionManagerPlugin, .openSSH])
    func webForwards(_ missing: Capability) async {
        let recorder = WebEventRecorder()
        let tunnel = FakeSSHTunnel(recorder)
        tunnel.unavailable = [missing]
        let auth = MockAuthProvider()
        let ssm = MockSSMService()
        let writes = WebEventRecorder()
        let web = webMachine(recorder: recorder, tunnel: tunnel, auth: auth, ssm: ssm, pacWrites: { writes.append("pac") })
        web.connect()
        await Self.waitUntil { web.state == .error }
        #expect(web.state == .error)
        #expect(web.errorMessage == CapabilityError.missing(missing).errorDescription)
        #expect(auth.authenticateCallCount == 0 && ssm.startSSHSessionCount == 0)
        #expect(recorder.values.isEmpty && writes.values.isEmpty)
        web.stop()
    }

    @Test("A missing browser refuses managed browsing before connecting or launching")
    func managedBrowser() async {
        let recorder = WebEventRecorder()
        let auth = MockAuthProvider()
        let ssm = MockSSMService()
        let writes = WebEventRecorder()
        let web = webMachine(recorder: recorder, tunnel: FakeSSHTunnel(recorder), auth: auth, ssm: ssm,
                             pacWrites: { writes.append("pac") })
        let browser = FakeBrowserOpening()
        browser.preflightError = CapabilityError.missing(.browser)
        web.openBrowser(using: browser)
        await web.awaitBrowserOpened()
        #expect(web.browserErrorMessage == CapabilityError.missing(.browser).errorDescription)
        #expect(web.browserErrorMessage?.contains("browser") == true)
        #expect(auth.authenticateCallCount == 0 && ssm.startSSHSessionCount == 0)
        #expect(recorder.values.isEmpty && writes.values.isEmpty && browser.launchCount == 0)
        #expect(web.state == .off)
    }

    // MARK: Editor

    enum EditorGap: String, CaseIterable { case plugin, openSSH, visualStudioCode }

    @Test("A missing plugin, OpenSSH or VS Code refuses the editor before any effect", arguments: EditorGap.allCases)
    func editor(_ gap: EditorGap) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var profile = ConnectionProfile.example
        profile.remoteDevelopment = .init(enabled: true)
        profile.webForwards = .init(enabled: true, sshUser: "example")
        let auth = MockAuthProvider()
        let recorder = WebEventRecorder()
        var preflights = 0
        var launches = 0
        var leaseWrites = 0
        let machine = RemoteDevelopmentStateMachine(profile: profile, root: root.appendingPathComponent("owned"),
            configURL: root.appendingPathComponent("user/config"), auth: auth, ec2: MockEC2Service(), ssm: MockSSMService(),
            keyGenerator: FakeSSHKeyGenerator(recorder: recorder), helperPath: { "/usr/bin/true" },
            pluginPath: { gap == .plugin ? nil : "/usr/bin/true" },
            editorPath: { gap == .visualStudioCode ? nil : "/usr/bin/true" },
            editorPreflight: { _ in preflights += 1 }, ownerIdentity: { (12345, Date(), "test-owner") },
            writeLease: { _, _ in leaseWrites += 1 }, launchEditor: { _, _ in launches += 1 },
            sshAvailable: { gap != .openSSH })
        defer { machine.stop() }
        try machine.installSetup(consent: true)
        let setupFiles = try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted()
        machine.open()
        await machine.awaitOpening()
        switch gap {
        case .plugin: #expect(machine.errorMessage == CapabilityError.missing(.sessionManagerPlugin).errorDescription)
        case .openSSH: #expect(machine.errorMessage == CapabilityError.missing(.openSSH).errorDescription)
        case .visualStudioCode: #expect(machine.errorMessage == RemoteSSHError.unavailable.errorDescription)
        }
        #expect(auth.authenticateCallCount == 0 && preflights == 0 && launches == 0 && leaseWrites == 0)
        #expect(recorder.values.isEmpty && !machine.editorLaunched)
        #expect(try FileManager.default.subpathsOfDirectory(atPath: root.path).sorted() == setupFiles)
    }
}
