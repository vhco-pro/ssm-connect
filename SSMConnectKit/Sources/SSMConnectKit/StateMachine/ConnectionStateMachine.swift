import Darwin
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
public final class ConnectionStateMachine {
    // MARK: Observed state (drives the menu + menu-bar icon)

    public private(set) var state: ConnectionState = .disconnected {
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
    private let readiness: WorkstationReadinessProbing
    /// Asserts the local tunnel port is actually listening before the readiness probe (#9, RVL-3).
    private let tunnelListener: TunnelListenerProbing
    /// Persists last-connected instance-id per profile for instance-replacement detection (#9, RVL-4).
    private let instanceIds: InstanceIdPersisting
    private let clipboard: ClipboardManager
    /// In-memory connection log (F-19) + Apple Unified Logging (NF-14). Exposed for the log window.
    public let log: ConnectionLog
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
    /// Monotonic id for the current `connectTask`. A finishing task clears `connectTask` only if
    /// it is still the current one, so a cancelled flow can't null out its successor's handle.
    private var connectGeneration = 0

    /// Public entry point for the app shell: a state machine for a profile + settings, wired with
    /// the default production dependencies. The full dependency-injecting init stays internal so the
    /// provider protocols don't leak into the package's public API.
    public convenience init(profile: ConnectionProfile, settings: AppSettings) {
        self.init(profile: profile, settings: settings, timeouts: .default)
    }

    init(
        authProvider: AuthProviding = AWSAuthProvider(),
        ec2: EC2Providing = EC2Service(),
        ssm: SSMProviding = SSMService(),
        tunnel: TunnelProvider = BundledPluginTunnel(),
        secrets: SecretsProviding = SecretsService(),
        dcv: DCVLaunching = DCVLauncher(),
        readiness: WorkstationReadinessProbing = HTTPSReadinessProbe(),
        tunnelListener: TunnelListenerProbing = TCPListenerProbe(),
        instanceIds: InstanceIdPersisting = UserDefaultsInstanceIdStore(),
        clipboard: ClipboardManager = ClipboardManager(),
        log: ConnectionLog? = nil,
        notifier: Notifying = UserNotificationService(),
        profile: ConnectionProfile = .template,
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
        self.readiness = readiness
        self.tunnelListener = tunnelListener
        self.instanceIds = instanceIds
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
        clipboard.setAutoClear(seconds: settings.clipboardAutoClearSeconds)
        // Kill the plugin child on app quit so it isn't orphaned holding the local port (F-13).
        AppQuitHandler.shared.register { [weak self] in self?.terminateTunnelForQuit() }
    }

    /// Synchronous best-effort plugin teardown for app termination (F-13). `applicationWillTerminate`
    /// can't await `terminate()`, so signal the child process directly (SIGTERM, then SIGKILL).
    func terminateTunnelForQuit() {
        monitorTask?.cancel()
        guard let pid = tunnelPID, pid > 0 else { return }
        kill(pid, SIGTERM)
        usleep(300_000) // 0.3s grace
        kill(pid, SIGKILL)
    }

    // MARK: - Public API (F1)

    /// Apply a new active profile / settings. Ignored while a connection is in flight so we
    /// never swap the target out from under an active tunnel (takes effect on next connect).
    func apply(profile: ConnectionProfile, settings: AppSettings) {
        clipboard.setAutoClear(seconds: settings.clipboardAutoClearSeconds)
        guard state == .disconnected else {
            self.settings = settings // settings (e.g. auto-reconnect) are safe to update live
            return
        }
        self.profile = profile
        self.settings = settings
    }

    /// Called once on app launch: sweep stale DCV files and auto-connect if configured (F-03).
    public func onLaunch() {
        dcv.sweepOrphanedFiles()
        Task { await notifier.requestAuthorization() }
        // Only auto-connect a fully configured profile — a fresh install has none yet (F-03/F-18).
        if settings.autoConnect, state == .disconnected, profile.isConfigured {
            connect()
        }
    }

    /// Called when the machine wakes from system sleep. An apparently-`Connected` tunnel can be a
    /// zombie — the `session-manager-plugin` process survives sleep but its data channel (and the
    /// DCV session) is dead, so the app still shows "Connected" while DCV Viewer drops to its
    /// connect screen. Health-check the forwarded port; if it isn't really responding, reconnect
    /// (re-establishes the tunnel and re-launches DCV auto-login) (F-13).
    public func handleSystemWake() async {
        guard state == .connected, let port = localPort else { return }
        let healthy = await readiness.waitUntilReady(port: port, timeout: .seconds(8), interval: .seconds(2))
        guard !healthy else { return }
        log.log(.tunnel, "Workstation not responding after wake from sleep; reconnecting…")
        reconnect()
    }

    /// Run the full connection flow. No-op if already connecting/connected.
    func connect() {
        guard connectTask == nil, state != .connected else { return }
        launchTask { await self.runConnect() }
    }

    /// Tear down any tunnel and return to `disconnected`.
    func disconnect() {
        let previous = connectTask
        previous?.cancel()
        launchTask {
            await previous?.value
            await self.teardownTunnel()
            self.resetToDisconnected()
        }
    }

    /// Tear down and re-run the full flow (re-resolves the instance, F-14).
    func reconnect() {
        let previous = connectTask
        previous?.cancel()
        launchTask {
            await previous?.value
            await self.teardownTunnel()
            await self.runConnect()
        }
    }

    /// Stop the workstation instance and disconnect (F-15).
    func stopWorkstation() {
        guard let instanceId, let credentials else { return }
        let previous = connectTask
        previous?.cancel()
        launchTask {
            await previous?.value
            await self.teardownTunnel()
            do {
                self.log.log(.ec2, "Stopping instance \(instanceId)…")
                try await self.ec2.stopInstance(instanceId: instanceId, region: self.profile.resourceRegion, credentials: credentials)
                self.resetToDisconnected()
                await self.notifier.post(.stopped)
            } catch {
                self.fail(error)
            }
        }
    }

    /// Launch `body` as the single in-flight connect/disconnect/reconnect/stop task. On completion
    /// it clears `connectTask` only if a newer `launchTask` hasn't replaced it — so a cancelled
    /// task unwinding later can't clobber its successor (defeating the `connect()` guard).
    private func launchTask(_ body: @escaping () async -> Void) {
        connectGeneration += 1
        let generation = connectGeneration
        connectTask = Task {
            await body()
            if self.connectGeneration == generation { self.connectTask = nil }
        }
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

            // Instance-replacement detection (F-14, RVL-4): if the workstation was rebuilt, its
            // instance-id changed — never reuse a tunnel/handle/port bound to the terminated one.
            if let previous = instanceIds.lastInstanceId(forProfile: profile.id), previous != instance.id {
                log.log(.ec2, "Workstation instance changed (\(previous) \u{2192} \(instance.id)); resetting stale tunnel state.")
                await teardownTunnel()
                localPort = nil
                tunnelPID = nil
            }
            instanceIds.setLastInstanceId(instance.id, forProfile: profile.id)

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

            // 5. Open the port-forwarding tunnel (F-09) and hard-gate on endpoint readiness:
            //    assert the tunnel is listening + the DCV server answers BEFORE launching the
            //    viewer, re-establishing a bounded number of times on a readiness miss (#9,
            //    RVL-1/2/3/5). On exhaustion this throws a distinct, retryable error — we never
            //    launch the viewer into an unverified endpoint.
            state = .tunneling
            let handle = try await establishReadyTunnel(instanceId: instance.id)
            try Task.checkCancellation()

            // 6. Auto-login DCV — vanilla password (single-user) or identity token (multi-user).
            switch profile.resolvedConnectMode {
            case .singleUser:
                await fetchSecretAndLaunchDCV()
            case .multiUser:
                await ensureSessionAndLaunchMultiUser(instanceId: instance.id)
            }

            // 7. Connected
            state = .connected
            connectedAt = Date()
            log.log(.tunnel, "Connected: 127.0.0.1:\(profile.localPort) → \(instance.id):\(profile.remotePort).")
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

    /// Open the tunnel and confirm the endpoint is genuinely usable before returning, so the caller
    /// can launch the viewer knowing the server answered. On a readiness miss (`DCVReadinessError`)
    /// it tears the tunnel down and re-establishes, up to `establishRetryAttempts` times with a
    /// per-attempt backoff, then rethrows the (retryable) error (#9, RVL-5). Cancellable.
    private func establishReadyTunnel(instanceId: String) async throws -> TunnelHandle {
        var attempt = 0
        while true {
            attempt += 1
            let handle = try await establishTunnel(instanceId: instanceId)
            do {
                try await assertEndpointReady(port: profile.localPort)
                return handle
            } catch let error as DCVReadinessError {
                await teardownTunnel()
                guard attempt <= timeouts.establishRetryAttempts else { throw error }
                log.log(.tunnel, "Endpoint not ready (\(describe(error))); re-establishing (attempt \(attempt))…")
                try await reconnectSleep(timeouts.establishRetryBackoff * attempt)
                try Task.checkCancellation()
            }
        }
    }

    /// Hard-gate the viewer launch (#9, RVL-1/2/3): first assert the SSM port-forward is actually
    /// listening locally (distinguishes a dead tunnel from a slow server), then poll the in-VM DCV
    /// server until it answers within the `dcvReady` budget. Throws a distinct `DCVReadinessError`
    /// on either failure so the viewer is never launched into an unverified endpoint.
    private func assertEndpointReady(port: Int) async throws {
        guard await tunnelListener.isListening(host: "127.0.0.1", port: port, timeout: timeouts.tunnelListen) else {
            throw DCVReadinessError.tunnelNotEstablished(port: port)
        }
        guard await readiness.waitUntilReady(port: port, timeout: timeouts.dcvReady, interval: timeouts.dcvReadyPollInterval) else {
            throw DCVReadinessError.dcvServerNotReady(port: port)
        }
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
            // Endpoint readiness was already hard-gated in establishReadyTunnel (#9, RVL-1), so the
            // server is confirmed answering here — just launch the viewer.
            let file = DCVConnectionFile(port: profile.localPort, password: pw)
            try await dcv.launch(connectionFile: file)
        } catch {
            warningMessage = describe(error)
        }
    }

    // MARK: - Multi-user connect (Phase F, CL-01..05)

    /// Multi-user auto-login: derive the caller's identity, ask the on-box agent to ensure that
    /// user's virtual session (over a transient second tunnel), then launch DCV with a
    /// presigned-identity token instead of a password.
    ///
    /// A multi-user host is **identity-only** (spec MU-00a): there is no `ec2-user`/shared
    /// fallback. Failures here are surfaced as a warning and keep the tunnel up, like the
    /// single-user path, but never silently downgrade the connection.
    private func ensureSessionAndLaunchMultiUser(instanceId: String) async {
        do {
            guard let creds = credentials else { throw AuthError.signInRequired }
            let presigner = STSPresigner(region: profile.resourceRegion)

            // 1. Resolve our own AWS identity -> Linux username (CL-01).
            let resolver = STSIdentityResolver(presigner: presigner)
            let (_, username) = try await resolver.resolve(credentials: creds)
            log.log(.auth, "Multi-user identity resolved to '\(username)'.")

            // 2. Ensure our virtual session exists, via the agent over a transient tunnel (R1/CL-02b).
            //    The agent tunnel is only needed for this one-shot call — DCV reaches its verifier
            //    locally on the box, not through the client — so we close it right after.
            let agentPort = profile.resolvedAgentRemotePort
            let agentHandle = try await openAgentTunnel(instanceId: instanceId, port: agentPort)
            let agent = WorkstationAgentClient(baseURL: URL(string: "http://127.0.0.1:\(agentPort)")!)
            let provisioned: WorkstationAgentClient.EnsureSessionResult
            do {
                provisioned = try await ensureSessionWithRetry(agent: agent, presigner: presigner, credentials: creds)
            } catch {
                // Always tear down the transient agent tunnel — otherwise a failed
                // ensure-session leaks the session-manager-plugin holding the agent port.
                await agentHandle.terminate()
                throw error
            }
            await agentHandle.terminate()
            log.log(.tunnel, "Agent ensured session '\(provisioned.sessionId)' for '\(provisioned.user)'.")

            // 3. Mint a FRESH token and auto-login with sessionid+authtoken (CL-03). Endpoint
            //    readiness was already hard-gated in establishReadyTunnel (#9, RVL-1).
            guard dcv.isViewerInstalled() else {
                warningMessage = DCVError.viewerNotInstalled.errorDescription
                return
            }
            let freshToken = presigner.presignedGetCallerIdentityURL(credentials: creds, now: Date())
            let file = DCVConnectionFile.multiUser(
                port: profile.localPort,
                user: provisioned.user,
                sessionId: provisioned.sessionId,
                authToken: freshToken
            )
            try await dcv.launch(connectionFile: file)
        } catch {
            warningMessage = describe(error)
            log.log(.tunnel, "Multi-user connect issue: \(describe(error))")
        }
    }

    /// Call `/ensure-session`, retrying transient connection failures while the freshly-opened
    /// agent tunnel becomes ready (the port-forward isn't listening the instant the handle returns).
    /// `ensureSession` is idempotent, so retrying is safe. A real agent response (401/5xx) is *not*
    /// transient and propagates immediately. A fresh token is minted per attempt to avoid expiry.
    private func ensureSessionWithRetry(
        agent: WorkstationAgentClient,
        presigner: STSPresigner,
        credentials: AWSCredentials,
        attempts: Int = 15
    ) async throws -> WorkstationAgentClient.EnsureSessionResult {
        var lastError: Error = AuthError.signInRequired
        for _ in 1...attempts {
            do {
                let token = presigner.presignedGetCallerIdentityURL(credentials: credentials, now: Date())
                return try await agent.ensureSession(authToken: token)
            } catch let agentError as WorkstationAgentClient.AgentError {
                throw agentError // the agent responded — not transient
            } catch {
                lastError = error
                try? await Task.sleep(for: .seconds(1))
            }
        }
        throw lastError
    }

    /// Open a transient SSM tunnel to the on-box agent (`port`→`port`). Not stored as the
    /// monitored handle — the caller terminates it once `/ensure-session` returns.
    private func openAgentTunnel(instanceId: String, port: Int) async throws -> TunnelHandle {
        let session = try await withReauth { [ssm, profile] creds in
            try await ssm.startSession(
                instanceId: instanceId,
                region: profile.resourceRegion,
                credentials: creds,
                localPort: port,
                remotePort: port
            )
        }
        let tunnel = self.tunnel
        let profile = self.profile
        return try await withStageTimeout("Opening agent tunnel", timeouts.tunnel) {
            try await tunnel.startTunnel(
                session: session,
                region: profile.resourceRegion,
                instanceId: instanceId,
                localPort: port,
                remotePort: port
            )
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
                    await teardownTunnel() // don't leave a half-open plugin process behind (F-13)
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
