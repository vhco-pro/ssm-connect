import Foundation
import Testing
@testable import SSMConnectKit

@Suite("ConnectionStateMachine")
@MainActor
struct ConnectionStateMachineTests {

    // MARK: Builders

    /// Build a state machine wired entirely from mocks. Reconnect backoff is a no-op so
    /// auto-reconnect tests don't wait; stage timeouts keep their real (long) budgets.
    private func makeMachine(
        auth: MockAuthProvider = MockAuthProvider(),
        ec2: EC2Providing = MockEC2Service(),
        ssm: MockSSMService = MockSSMService(),
        tunnel: TunnelProvider = MockTunnelProvider(),
        secrets: MockSecretsService = MockSecretsService(),
        dcv: MockDCVLauncher = MockDCVLauncher(),
        readiness: WorkstationReadinessProbing = StubReadinessProbe(),
        tunnelListener: TunnelListenerProbing = StubTunnelListenerProbe(),
        instanceIds: InstanceIdPersisting = MockInstanceIdStore(),
        clipboard: ClipboardManager = ClipboardManager(pasteboard: FakePasteboard(), autoClearAfter: nil),
        notifier: Notifying = MockNotifier(),
        profile: ConnectionProfile = .example,
        settings: AppSettings = .default,
        isExpired: @escaping @Sendable (Error) -> Bool = ConnectionStateMachine.defaultExpiredCredentialsCheck
    ) -> ConnectionStateMachine {
        ConnectionStateMachine(
            authProvider: auth,
            ec2: ec2,
            ssm: ssm,
            tunnel: tunnel,
            secrets: secrets,
            dcv: dcv,
            readiness: readiness,
            tunnelListener: tunnelListener,
            instanceIds: instanceIds,
            clipboard: clipboard,
            notifier: notifier,
            profile: profile,
            settings: settings,
            isExpiredCredentials: isExpired,
            maxReconnectAttempts: 3,
            reconnectBackoff: .zero,
            reconnectSleep: { _ in }
        )
    }

    private func runningEC2(id: String = "i-running") -> MockEC2Service {
        let ec2 = MockEC2Service()
        ec2.resolveResult = .success(.stub(id: id, state: .running))
        return ec2
    }

    /// Spin (cooperatively) until `condition` is true or the deadline elapses.
    private func waitUntil(_ timeout: Duration = .seconds(2), _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition(), ContinuousClock.now < deadline {
            await Task.yield()
        }
    }

    // MARK: Happy path

    @Test("warm start: a running instance connects, fetches the secret, copies it, launches DCV")
    func warmStartHappyPath() async {
        let ec2 = runningEC2(id: "i-warm")
        let secrets = MockSecretsService(); secrets.result = .success("s3cr3t")
        let dcv = MockDCVLauncher()
        let pb = FakePasteboard()
        let machine = makeMachine(
            ec2: ec2,
            secrets: secrets,
            dcv: dcv,
            clipboard: ClipboardManager(pasteboard: pb, autoClearAfter: nil)
        )

        machine.connect()
        await machine.awaitInFlightTask()

        #expect(machine.state == .connected)
        #expect(machine.instanceId == "i-warm")
        #expect(machine.tunnelPID == 4242)
        #expect(machine.localPort == ConnectionProfile.template.localPort)
        #expect(machine.password == "s3cr3t")
        #expect(pb.currentString() == "s3cr3t")
        #expect(dcv.launchCount == 1)
        #expect(dcv.lastConnectionFile?.password == "s3cr3t")
        #expect(ec2.startCount == 0)
        #expect(ec2.pollCount == 0)
        #expect(machine.warningMessage == nil)
    }

    // MARK: Auto-start (F-07)

    @Test("cold start: a stopped instance is auto-started before tunneling")
    func coldStartAutoStarts() async {
        let ec2 = MockEC2Service()
        ec2.resolveResult = .success(.stub(id: "i-cold", state: .stopped))
        ec2.pollResult = .success(.stub(id: "i-cold", state: .running))
        let machine = makeMachine(ec2: ec2)

        machine.connect()
        await machine.awaitInFlightTask()

        #expect(machine.state == .connected)
        #expect(ec2.startCount == 1)
        #expect(ec2.lastStartedInstanceId == "i-cold")
        #expect(ec2.pollCount == 1)
    }

    @Test("auto-start is skipped when the instance is already running")
    func runningInstanceSkipsStart() async {
        let ec2 = runningEC2()
        let machine = makeMachine(ec2: ec2)

        machine.connect()
        await machine.awaitInFlightTask()

        #expect(ec2.startCount == 0)
        #expect(ec2.pollCount == 0)
    }

    // MARK: Resolve errors

    @Test("a terminated instance ends in error without attempting a start")
    func terminatedInstanceErrors() async {
        let ec2 = MockEC2Service()
        ec2.resolveResult = .success(.stub(state: .terminated))
        let machine = makeMachine(ec2: ec2)

        machine.connect()
        await machine.awaitInFlightTask()

        #expect(machine.state == .error)
        #expect(ec2.startCount == 0)
        #expect(machine.errorMessage != nil)
    }

    @Test("a resolve failure surfaces an error state")
    func resolveFailureErrors() async {
        let ec2 = MockEC2Service()
        ec2.resolveResult = .failure(EC2Error.noMatchingInstance(tagKey: "Name", tagValue: "x"))
        let machine = makeMachine(ec2: ec2)

        machine.connect()
        await machine.awaitInFlightTask()

        #expect(machine.state == .error)
        #expect(machine.errorMessage != nil)
    }

    // MARK: DCV is best-effort (F-16)

    @Test("a missing DCV Viewer keeps the tunnel up with a warning")
    func missingDCVKeepsTunnel() async {
        let dcv = MockDCVLauncher(); dcv.installed = false
        let machine = makeMachine(ec2: runningEC2(), dcv: dcv)

        machine.connect()
        await machine.awaitInFlightTask()

        #expect(machine.state == .connected)
        #expect(dcv.launchCount == 0)
        #expect(machine.warningMessage != nil)
    }

    @Test("a DCV launch failure keeps the tunnel up with a warning")
    func dcvLaunchFailureKeepsTunnel() async {
        let dcv = MockDCVLauncher(); dcv.launchError = DCVError.launchFailed(reason: "boom")
        let machine = makeMachine(ec2: runningEC2(), dcv: dcv)

        machine.connect()
        await machine.awaitInFlightTask()

        #expect(machine.state == .connected)
        #expect(machine.warningMessage != nil)
    }

    // MARK: Readiness gating + reconnect safety (#9, RVL-1..RVL-6)

    @Test("AC-1: an unready DCV server fails retryably and never launches the viewer")
    func unreadyServerFailsWithoutLaunch() async {
        let probe = StubReadinessProbe(ready: false) // never answers within budget
        let tunnel = RecordingTunnelProvider(handles: [])
        let dcv = MockDCVLauncher()
        let machine = makeMachine(ec2: runningEC2(), tunnel: tunnel, dcv: dcv, readiness: probe)

        machine.connect()
        await machine.awaitInFlightTask()

        #expect(machine.state == .error)
        #expect(dcv.launchCount == 0) // RVL-1: never launched into a dead endpoint
        #expect(machine.errorMessage?.contains("DCV server didn't become ready") == true)
        #expect(tunnel.startCount == 3) // RVL-5: 1 + 2 retries
    }

    @Test("AC-2: when the endpoint never answers AND nothing is listening, the error is tunnelNotEstablished")
    func tunnelNotListeningFailsDistinctly() async {
        // Readiness fails (server never answers) and the TCP classifier finds nothing listening →
        // the distinct tunnelNotEstablished message (#9, RVL-3). The TCP probe runs only on the
        // failure path, so it can never false-block a healthy tunnel.
        let listener = StubTunnelListenerProbe(listening: false)
        let probe = StubReadinessProbe(ready: false)
        let dcv = MockDCVLauncher()
        let machine = makeMachine(ec2: runningEC2(), dcv: dcv, readiness: probe, tunnelListener: listener)

        machine.connect()
        await machine.awaitInFlightTask()

        #expect(machine.state == .error)
        #expect(machine.errorMessage?.contains("isn't listening") == true) // RVL-3 distinct error
        #expect(listener.calls >= 1) // classification ran on the failure path
        #expect(dcv.launchCount == 0)
    }

    @Test("AC-2b: a healthy tunnel is never blocked by the listener check (no false negative)")
    func healthyTunnelNotBlockedByListenerCheck() async {
        // Even if the TCP listener probe would say "not listening", a successful readiness probe
        // connects and launches — the listener check must not run on the success path. This is the
        // regression guard for the v0.3.0 false-block.
        let listener = StubTunnelListenerProbe(listening: false)
        let probe = StubReadinessProbe(ready: true)
        let dcv = MockDCVLauncher()
        let machine = makeMachine(ec2: runningEC2(), dcv: dcv, readiness: probe, tunnelListener: listener)

        machine.connect()
        await machine.awaitInFlightTask()

        #expect(machine.state == .connected)
        #expect(dcv.launchCount == 1)
        #expect(listener.calls == 0) // never consulted on the happy path
    }

    @Test("AC-4: a transient readiness miss re-establishes once and then connects")
    func transientReadinessMissRetriesThenConnects() async {
        let probe = StubReadinessProbe(sequence: [false, true]) // miss, then ready
        let tunnel = RecordingTunnelProvider(handles: [])
        let dcv = MockDCVLauncher()
        let machine = makeMachine(ec2: runningEC2(), tunnel: tunnel, dcv: dcv, readiness: probe)

        machine.connect()
        await machine.awaitInFlightTask()

        #expect(machine.state == .connected)
        #expect(tunnel.startCount == 2) // RVL-5: one re-establish
        #expect(dcv.launchCount == 1)
    }

    @Test("AC-3: a changed instance-id resets stale state and is recorded")
    func instanceReplacementResetsAndRecords() async {
        let profile = ConnectionProfile.example
        let store = MockInstanceIdStore(seed: [profile.id: "i-old"])
        let ec2 = runningEC2(id: "i-new")
        let machine = makeMachine(ec2: ec2, instanceIds: store, profile: profile)

        machine.connect()
        await machine.awaitInFlightTask()

        #expect(machine.state == .connected)
        #expect(machine.log.entries.contains { $0.message.contains("instance changed") })
        #expect(store.lastInstanceId(forProfile: profile.id) == "i-new")
    }

    @Test("AC-3: an unchanged instance-id does not log a replacement")
    func sameInstanceNoReplacementLog() async {
        let profile = ConnectionProfile.example
        let store = MockInstanceIdStore(seed: [profile.id: "i-same"])
        let ec2 = runningEC2(id: "i-same")
        let machine = makeMachine(ec2: ec2, instanceIds: store, profile: profile)

        machine.connect()
        await machine.awaitInFlightTask()

        #expect(machine.state == .connected)
        #expect(!machine.log.entries.contains { $0.message.contains("instance changed") })
    }

    @Test("AC-5: readiness errors carry specific messages and the menu offers Retry")
    func readinessErrorsAreSpecificAndRetryable() async {
        #expect(DCVReadinessError.tunnelNotEstablished(port: 8443).errorDescription?.contains("8443") == true)
        #expect(DCVReadinessError.dcvServerNotReady(port: 8443).errorDescription?.contains("didn't become ready") == true)

        let machine = makeMachine(ec2: runningEC2(), readiness: StubReadinessProbe(ready: false))
        machine.connect()
        await machine.awaitInFlightTask()
        #expect(machine.state == .error)
        #expect(machine.actionTitle == "Retry Connect")
        #expect(machine.actionEnabled)
    }

    // MARK: SSO expiry recovery (F-17)

    @Test("an expired-credentials error triggers a single re-auth and then succeeds")
    func expiredCredentialsReauthRetries() async {
        let ec2 = SequencedEC2Service(resolveResults: [
            .failure(StubExpiredError()),
            .success(.stub(id: "i-reauth", state: .running)),
        ])
        let auth = MockAuthProvider()
        let machine = makeMachine(auth: auth, ec2: ec2, isExpired: { $0 is StubExpiredError })

        machine.connect()
        await machine.awaitInFlightTask()

        #expect(machine.state == .connected)
        #expect(machine.instanceId == "i-reauth")
        // One initial sign-in + one re-auth during the expired resolve.
        #expect(auth.authenticateCallCount == 2)
        #expect(ec2.resolveCount == 2)
    }

    // MARK: Auto-reconnect (F-13)

    @Test("an unexpected tunnel drop auto-reconnects")
    func tunnelDropAutoReconnects() async {
        let first = MockTunnelHandle()
        let second = MockTunnelHandle()
        let provider = RecordingTunnelProvider(handles: [first, second])
        let machine = makeMachine(ec2: runningEC2(), tunnel: provider)

        machine.connect()
        await machine.awaitInFlightTask()
        #expect(machine.state == .connected)
        #expect(provider.startCount == 1)

        first.simulateDrop(code: 1, stderr: "broken pipe")
        await waitUntil { provider.startCount == 2 && machine.state == .connected }

        #expect(provider.startCount == 2)
        #expect(machine.state == .connected)
    }

    @Test("a tunnel drop with auto-reconnect disabled ends in error")
    func tunnelDropNoReconnectErrors() async {
        let first = MockTunnelHandle()
        let provider = RecordingTunnelProvider(handles: [first])
        let machine = makeMachine(
            ec2: runningEC2(),
            tunnel: provider,
            settings: AppSettings(autoConnect: false, autoReconnect: false, clipboardAutoClearSeconds: 30)
        )

        machine.connect()
        await machine.awaitInFlightTask()
        #expect(machine.state == .connected)

        first.simulateDrop(code: 2, stderr: "")
        await waitUntil { machine.state == .error }

        #expect(machine.state == .error)
        #expect(provider.startCount == 1)
    }

    // MARK: System wake (zombie-tunnel recovery, F-13)

    @Test("wake from sleep with a dead tunnel reconnects and re-launches DCV")
    func wakeDeadTunnelReconnects() async {
        // Gate-ready on the initial connect, dead at the wake health-check (triggers reconnect),
        // ready again on the reconnect's launch gate. (The readiness gate is now fatal — #9 RVL-1.)
        let probe = StubReadinessProbe(sequence: [true, false, true])
        let tunnel = RecordingTunnelProvider(handles: [MockTunnelHandle(), MockTunnelHandle()])
        let dcv = MockDCVLauncher()
        let machine = makeMachine(ec2: runningEC2(), tunnel: tunnel, dcv: dcv, readiness: probe)

        machine.connect()
        await machine.awaitInFlightTask()
        #expect(machine.state == .connected)
        #expect(tunnel.startCount == 1)
        #expect(dcv.launchCount == 1)

        await machine.handleSystemWake()
        await machine.awaitInFlightTask()
        await waitUntil { tunnel.startCount == 2 }

        #expect(tunnel.startCount == 2)       // re-established the tunnel
        #expect(dcv.launchCount == 2)         // re-staged DCV automatically
        #expect(machine.state == .connected)
    }

    @Test("wake from sleep with a healthy tunnel does nothing")
    func wakeHealthyTunnelNoop() async {
        let probe = StubReadinessProbe(ready: true)
        let tunnel = RecordingTunnelProvider(handles: [MockTunnelHandle()])
        let machine = makeMachine(ec2: runningEC2(), tunnel: tunnel, readiness: probe)

        machine.connect()
        await machine.awaitInFlightTask()
        #expect(tunnel.startCount == 1)

        await machine.handleSystemWake()
        #expect(tunnel.startCount == 1)
        #expect(machine.state == .connected)
    }

    // MARK: Disconnect / stop

    @Test("disconnect tears down and returns to disconnected")
    func disconnectResets() async {
        let machine = makeMachine(ec2: runningEC2())
        machine.connect()
        await machine.awaitInFlightTask()
        #expect(machine.state == .connected)

        machine.disconnect()
        await machine.awaitInFlightTask()

        #expect(machine.state == .disconnected)
        #expect(machine.instanceId == nil)
        #expect(machine.password == nil)
    }

    @Test("stop workstation stops the instance and disconnects")
    func stopWorkstationStopsInstance() async {
        let ec2 = runningEC2(id: "i-stop")
        let machine = makeMachine(ec2: ec2)
        machine.connect()
        await machine.awaitInFlightTask()
        #expect(machine.state == .connected)

        machine.stopWorkstation()
        await machine.awaitInFlightTask()

        #expect(machine.state == .disconnected)
        #expect(ec2.stopCount == 1)
        #expect(ec2.lastStoppedInstanceId == "i-stop")
    }

    // MARK: onLaunch

    @Test("onLaunch sweeps orphaned DCV files and does not auto-connect by default")
    func onLaunchSweepsWithoutAutoConnect() async {
        let dcv = MockDCVLauncher()
        let machine = makeMachine(ec2: runningEC2(), dcv: dcv)

        machine.onLaunch()
        await machine.awaitInFlightTask()

        #expect(dcv.sweepCount == 1)
        #expect(machine.state == .disconnected)
    }

    @Test("onLaunch auto-connects when configured")
    func onLaunchAutoConnects() async {
        let machine = makeMachine(
            ec2: runningEC2(),
            settings: AppSettings(autoConnect: true, autoReconnect: true, clipboardAutoClearSeconds: 30)
        )

        machine.onLaunch()
        await machine.awaitInFlightTask()

        #expect(machine.state == .connected)
    }

    // MARK: Notifications + logging (Phase H)

    @Test("a successful connect posts a Connected notification and logs transitions")
    func connectNotifiesAndLogs() async {
        let notifier = MockNotifier()
        let machine = makeMachine(ec2: runningEC2(), notifier: notifier)

        machine.connect()
        await machine.awaitInFlightTask()

        #expect(notifier.events.contains(.connected))
        #expect(machine.log.entries.contains { $0.message.contains("State:") })
    }

    @Test("stop workstation posts a Stopped notification")
    func stopNotifies() async {
        let notifier = MockNotifier()
        let machine = makeMachine(ec2: runningEC2(), notifier: notifier)
        machine.connect()
        await machine.awaitInFlightTask()

        machine.stopWorkstation()
        await machine.awaitInFlightTask()

        #expect(notifier.events.contains(.stopped))
    }

    @Test("onLaunch requests notification authorization once")
    func onLaunchRequestsAuthorization() async {
        let notifier = MockNotifier()
        let machine = makeMachine(ec2: runningEC2(), notifier: notifier)

        machine.onLaunch()
        await machine.awaitInFlightTask()
        // The auth request is fired on a detached Task; wait for it to run.
        await waitUntil { notifier.authorizationRequests >= 1 }

        #expect(notifier.authorizationRequests >= 1)
    }

    @Test("an expired-credentials recovery posts a sign-in-required notification")
    func reauthNotifiesSignIn() async {
        let ec2 = SequencedEC2Service(resolveResults: [
            .failure(StubExpiredError()),
            .success(.stub(id: "i-reauth", state: .running)),
        ])
        let notifier = MockNotifier()
        let machine = makeMachine(ec2: ec2, notifier: notifier, isExpired: { $0 is StubExpiredError })

        machine.connect()
        await machine.awaitInFlightTask()

        #expect(machine.state == .connected)
        #expect(notifier.events.contains(.signInRequired))
    }
}

@Suite("withStageTimeout")
struct StageTimeoutTests {
    @Test("returns the operation result when it finishes in time")
    func returnsResult() async throws {
        let value = try await withStageTimeout("fast", .seconds(10)) { 42 }
        #expect(value == 42)
    }

    @Test("throws StageTimeoutError when the operation is too slow")
    func throwsOnTimeout() async {
        await #expect(throws: StageTimeoutError.self) {
            try await withStageTimeout("slow", .milliseconds(10)) {
                try await Task.sleep(for: .seconds(5))
                return 0
            }
        }
    }
}
