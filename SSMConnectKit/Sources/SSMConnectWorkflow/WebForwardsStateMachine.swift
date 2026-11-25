import Foundation
import SSMConnectDomain
import Observation

@MainActor
@Observable
public final class WebForwardsStateMachine {
    package enum State: String { case off = "Off", starting = "Starting", on = "On", error = "Error" }
    package private(set) var state: State = .off
    package private(set) var errorMessage: String?
    package private(set) var pacURL: URL?
    package private(set) var profile: ConnectionProfile
    package private(set) var pendingProfile: ConnectionProfile?
    package private(set) var browserErrorMessage: String?
    package private(set) var isOpeningBrowser = false
    package private(set) var pendingReplacement: EditorReplacement?
    package private(set) var recoveryMessage: String?
    private var settings: AppSettings
    private let auth: AuthProviding
    private let ec2: EC2Providing
    private let ssm: SSMProviding
    private let instanceConnect: InstanceConnectProviding
    private let keyGenerator: SSHKeyGenerating
    private let tunnel: SSHTunnelProviding
    private let resolveUser: @Sendable (AWSCredentials, String) async throws -> String
    private let writePAC: @Sendable (WebForwardsConfiguration, UUID) throws -> URL
    private let sleep: @Sendable (Duration) async throws -> Void
    private let reconnectBackoff: Duration
    private let maxReconnectAttempts: Int
    private let timeouts: ConnectionTimeouts
    private let recoveryBudget: Duration
    private let log: ConnectionLog
    private let platform: WorkflowPlatform
    private var task: Task<Void, Never>?
    private var handle: TunnelHandle?
    private var key: SSHKeyMaterial?
    private var browserTask: Task<Void, Never>?
    private var boundTarget: (instanceID: String, user: String)?
    private var approvedInstanceID: String?

    package init(platform: WorkflowPlatform, profile: ConnectionProfile, settings: AppSettings = .default, log: ConnectionLog,
         auth: AuthProviding, ec2: EC2Providing, ssm: SSMProviding, instanceConnect: InstanceConnectProviding,
         keyGenerator: SSHKeyGenerating, tunnel: SSHTunnelProviding,
         writePAC: @escaping @Sendable (WebForwardsConfiguration, UUID) throws -> URL,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         reconnectBackoff: Duration = .seconds(5), maxReconnectAttempts: Int = 3,
         timeouts: ConnectionTimeouts = .default, recoveryBudget: Duration = .seconds(30 * 60),
         quit: AppQuitHandler = .shared) {
        self.platform = platform
        self.profile = profile
        self.settings = settings
        self.log = log
        self.auth = auth
        self.ec2 = ec2
        self.ssm = ssm
        self.instanceConnect = instanceConnect
        self.keyGenerator = keyGenerator
        self.tunnel = tunnel
        self.resolveUser = platform.resolveUsername
        self.writePAC = writePAC
        self.sleep = sleep
        self.reconnectBackoff = reconnectBackoff
        self.maxReconnectAttempts = maxReconnectAttempts
        self.timeouts = timeouts
        self.recoveryBudget = recoveryBudget
        quit.register { [weak self] in self?.terminateForQuit() }
    }

    package var isActive: Bool { handle?.isActive == true }

    public func apply(profile: ConnectionProfile, settings: AppSettings) {
        self.settings = settings
        if task != nil {
            var transportProfile = profile
            transportProfile.webForwards?.browser = self.profile.webForwards?.browser
            transportProfile.webForwards?.browserMode = self.profile.webForwards?.browserMode
            transportProfile.webForwards?.browserProfilePath = self.profile.webForwards?.browserProfilePath
            if transportProfile != self.profile {
                pendingProfile = profile
                if state == .starting, auth is AuthorizationSession {
                    browserTask?.cancel()
                    task?.cancel()
                }
                return
            }
        }
        if self.profile != profile { pacURL = nil }
        if !self.profile.hasSameWorkstation(as: profile) {
            boundTarget = nil
            approvedInstanceID = nil
            pendingReplacement = nil
        }
        self.profile = profile
        pendingProfile = nil
    }

    package func openBrowser(using browser: BrowserOpening) {
        guard browserTask == nil else { return }
        browserErrorMessage = nil
        isOpeningBrowser = true
        browserTask = Task {
            defer { self.browserTask = nil; self.isOpeningBrowser = false }
            do {
                guard self.pendingProfile == nil else { throw BrowserBootstrapError.pendingChanges }
                try browser.preflight(profile: self.profile)
                self.connect()
                while self.state == .starting {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .milliseconds(50))
                }
                try Task.checkCancellation()
                guard self.state == .on, self.isActive else {
                    throw WebForwardsError.invalidConfiguration(self.errorMessage ?? "Web forwards are off.")
                }
                try await browser.open(profile: self.profile)
            } catch {
                if !Task.isCancelled { self.browserErrorMessage = error.localizedDescription }
            }
        }
    }

    package func awaitBrowserOpened() async { await browserTask?.value }

    package func applyPendingConfiguration() async {
        guard let pendingProfile, !isOpeningBrowser else { return }
        stop()
        await awaitStopped()
        if !profile.hasSameWorkstation(as: pendingProfile) { boundTarget = nil }
        profile = pendingProfile
        self.pendingProfile = nil
        pacURL = nil
        connect()
    }

    package func connect() {
        guard task == nil else { return }
        approvedInstanceID = nil
        begin(recovering: false)
    }

    private func begin(recovering: Bool) {
        guard task == nil, profile.webForwards?.enabled == true else { return }
        errorMessage = nil
        recoveryMessage = nil
        pendingReplacement = nil
        state = .starting
        task = Task {
            await self.run(initialRecovery: recovering)
            self.task = nil
        }
    }

    package func stop() {
        browserTask?.cancel()
        task?.cancel()
        state = .off
        errorMessage = nil
        pendingReplacement = nil
        approvedInstanceID = nil
        recoveryMessage = nil
    }

    package func approveReplacement(_ id: UUID) {
        guard task == nil, let candidate = pendingReplacement, candidate.id == id,
              candidate.profile.hasSameWorkstation(as: profile) else {
            errorMessage = RemoteSSHError.targetChanged.localizedDescription
            return
        }
        approvedInstanceID = candidate.instanceID
        begin(recovering: true)
    }

    package func awaitStopped() async { await task?.value }

    package func preparePAC() {
        guard let configuration = profile.webForwards else { return }
        do { pacURL = try writePAC(configuration, profile.id) }
        catch { errorMessage = error.localizedDescription }
    }

    package func terminateForQuit() {
        task?.cancel()
        if let pid = handle?.processIdentifier, pid > 0 {
            platform.terminateChildProcess(pid)
        }
        key?.remove()
        key = nil
    }

    private func run(initialRecovery: Bool) async {
        // Capability preflight (AC-25): before any AWS call, key, process or PAC write.
        if let missing = tunnel.unavailableCapabilities().first {
            state = .error
            errorMessage = CapabilityError.missing(missing).errorDescription
            return
        }
        var reconnecting = false
        var recovering = initialRecovery
        var readinessWait = false
        var deadline: ContinuousClock.Instant? = recovering ? ContinuousClock.now.advanced(by: recoveryBudget) : nil
        var attempt = 0
        while !Task.isCancelled {
            do {
                if reconnecting {
                    guard settings.autoReconnect, readinessWait || attempt < maxReconnectAttempts else {
                        throw WebForwardsError.sshNotReady
                    }
                    attempt += 1
                    state = .starting
                }
                let delay: Duration? = reconnecting ? (readinessWait ? .seconds(15) : reconnectBackoff) : nil
                let recoveryAttempt = recovering
                if let deadline {
                    let remaining = ContinuousClock.now.duration(to: deadline)
                    guard remaining > .zero else { throw StageTimeoutError(stage: "Native forwarding recovery") }
                    try await withStageTimeout("Native forwarding recovery", remaining) {
                        if let delay { try await self.sleep(delay) }
                        try await self.establish(recovering: recoveryAttempt)
                    }
                } else {
                    if let delay { try await sleep(delay) }
                    try await establish(recovering: recoveryAttempt)
                }
                try Task.checkCancellation()
                state = .on
                attempt = 0
                readinessWait = false
                recoveryMessage = nil
                approvedInstanceID = nil
                log.log(.tunnel, "Web forwards connected.")
                guard let handle else { throw WebForwardsError.sshNotReady }
                var drops = handle.onDisconnect.makeAsyncIterator()
                let reason = await drops.next()
                await cleanup()
                try Task.checkCancellation()
                guard case .processExited = reason else { state = .off; return }
                if !settings.autoReconnect { throw WebForwardsError.sshNotReady }
                reconnecting = true
                recovering = true
                deadline = ContinuousClock.now.advanced(by: recoveryBudget)
                log.log(.tunnel, "Web forwards dropped; reconnecting with a fresh SSH key.")
            } catch {
                await cleanup()
                if Task.isCancelled || error is CancellationError { state = .off; return }
                let budgetExpired = deadline.map { ContinuousClock.now >= $0 } ?? false
                if recovering, !budgetExpired, settings.autoReconnect, WorkstationRecoveryReadiness.isPending(error) {
                    reconnecting = true
                    readinessWait = true
                    attempt = 0
                    state = .starting
                    recoveryMessage = "Waiting for the workstation and SSM (up to 30 minutes). Turn Off Web Forwards cancels; stopped instances are not started."
                    continue
                }
                let terminal = error is EC2Error || error is RemoteSSHError || error is AuthError
                    || platform.isRejectedAuthorization(error)
                    || platform.isPermissionDenied(error)
                    || (auth as? AuthorizationSession)?.status == .signInRequired
                if !reconnecting || attempt >= maxReconnectAttempts || !settings.autoReconnect || terminal || budgetExpired {
                    recoveryMessage = nil
                    errorMessage = error.localizedDescription
                    state = .error
                    log.log(.tunnel, "Web forwards could not connect.")
                    return
                }
            }
        }
        await cleanup()
        state = .off
    }

    private func establish(recovering: Bool) async throws {
        guard profile.isConfigured, let configuration = profile.webForwards,
              configuration.enabled else {
            throw WebForwardsError.invalidConfiguration("Configure the workstation and enable web forwards in Settings.")
        }
        if let error = ProfileEditorValidation.webForwardsError(configuration) {
            throw WebForwardsError.invalidConfiguration(error)
        }
        let profile = self.profile
        let credentials = try await withStageTimeout("Web forwards sign-in", timeouts.authenticate) { [auth] in
            try await (recovering ? auth.refreshIfNeeded(profile: profile) : auth.authenticate(profile: profile))
        }
        var instance = try await auth.authorized(profile: profile, credentials: credentials) { credentials in
            try await withStageTimeout("Finding workstation", timeouts.resolve) { [ec2] in
                try await ec2.resolveInstance(tagKey: profile.instanceTagKey, tagValue: profile.instanceTagValue,
                                             region: profile.resourceRegion, credentials: credentials)
            }
        }
        if let boundTarget, instance.id != boundTarget.instanceID, approvedInstanceID != instance.id {
            pendingReplacement = EditorReplacement(profile: profile, previousInstanceID: boundTarget.instanceID,
                                                   instanceID: instance.id, user: boundTarget.user)
            throw RemoteSSHError.replacementApprovalRequired
        }
        guard !instance.state.isTerminal else { throw EC2Error.instanceTerminated(instanceId: instance.id) }
        if instance.state != .running {
            guard !recovering else { throw RemoteSSHError.workstationNotReady }
            let instanceId = instance.id
            instance = try await auth.authorized(profile: profile, credentials: credentials) { credentials in
                try await withStageTimeout("Starting workstation", timeouts.start) { [ec2, timeouts] in
                    try await ec2.startInstance(instanceId: instanceId, region: profile.resourceRegion, credentials: credentials)
                    return try await ec2.pollUntilRunning(instanceId: instanceId, region: profile.resourceRegion,
                        credentials: credentials, timeout: timeouts.start, interval: timeouts.startPollInterval)
                }
            }
        }
        let instanceId = instance.id
        let ssmBudget = recovering ? min(timeouts.ssm, .seconds(30)) : timeouts.ssm
        try await auth.authorized(profile: profile, credentials: credentials) { credentials in
            try await withStageTimeout("Web forwards SSM readiness", ssmBudget) { [ssm, timeouts] in
                try await ssm.waitForSSMOnline(instanceId: instanceId, region: profile.resourceRegion,
                    credentials: credentials, timeout: ssmBudget, interval: timeouts.ssmPollInterval)
            }
        }
        let configuredUser = configuration.sshUser?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let user = try await auth.authorized(profile: profile, credentials: credentials) { credentials in
            configuredUser.isEmpty ? try await resolveUser(credentials, profile.resourceRegion) : configuredUser
        }
        if let boundTarget, user != boundTarget.user { throw RemoteSSHError.targetChanged }
        recoveryMessage = recovering ? "Preparing native forwarding; SSM readiness does not certify the remote home or services." : nil
        pacURL = try writePAC(configuration, profile.id)
        try Task.checkCancellation()
        key = try await keyGenerator.generate()
        try Task.checkCancellation()
        guard let key else { throw WebForwardsError.keyGenerationFailed }
        try await auth.authorized(profile: profile, credentials: credentials) { credentials in
            try await withStageTimeout("Authorizing SSH key", .seconds(20)) { [instanceConnect] in
                try await instanceConnect.sendPublicKey(instanceId: instanceId, user: user, publicKey: key.publicKey,
                    region: profile.resourceRegion, credentials: credentials)
            }
        }
        try Task.checkCancellation()
        let session = try await auth.authorized(profile: profile, credentials: credentials) { credentials in
            try await withStageTimeout("Opening SSH session", .seconds(20)) { [ssm] in
                try await ssm.startSSHSession(instanceId: instanceId, region: profile.resourceRegion, credentials: credentials)
            }
        }
        try Task.checkCancellation()
        handle = try await tunnel.start(session: session, region: profile.resourceRegion, instanceId: instanceId,
            user: user, keyPath: key.privateKeyPath, configuration: configuration)
        boundTarget = (instanceId, user)
    }

    private func cleanup() async {
        let previous = handle
        handle = nil
        await previous?.terminate()
        key?.remove()
        key = nil
    }
}