import Foundation
import Testing
@testable import SSMConnect

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
        clipboard: ClipboardManager = ClipboardManager(pasteboard: FakePasteboard(), autoClearAfter: nil),
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
            clipboard: clipboard,
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
        #expect(machine.localPort == ConnectionProfile.factoryDefault.localPort)
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
