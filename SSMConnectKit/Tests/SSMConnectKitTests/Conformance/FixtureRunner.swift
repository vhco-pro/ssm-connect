import Foundation
@testable import SSMConnectDomain
@testable import SSMConnectWorkflow
@testable import SSMConnectAWS
@testable import SSMConnectMacOS
@testable import SSMConnectUI

/// Locates `contracts/` by walking up from this source file, so the fixtures are read from the one
/// copy in the repository. Copying them into the test bundle would let the two drift.
enum FixturePaths {
    static let contractsDirectory: URL = {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while directory.path != "/" {
            let candidate = directory.appendingPathComponent("contracts")
            if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("validate.py").path) {
                return candidate
            }
            directory = directory.deletingLastPathComponent()
        }
        fatalError("Could not locate the contracts/ directory above \(#filePath).")
    }()

    static var workflowsDirectory: URL { contractsDirectory.appendingPathComponent("fixtures/workflows") }

    static func workflowFixtureFiles() -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: workflowsDirectory, includingPropertiesForKeys: nil)) ?? []
        return contents.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
    }

    static func loadFixture(at url: URL) throws -> Fixture {
        try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }
}

/// The observable outcome of one fixture run, ready to assert against.
struct FixtureRun {
    let states: [String]
    let calls: [RecordedCall]
    let recorder: PortRecorder
    let machine: ConnectionStateMachine
}

/// Executes one conformance fixture against the real `ConnectionStateMachine`, with every port
/// faked from the fixture's declared outcomes.
@MainActor
final class FixtureRunner {
    private let fixture: Fixture
    private var states: [String] = []
    private var firedEvents: Set<Int> = []
    private var dispatchedSteps: Set<Int> = []

    private var recorder: PortRecorder!
    private var tunnels: FixtureTunnelProvider!
    private var sink: FixtureEventSink!
    private var machine: ConnectionStateMachine!

    init(fixture: Fixture) { self.fixture = fixture }

    func run() async throws -> FixtureRun {
        let profile = try Self.loadProfile(fixture)
        let recorder = PortRecorder(given: fixture.given)
        let tunnels = FixtureTunnelProvider(recorder: recorder)
        let sink = FixtureEventSink()
        self.recorder = recorder
        self.tunnels = tunnels
        self.sink = sink

        machine = ConnectionStateMachine(
            authProvider: FixtureAuthProvider(recorder: recorder),
            ec2: FixtureEC2Provider(recorder: recorder),
            ssm: FixtureSSMProvider(recorder: recorder),
            tunnel: tunnels,
            secrets: FixtureSecretsProvider(recorder: recorder),
            identity: FixtureIdentityProvider(recorder: recorder),
            agent: FixtureAgentClient(recorder: recorder),
            dcv: FixtureDCVLauncher(recorder: recorder, viewerInstalled: fixture.given.viewerInstalled),
            readiness: FixtureReadinessProbe(recorder: recorder),
            tunnelListener: FixtureTunnelListenerProbe(recorder: recorder),
            instanceIds: FixtureInstanceIdStore(recorder: recorder, seed: fixture.given.lastInstanceId),
            // Never send a real signal. `processIdentifier` is a synthetic number from the fixture
            // and would otherwise name an unrelated live process on the host.
            terminateProcess: { [weak tunnels] pid in
                tunnels?.handles.first { $0.processIdentifier == pid }?.terminateByProcessKill()
            },
            log: ConnectionLog(),
            events: sink,
            profile: profile,
            settings: buildSettings(),
            timeouts: buildTimeouts(),
            maxReconnectAttempts: fixture.harness?.maxReconnectAttempts ?? 3,
            reconnectBackoff: .seconds(fixture.harness?.reconnectBackoffSeconds ?? 5),
            // Every backoff collapses to nothing: fixtures assert ordering, never wall-clock time.
            reconnectSleep: { _ in }
        )
        // The sink is what feeds the fixture its ordered state sequence, and it fires synchronously
        // inside the flow — which is what lets a step pinned to `afterState` land before the next
        // port call instead of racing it.
        sink.onState = { [weak self] state in self?.onStateChanged(state) }

        // Steps with no `afterState` run in order, each settling before the next. Steps that name a
        // state are dispatched from the state callback, which fires synchronously inside the flow,
        // so a cancelling action lands before the next port call instead of racing it.
        for (index, step) in fixture.when.enumerated() where step.afterState == nil {
            if dispatchedSteps.insert(index).inserted {
                dispatch(step.action)
                await settle()
            }
        }
        await settle()

        return FixtureRun(states: states, calls: recorder.calls, recorder: recorder, machine: machine)
    }

    // MARK: - Wiring

    private func buildSettings() -> AppSettings {
        var settings = AppSettings.default
        guard let over = fixture.settings else { return settings }
        settings.autoConnect = over.autoConnect ?? settings.autoConnect
        settings.autoReconnect = over.autoReconnect ?? settings.autoReconnect
        settings.clipboardAutoClearSeconds = over.clipboardAutoClearSeconds ?? settings.clipboardAutoClearSeconds
        return settings
    }

    private func buildTimeouts() -> ConnectionTimeouts {
        var timeouts = ConnectionTimeouts.default
        // The agent retry loop exists to ride out a tunnel that is not listening yet. With instant
        // delays a 15-attempt budget would spin pointlessly; 3 still exercises the retry itself.
        timeouts.ensureSessionAttempts = 3
        timeouts.ensureSessionRetryInterval = .zero

        guard let over = fixture.harness else { return timeouts }
        timeouts.establishRetryAttempts = over.establishRetryAttempts ?? timeouts.establishRetryAttempts
        timeouts.establishRetryBackoff = .zero
        for (stage, seconds) in over.stageTimeoutSeconds ?? [:] {
            let duration = Duration.seconds(seconds)
            switch stage {
            case "authenticate": timeouts.authenticate = duration
            case "resolve":      timeouts.resolve = duration
            case "start":        timeouts.start = duration
            case "ssm":          timeouts.ssm = duration
            case "tunnel":       timeouts.tunnel = duration
            case "dcvReady":     timeouts.dcvReady = duration
            default:
                fatalError("Fixture '\(fixture.id)' overrides unknown stage timeout '\(stage)'.")
            }
        }
        return timeouts
    }

    /// Builds the profile a fixture references, applying its shallow field overrides.
    private static func loadProfile(_ fixture: Fixture) throws -> ConnectionProfile {
        guard let reference = fixture.profile.ref else {
            throw FixtureError.message("Fixture '\(fixture.id)' has no profile reference.")
        }
        // `$ref` is relative to the fixture file, so it starts with "../". Append then standardize:
        // building the URL with `relativeTo:` would not resolve the parent traversal.
        let url = FixturePaths.workflowsDirectory.appendingPathComponent(reference).standardized
        guard case var .object(fields) = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url)) else {
            throw FixtureError.message("Profile '\(reference)' is not a JSON object.")
        }
        for (key, value) in fixture.profile.overrides ?? [:] { fields[key] = value }

        func text(_ key: String) -> String { fields[key]?.stringValue ?? "" }
        func number(_ key: String, _ fallback: Int) -> Int { fields[key]?.intValue ?? fallback }

        return ConnectionProfile(
            id: UUID(uuidString: text("id")) ?? UUID(),
            name: text("name"),
            ssoStartUrl: text("ssoStartUrl"),
            ssoRegion: text("ssoRegion"),
            accountId: text("accountId"),
            roleName: text("roleName"),
            resourceRegion: text("resourceRegion"),
            instanceTagKey: text("instanceTagKey"),
            instanceTagValue: text("instanceTagValue"),
            secretId: fields["secretId"]?.stringValue,
            localPort: number("localPort", 8443),
            remotePort: number("remotePort", 8443),
            connectAction: .dcvViewer,
            connectMode: fields["connectMode"]?.stringValue.flatMap(ConnectMode.init(rawValue:)),
            agentRemotePort: fields["agentRemotePort"]?.intValue
        )
    }

    // MARK: - Driving

    private func dispatch(_ action: String) {
        switch action {
        case "onLaunch":                machine.onLaunch()
        case "connect":                 machine.connect()
        case "disconnect":              machine.disconnect()
        case "reconnect":               machine.reconnect()
        case "stopWorkstation":         machine.stopWorkstation()
        case "handleSystemWake":        Task { await self.machine.handleSystemWake() }
        case "applicationWillTerminate": machine.terminateTunnelForQuit()
        default: fatalError("Unknown fixture action '\(action)'.")
        }
    }

    /// Fires whatever a fixture pinned to this state: injected events first, so a tunnel drop is
    /// visible to the monitor the flow is about to start, then any pending actions.
    private func onStateChanged(_ state: ConnectionState) {
        let wire = state.rawValue
        states.append(wire)

        for (index, event) in fixture.given.events.enumerated()
        where event.afterState == wire && firedEvents.insert(index).inserted {
            fire(event)
        }

        for (index, step) in fixture.when.enumerated()
        where step.afterState == wire && dispatchedSteps.insert(index).inserted {
            dispatch(step.action)
        }
    }

    private func fire(_ event: FixtureEvent) {
        switch event.kind {
        case "tunnelDrop":
            // The main tunnel, not a transient agent tunnel: match on the forwarded local port.
            // Deferred because the monitor is started just *after* `connected` is emitted, and a
            // drop delivered before that would be observed by nobody.
            let port = machine.profile.localPort
            Task { @MainActor in
                self.tunnels.handles.last { $0.isActive && $0.localPort == port }?
                    .injectProcessExit(code: Int32(event.reason?.exitCode ?? 1), stderr: event.reason?.stderr ?? "")
            }
        case "systemWake":
            Task { await self.machine.handleSystemWake() }
        case "applicationWillTerminate":
            machine.terminateTunnelForQuit()
        default:
            fatalError("Unknown fixture event '\(event.kind)'.")
        }
    }

    /// Waits until nothing further happens. Every fake completes instantly, so once the recorded
    /// state and call counts hold still across several rounds the run has genuinely settled —
    /// including an auto-reconnect a tunnel monitor started after the first check.
    private func settle() async {
        var quietRounds = 0
        var lastSignature = signature()
        for _ in 0..<200 {
            await machine.awaitInFlightTask()
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(2))

            let current = signature()
            if current == lastSignature {
                quietRounds += 1
                if quietRounds >= 5 { break }
            } else {
                quietRounds = 0
                lastSignature = current
            }
        }
        await machine.awaitInFlightTask()
    }

    private func signature() -> String { "\(states.count)/\(recorder.calls.count)/\(machine.state.rawValue)" }
}

enum FixtureError: Error, CustomStringConvertible {
    case message(String)

    var description: String {
        if case let .message(text) = self { return text }
        return "Fixture error."
    }
}
