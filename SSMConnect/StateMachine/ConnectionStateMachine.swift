import Foundation
import Observation

/// Orchestrates the full connection lifecycle across all service layers (Phase F, spec §5).
///
/// Drives the 8-state machine end-to-end using injected protocols, so the whole flow is
/// unit-testable with mocks (ADR-P2). Notable behaviors:
/// - **Auto-start** a `stopped`/`stopping` instance before connecting (F-07).
/// - **Auto-reconnect** the tunnel if it drops unexpectedly (F-13).
/// - **SSO expiry recovery**: re-authenticate and retry a failed AWS step without tearing
///   down an active tunnel (F-17).
/// - **Per-stage timeouts** per the §5 timing budget (F-06).
@MainActor
@Observable
final class ConnectionStateMachine {
    // MARK: Observed state (drives the menu + menu-bar icon)

    private(set) var state: ConnectionState = .disconnected {
        didSet {
            guard oldValue != state else { return }
            log.log(.ui, "State: \(oldValue.rawValue) \u{2192} \(state.rawValue)")
        }
    }
    private(set) var errorMessage: String?
    /// Non-fatal note shown while still Connected (e.g. DCV Viewer missing, F-16).
    private(set) var warningMessage: String?
    private(set) var instanceId: String?
    /// Last-known EC2 instance state, shown in the menu detail (F-12).
    private(set) var instanceState: EC2Instance.State?
    private(set) var tunnelPID: Int32?
    private(set) var localPort: Int?
    /// DCV password held in memory only (F-11) for the menu's masked display + copy.
    private(set) var password: String?
    private(set) var connectedAt: Date?
    private(set) var credentialsExpiry: Date?

    // MARK: Dependencies

    private let authProvider: AuthProviding
    private let ec2: EC2Providing
    private let ssm: SSMProviding
    private let tunnel: TunnelProvider
    private let secrets: SecretsProviding
    private let dcv: DCVLaunching
    private let clipboard: ClipboardManager
    /// In-memory connection log (F-19) + Apple Unified Logging (NF-14). Exposed for the log window.
    let log: ConnectionLog
    private let notifier: Notifying
    /// Active connection profile + global settings. Updatable via `apply(profile:settings:)`
    /// while disconnected so an active-profile switch in Settings takes effect on next connect.
    private(set) var profile: ConnectionProfile
    private(set) var settings: AppSettings
    private let timeouts: ConnectionTimeouts
    private let isExpiredCredentials: @Sendable (Error) -> Bool
    private let maxReconnectAttempts: Int
    private let reconnectBackoff: Duration
    /// Sleep used for the auto-reconnect backoff (injectable so tests don't wait). Stage timeouts
    /// use the real clock with their long real budgets, so they never fire under fast mocks.
    private let reconnectSleep: @Sendable (Duration) async throws -> Void

    // MARK: Working state

    private var credentials: AWSCredentials?
    private var currentHandle: TunnelHandle?
    private var monitorTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?

    init(
        authProvider: AuthProviding = AWSAuthProvider(),
        ec2: EC2Providing = EC2Service(),
        ssm: SSMProviding = SSMService(),
        tunnel: TunnelProvider = BundledPluginTunnel(),
        secrets: SecretsProviding = SecretsService(),
        dcv: DCVLaunching = DCVLauncher(),
        clipboard: ClipboardManager = ClipboardManager(),
        log: ConnectionLog? = nil,
        notifier: Notifying = UserNotificationService(),
        profile: ConnectionProfile = .factoryDefault,
        settings: AppSettings = .default,
        timeouts: ConnectionTimeouts = .default,
        isExpiredCredentials: @escaping @Sendable (Error) -> Bool = ConnectionStateMachine.defaultExpiredCredentialsCheck,
        maxReconnectAttempts: Int = 3,
        reconnectBackoff: Duration = .seconds(5),
        reconnectSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.authProvider = authProvider
        self.ec2 = ec2
        self.ssm = ssm
        self.tunnel = tunnel
        self.secrets = secrets
        self.dcv = dcv
        self.clipboard = clipboard
        self.log = log ?? ConnectionLog()
        self.notifier = notifier
        self.profile = profile
        self.settings = settings
        self.timeouts = timeouts
        self.isExpiredCredentials = isExpiredCredentials
        self.maxReconnectAttempts = maxReconnectAttempts
        self.reconnectBackoff = reconnectBackoff
        self.reconnectSleep = reconnectSleep
    }

    // MARK: - Public API (F1)

    /// Apply a new active profile / settings. Ignored while a connection is in flight so we
    /// never swap the target out from under an active tunnel (takes effect on next connect).
    func apply(profile: ConnectionProfile, settings: AppSettings) {
        guard state == .disconnected else {
            self.settings = settings // settings (e.g. auto-reconnect) are safe to update live
            return
        }
        self.profile = profile
        self.settings = settings
    }

    /// Called once on app launch: sweep stale DCV files and auto-connect if configured (F-03).
    func onLaunch() {
        dcv.sweepOrphanedFiles()
        Task { await notifier.requestAuthorization() }
        if settings.autoConnect, state == .disconnected {
            connect()
        }
    }

    /// Run the full connection flow. No-op if already connecting/connected.
    func connect() {
        guard connectTask == nil, state != .connected else { return }
        let task = Task { await runConnect() }
        connectTask = task
    }

    /// Tear down any tunnel and return to `disconnected`.
    func disconnect() {
        connectTask?.cancel()
        let task = Task {
            defer { connectTask = nil }
            await teardownTunnel()
            resetToDisconnected()
        }
        connectTask = task
    }

    /// Tear down and re-run the full flow (re-resolves the instance, F-14).
    func reconnect() {
        connectTask?.cancel()
        let task = Task {
            await teardownTunnel()
            await runConnect()
        }
        connectTask = task
    }

    /// Stop the workstation instance and disconnect (F-15).
    func stopWorkstation() {
        guard let instanceId, let credentials else { return }
        connectTask?.cancel()
        connectTask = nil
        let task = Task {
            defer { connectTask = nil }
            await teardownTunnel()
            do {
                log.log(.ec2, "Stopping instance \(instanceId)…")
                try await ec2.stopInstance(instanceId: instanceId, region: profile.resourceRegion, credentials: credentials)
                resetToDisconnected()
                await notifier.post(.stopped)
            } catch {
                fail(error)
            }
        }
        connectTask = task
    }

    /// Copy the in-memory DCV password to the clipboard (F-11).
    func copyPassword() {
        guard let password else { return }
        clipboard.copy(password)
    }

    /// Test hook: await the most recent connect/disconnect/reconnect/stop task to completion.
    /// (Tunnel-drop auto-reconnect runs on a separate monitor task; poll `state` for those.)
    func awaitInFlightTask() async {
        await connectTask?.value
    }

    // MARK: - Connection flow (F2)

    private func runConnect() async {
        defer { connectTask = nil }
        errorMessage = nil
        warningMessage = nil
        log.log(.ui, "Connecting to \(profile.name) (\(profile.resourceRegion))…")

        do {
            // 1. Authenticate (F-04/F-05)
            state = .authenticating
            let authProvider = self.authProvider
            let profile = self.profile
            let creds = try await withStageTimeout("Sign-in", timeouts.authenticate) {
                try await authProvider.authenticate(profile: profile)
            }
            try Task.checkCancellation()
            setCredentials(creds)
            log.log(.auth, "Authenticated; SSO session valid.")

            // 2. Resolve the instance by tag (F-06)
            state = .resolving
            var instance = try await withReauth { [ec2, profile] creds in
                try await withStageTimeout("Finding instance", self.timeouts.resolve) {
                    try await ec2.resolveInstance(
                        tagKey: profile.instanceTagKey,
                        tagValue: profile.instanceTagValue,
                        region: profile.resourceRegion,
                        credentials: creds
                    )
                }
            }
            try Task.checkCancellation()
            instanceId = instance.id
            instanceState = instance.state
            log.log(.ec2, "Resolved instance \(instance.id) (\(instance.state.rawValue)).")
            if instance.state.isTerminal {
                throw EC2Error.instanceTerminated(instanceId: instance.id)
            }

            // 3. Auto-start a stopped instance (F-07)
            if instance.state != .running {
                state = .starting
                log.log(.ec2, "Instance is \(instance.state.rawValue); starting it…")
                instance = try await withReauth { [ec2, profile, timeouts] creds in
                    try await ec2.startInstance(instanceId: instance.id, region: profile.resourceRegion, credentials: creds)
                    return try await ec2.pollUntilRunning(
                        instanceId: instance.id,
                        region: profile.resourceRegion,
                        credentials: creds,
                        timeout: timeouts.start,
                        interval: timeouts.startPollInterval
                    )
                }
                try Task.checkCancellation()
                instanceState = instance.state
                log.log(.ec2, "Instance is now running.")
            }

            // 4. Wait for the SSM agent (F-08)
            state = .waitingForSSM
            log.log(.ssm, "Waiting for the SSM agent to come online…")
            try await withReauth { [ssm, profile, timeouts] creds in
                try await ssm.waitForSSMOnline(
                    instanceId: instance.id,
                    region: profile.resourceRegion,
                    credentials: creds,
                    timeout: timeouts.ssm,
                    interval: timeouts.ssmPollInterval
                )
            }
            try Task.checkCancellation()
            log.log(.ssm, "SSM agent is online.")

            // 5. Open the port-forwarding tunnel (F-09)
            state = .tunneling
            let handle = try await establishTunnel(instanceId: instance.id)
            try Task.checkCancellation()

            // 6. Fetch the password, copy it, and auto-login DCV (F-10/F-11, best-effort F-16)
            await fetchSecretAndLaunchDCV()

            // 7. Connected
            state = .connected
            connectedAt = Date()
            log.log(.tunnel, "Connected: localhost:\(profile.localPort) → \(instance.id):\(profile.remotePort).")
            startTunnelMonitor(handle: handle)
            await notifier.post(.connected)
        } catch is CancellationError {
            // disconnect()/reconnect() cancelled us; they own the resulting state.
            return
        } catch {
            await teardownTunnel()
            fail(error)
        }
    }

    /// Open a session + tunnel for `instanceId`, recording handle/PID/port. Used by the main
    /// flow and by auto-reconnect.
    private func establishTunnel(instanceId: String) async throws -> TunnelHandle {
        let session = try await withReauth { [ssm, profile] creds in
            try await ssm.startSession(
                instanceId: instanceId,
                region: profile.resourceRegion,
                credentials: creds,
                localPort: profile.localPort,
                remotePort: profile.remotePort
            )
        }
        let tunnel = self.tunnel
        let profile = self.profile
        let handle = try await withStageTimeout("Opening tunnel", timeouts.tunnel) {
            try await tunnel.startTunnel(
                session: session,
                region: profile.resourceRegion,
                instanceId: instanceId,
                localPort: profile.localPort,
                remotePort: profile.remotePort
            )
        }
        currentHandle = handle
        tunnelPID = handle.processIdentifier
        localPort = profile.localPort
        return handle
    }

    /// Fetch the DCV password, copy it to the clipboard, and auto-login DCV Viewer.
    /// Failures here are non-fatal — the tunnel stays up (F-16, spec §8).
    private func fetchSecretAndLaunchDCV() async {
        guard let secretId = profile.secretId else { return }
        do {
            let pw = try await withReauth { [secrets, profile] creds in
                try await secrets.fetchSecret(secretId: secretId, region: profile.resourceRegion, credentials: creds)
            }
            password = pw
            clipboard.copy(pw)

            guard dcv.isViewerInstalled() else {
                warningMessage = DCVError.viewerNotInstalled.errorDescription
                return
            }
            let file = DCVConnectionFile(port: profile.localPort, password: pw)
            try await dcv.launch(connectionFile: file)
        } catch {
            warningMessage = describe(error)
        }
    }

    // MARK: - Auto-reconnect (F4)

    private func startTunnelMonitor(handle: TunnelHandle) {
        monitorTask?.cancel()
        let stream = handle.onDisconnect
        monitorTask = Task { [weak self] in
            for await reason in stream {
                await self?.handleTunnelDrop(reason)
                break
            }
        }
    }

    private func handleTunnelDrop(_ reason: TunnelDropReason) async {
        switch reason {
        case .terminatedByUser:
            return // normal teardown — disconnect()/reconnect() drive the next state
        case let .processExited(code, stderr):
            currentHandle = nil
            tunnelPID = nil
            if settings.autoReconnect {
                await attemptAutoReconnect(detail: stderr.isEmpty ? "exit code \(code)" : stderr)
            } else {
                errorMessage = "The SSM tunnel dropped (exit code \(code))."
                state = .error
            }
        }
    }

    private func attemptAutoReconnect(detail: String) async {
        guard let instanceId else { state = .error; return }
        log.log(.tunnel, "Tunnel dropped (\(detail)); reconnecting…")
        await notifier.post(.reconnecting)
        for attempt in 1...maxReconnectAttempts {
            do {
                try await reconnectSleep(reconnectBackoff)
                state = .tunneling
                let handle = try await establishTunnel(instanceId: instanceId)
                state = .connected
                connectedAt = Date()
                startTunnelMonitor(handle: handle)
                log.log(.tunnel, "Reconnected after \(attempt) attempt(s).")
                await notifier.post(.connected)
                return
            } catch is CancellationError {
                return
            } catch {
                if attempt == maxReconnectAttempts {
                    errorMessage = "Auto-reconnect failed after \(maxReconnectAttempts) attempts (\(detail)): \(describe(error))"
                    state = .error
                }
            }
        }
    }

    // MARK: - SSO expiry recovery (F5)

    /// Run `op` with the current credentials. If it fails with an expired-credentials error,
    /// re-authenticate once and retry — without tearing down an active tunnel (F-17).
    private func withReauth<T>(_ op: (AWSCredentials) async throws -> T) async throws -> T {
        guard let creds = credentials else { throw AuthError.signInRequired }
        do {
            return try await op(creds)
        } catch {
            guard isExpiredCredentials(error) else { throw error }
            log.log(.auth, "SSO session expired; re-authenticating…")
            await notifier.post(.signInRequired)
            let fresh = try await authProvider.authenticate(profile: profile)
            setCredentials(fresh)
            return try await op(fresh)
        }
    }

    // MARK: - Helpers

    private func setCredentials(_ creds: AWSCredentials) {
        credentials = creds
        credentialsExpiry = creds.expiration
    }

    private func teardownTunnel() async {
        monitorTask?.cancel()
        monitorTask = nil
        if let handle = currentHandle {
            await handle.terminate()
        }
        currentHandle = nil
        tunnelPID = nil
    }

    private func resetToDisconnected() {
        state = .disconnected
        errorMessage = nil
        warningMessage = nil
        instanceId = nil
        instanceState = nil
        localPort = nil
        password = nil
        connectedAt = nil
    }

    private func fail(_ error: Error) {
        let message = describe(error)
        errorMessage = message
        log.log(.ui, "Error: \(message)")
        state = .error
    }

    private func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    /// Default heuristic for detecting expired/unauthorized SSO credentials across SDK services.
    nonisolated static func defaultExpiredCredentialsCheck(_ error: Error) -> Bool {
        let description = String(reflecting: error)
        return description.contains("ExpiredToken")
            || description.contains("UnauthorizedAccess")
            || description.contains("ExpiredTokenException")
    }
}
