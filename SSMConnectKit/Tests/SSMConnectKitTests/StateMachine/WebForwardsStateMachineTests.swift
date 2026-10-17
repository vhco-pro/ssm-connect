import Foundation
import Testing
@testable import SSMConnectKit

private actor RecoveryWaitRecorder {
    private var values: [Duration] = []
    func record(_ delay: Duration) { values.append(delay) }
    func snapshot() -> [Duration] { values }
}

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
    var error: Error?
    private(set) var publicKeys: [String] = []
    private(set) var user: String?
    init(_ recorder: WebEventRecorder) { self.recorder = recorder }
    func sendPublicKey(instanceId: String, user: String, publicKey: String,
                       region: String, credentials: AWSCredentials) async throws {
        recorder.append("push")
        if let error { throw error }
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
        let ec2 = MockEC2Service()
        ec2.resolveResult = .success(.stub(state: .running))
        return WebForwardsStateMachine(profile: profile, auth: MockAuthProvider(), ec2: ec2,
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

    private func recoveryMachine(ec2: LeaseEC2, tunnel: FakeSSHTunnel, connector: FakeInstanceConnect,
                                 ssm: MockSSMService = MockSSMService(), budget: Duration = .seconds(30 * 60),
                                 sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }) -> WebForwardsStateMachine {
        var profile = ConnectionProfile.example
        profile.webForwards = .init(enabled: true, sshUser: "alice")
        return WebForwardsStateMachine(profile: profile, auth: MockAuthProvider(), ec2: ec2,
            ssm: ssm, instanceConnect: connector, keyGenerator: FakeSSHKeyGenerator(recorder: connector.recorder),
            tunnel: tunnel, writePAC: { _, _ in URL(fileURLWithPath: "/tmp/synthetic-recovery.pac") },
            sleep: sleep, reconnectBackoff: .zero, recoveryBudget: budget)
    }

    @Test("REBUILD-04: Four expected absent-target misses do not exhaust the old three-attempt transport limit")
    func longReadinessWaitIsNotThreeBlindRetries() async throws {
        let recorder = WebEventRecorder()
        let ec2 = LeaseEC2()
        let tunnel = FakeSSHTunnel(recorder)
        let connector = FakeInstanceConnect(recorder)
        let waits = RecoveryWaitRecorder()
        let web = recoveryMachine(ec2: ec2, tunnel: tunnel, connector: connector, sleep: { await waits.record($0) })
        defer { web.stop() }
        web.connect()
        try await wait { web.state == .on }
        let originalProfile = web.profile
        ec2.onResolve = {
            if ec2.resolves <= 5 { throw EC2Error.noMatchingInstance(tagKey: "Name", tagValue: "synthetic") }
        }
        tunnel.handles[0].simulateDrop()
        try await wait { tunnel.handles.count == 2 && web.state == .on }
        #expect(ec2.resolves == 6 && ec2.starts == 0)
        #expect(await waits.snapshot() == [.zero, .seconds(15), .seconds(15), .seconds(15), .seconds(15)])
        #expect(web.profile == originalProfile)
        #expect(connector.publicKeys.count == 2 && connector.publicKeys[0] != connector.publicKeys[1])
        web.stop()
        await web.awaitStopped()
    }

    @Test("REBUILD-06: Native forwarding asks before a replacement and refuses a different approved candidate",
          arguments: [false, true])
    func forwardingReplacementMustBeReviewed(changeAgain: Bool) async throws {
        let recorder = WebEventRecorder()
        let ec2 = LeaseEC2()
        let tunnel = FakeSSHTunnel(recorder)
        let connector = FakeInstanceConnect(recorder)
        let web = recoveryMachine(ec2: ec2, tunnel: tunnel, connector: connector)
        defer { web.stop() }
        web.connect()
        try await wait { web.state == .on }
        let originalPAC = web.pacURL
        ec2.instance = .stub(id: "i-11111111111111111", state: .running)
        tunnel.handles[0].simulateDrop()
        try await wait { web.pendingReplacement != nil && web.state == .error }
        await web.awaitStopped()
        let candidate = try #require(web.pendingReplacement)
        #expect(connector.publicKeys.count == 1)
        if changeAgain { ec2.instance = .stub(id: "i-22222222222222222", state: .running) }
        web.approveReplacement(candidate.id)
        try await wait { web.state == .on || web.state == .error }
        if changeAgain {
            #expect(web.pendingReplacement?.instanceID == "i-22222222222222222")
            #expect(connector.publicKeys.count == 1)
        } else {
            #expect(web.state == .on && tunnel.handles.count == 2)
            #expect(connector.publicKeys.count == 2 && tunnel.keyPaths[0] != tunnel.keyPaths[1])
            #expect(web.pacURL == originalPAC && web.pendingReplacement == nil)
        }
        #expect(ec2.starts == 0)
        web.stop()
        await web.awaitStopped()
    }

    @Test("REBUILD-09: Native readiness recovery is bounded and never starts a stopped workstation",
          arguments: [false, true])
    func forwardingWaitBudgetAndCancellation(cancel: Bool) async throws {
        let recorder = WebEventRecorder()
        let ec2 = LeaseEC2()
        let tunnel = FakeSSHTunnel(recorder)
        let web = recoveryMachine(ec2: ec2, tunnel: tunnel, connector: FakeInstanceConnect(recorder),
                                  budget: .milliseconds(150), sleep: { try await Task.sleep(for: $0) })
        defer { web.stop() }
        web.connect()
        try await wait { web.state == .on }
        ec2.instance = .stub(state: .stopped)
        let started = ContinuousClock.now
        tunnel.handles[0].simulateDrop()
        try await wait { web.recoveryMessage != nil }
        if cancel { web.stop() }
        await web.awaitStopped()
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(web.state == (cancel ? .off : .error))
        if !cancel {
            #expect(web.errorMessage == StageTimeoutError(stage: "Native forwarding recovery").localizedDescription)
        }
        #expect(tunnel.handles.count == 1 && ec2.starts == 0)
    }

    @Test("REBUILD-06: Native ambiguous targets fail immediately instead of consuming a readiness budget")
    func forwardingAmbiguityIsTerminal() async throws {
        let recorder = WebEventRecorder()
        let ec2 = LeaseEC2()
        let tunnel = FakeSSHTunnel(recorder)
        let web = recoveryMachine(ec2: ec2, tunnel: tunnel, connector: FakeInstanceConnect(recorder))
        defer { web.stop() }
        web.connect()
        try await wait { web.state == .on }
        ec2.onResolve = { throw EC2Error.multipleMatchingInstances(tagKey: "Name", tagValue: "synthetic", count: 2) }
        tunnel.handles[0].simulateDrop()
        await web.awaitStopped()
        #expect(web.state == .error && ec2.resolves == 2)
        #expect(web.recoveryMessage == nil && tunnel.handles.count == 1)
    }

    @Test("Explicit Turn On preserves cold-start behavior; automatic recovery is the no-start path")
    func explicitTurnOnCanStillStartTheSelectedWorkstation() async throws {
        let recorder = WebEventRecorder()
        let ec2 = MockEC2Service()
        let tunnel = FakeSSHTunnel(recorder)
        var profile = ConnectionProfile.example
        profile.webForwards = .init(enabled: true, sshUser: "alice")
        let web = WebForwardsStateMachine(profile: profile, auth: MockAuthProvider(), ec2: ec2,
            ssm: MockSSMService(), instanceConnect: FakeInstanceConnect(recorder),
            keyGenerator: FakeSSHKeyGenerator(recorder: recorder), tunnel: tunnel,
            writePAC: { _, _ in URL(fileURLWithPath: "/tmp/synthetic-recovery.pac") })
        defer { web.stop() }
        for expectedStarts in 1...2 {
            web.connect()
            try await wait { web.state == .on }
            #expect(ec2.startCount == expectedStarts)
            web.stop()
            await web.awaitStopped()
        }
    }

    @Test("REBUILD-06: SDK permission denial terminates forwarding recovery without transport retries",
          arguments: ["ec2", "ssm", "eic"])
    func forwardingSDKDenialDoesNotRetry(stage: String) async throws {
        let recorder = WebEventRecorder()
        let ec2 = LeaseEC2()
        let ssm = MockSSMService()
        let tunnel = FakeSSHTunnel(recorder)
        let connector = FakeInstanceConnect(recorder)
        let web = recoveryMachine(ec2: ec2, tunnel: tunnel, connector: connector, ssm: ssm)
        defer { web.stop() }
        web.connect()
        try await wait { web.state == .on }
        let denied = unmodeledAWSServiceError(typeName: stage == "ec2" ? "UnauthorizedOperation" : "AccessDeniedException",
                                            message: "synthetic permission denial", statusCode: .forbidden)
        if stage == "ec2" { ec2.onResolve = { throw denied } }
        if stage == "ssm" { ssm.waitError = denied }
        if stage == "eic" { connector.error = denied }
        tunnel.handles[0].simulateDrop()
        await web.awaitStopped()
        #expect(web.state == .error && web.errorMessage != nil)
        #expect(ec2.resolves == 2)
        #expect(tunnel.handles.count == 1 && connector.publicKeys.count == 1)
    }

    @Test("REBUILD-09: Ordinary forwarding cold starts retain their configured SSM readiness window")
    func explicitForwardingColdStartWaitsPastRecoverySlice() async throws {
        let recorder = WebEventRecorder()
        let ec2 = MockEC2Service()
        let ssm = MockSSMService()
        let tunnel = FakeSSHTunnel(recorder)
        ssm.onWaitForSSMOnline = { timeout in
            #expect(timeout == ConnectionTimeouts.default.ssm)
            try await Task.sleep(for: .seconds(35))
        }
        var profile = ConnectionProfile.example
        profile.webForwards = .init(enabled: true, sshUser: "alice")
        let web = WebForwardsStateMachine(profile: profile, auth: MockAuthProvider(), ec2: ec2,
            ssm: ssm, instanceConnect: FakeInstanceConnect(recorder),
            keyGenerator: FakeSSHKeyGenerator(recorder: recorder), tunnel: tunnel,
            writePAC: { _, _ in URL(fileURLWithPath: "/tmp/synthetic-recovery.pac") })
        defer { web.stop() }
        let started = ContinuousClock.now
        web.connect()
        let deadline = started.advanced(by: .seconds(50))
        while web.state == .starting, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(web.state == .on && web.errorMessage == nil)
        #expect(ContinuousClock.now - started >= .seconds(35))
        #expect(ec2.startCount == 1)
        web.stop()
        await web.awaitStopped()
    }
}