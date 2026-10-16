import Darwin
import Foundation
import Observation

@MainActor
@Observable
public final class WebForwardsStateMachine {
    enum State: String { case off = "Off", starting = "Starting", on = "On", error = "Error" }
    private(set) var state: State = .off
    private(set) var errorMessage: String?
    private(set) var pacURL: URL?
    private(set) var profile: ConnectionProfile
    private(set) var pendingProfile: ConnectionProfile?
    private(set) var browserErrorMessage: String?
    private(set) var isOpeningBrowser = false
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
    private let log: ConnectionLog
    private var task: Task<Void, Never>?
    private var handle: TunnelHandle?
    private var key: SSHKeyMaterial?
    private var browserTask: Task<Void, Never>?

    public convenience init(profile: ConnectionProfile, settings: AppSettings, log: ConnectionLog,
                            authorization: AuthorizationSession? = nil) {
        self.init(profile: profile, settings: settings, log: log, auth: authorization ?? AWSAuthProvider())
    }

    init(profile: ConnectionProfile, settings: AppSettings = .default, log: ConnectionLog? = nil,
         auth: AuthProviding = AWSAuthProvider(), ec2: EC2Providing = EC2Service(),
         ssm: SSMProviding = SSMService(), instanceConnect: InstanceConnectProviding = InstanceConnectService(),
         keyGenerator: SSHKeyGenerating = SSHKeyGenerator(), tunnel: SSHTunnelProviding = SSHTunnel(),
         resolveUser: @escaping @Sendable (AWSCredentials, String) async throws -> String = { credentials, region in
             try await STSIdentityResolver(presigner: STSPresigner(region: region)).resolve(credentials: credentials).username
         },
         writePAC: @escaping @Sendable (WebForwardsConfiguration, UUID) throws -> URL = {
             try WebForwardsPAC.write(configuration: $0, profileID: $1)
         },
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         reconnectBackoff: Duration = .seconds(5), maxReconnectAttempts: Int = 3,
         timeouts: ConnectionTimeouts = .default) {
        self.profile = profile
        self.settings = settings
        self.log = log ?? ConnectionLog()
        self.auth = auth
        self.ec2 = ec2
        self.ssm = ssm
        self.instanceConnect = instanceConnect
        self.keyGenerator = keyGenerator
        self.tunnel = tunnel
        self.resolveUser = resolveUser
        self.writePAC = writePAC
        self.sleep = sleep
        self.reconnectBackoff = reconnectBackoff
        self.maxReconnectAttempts = maxReconnectAttempts
        self.timeouts = timeouts
        AppQuitHandler.shared.register { [weak self] in self?.terminateForQuit() }
    }

    var isActive: Bool { handle?.isActive == true }

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
        self.profile = profile
        pendingProfile = nil
    }

    func openBrowser(using browser: BrowserOpening) {
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

    func awaitBrowserOpened() async { await browserTask?.value }

    func applyPendingConfiguration() async {
        guard let pendingProfile, !isOpeningBrowser else { return }
        stop()
        await awaitStopped()
        profile = pendingProfile
        self.pendingProfile = nil
        pacURL = nil
        connect()
    }

    func connect() {
        guard task == nil, profile.webForwards?.enabled == true else { return }
        errorMessage = nil
        state = .starting
        task = Task {
            await self.run()
            self.task = nil
        }
    }

    func stop() {
        browserTask?.cancel()
        task?.cancel()
        state = .off
        errorMessage = nil
    }

    func awaitStopped() async { await task?.value }

    func preparePAC() {
        guard let configuration = profile.webForwards else { return }
        do { pacURL = try writePAC(configuration, profile.id) }
        catch { errorMessage = error.localizedDescription }
    }

    func terminateForQuit() {
        task?.cancel()
        if let pid = handle?.processIdentifier, pid > 0 {
            kill(pid, SIGTERM)
            usleep(300_000)
            kill(pid, SIGKILL)
        }
        key?.remove()
        key = nil
    }

    private func run() async {
        var reconnecting = false
        var attempt = 0
        while !Task.isCancelled {
            do {
                if reconnecting {
                    guard settings.autoReconnect, attempt < maxReconnectAttempts else {
                        throw WebForwardsError.sshNotReady
                    }
                    attempt += 1
                    state = .starting
                    try await sleep(reconnectBackoff)
                }
                try await establish()
                try Task.checkCancellation()
                state = .on
                attempt = 0
                log.log(.tunnel, "Web forwards connected.")
                guard let handle else { throw WebForwardsError.sshNotReady }
                var drops = handle.onDisconnect.makeAsyncIterator()
                let reason = await drops.next()
                await cleanup()
                try Task.checkCancellation()
                guard case .processExited = reason else { state = .off; return }
                if !settings.autoReconnect { throw WebForwardsError.sshNotReady }
                reconnecting = true
                log.log(.tunnel, "Web forwards dropped; reconnecting with a fresh SSH key.")
            } catch {
                await cleanup()
                if Task.isCancelled || error is CancellationError { state = .off; return }
                if !reconnecting || attempt >= maxReconnectAttempts || !settings.autoReconnect {
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

    private func establish() async throws {
        guard profile.isConfigured, let configuration = profile.webForwards,
              configuration.enabled else {
            throw WebForwardsError.invalidConfiguration("Configure the workstation and enable web forwards in Settings.")
        }
        if let error = ProfileEditorValidation.webForwardsError(configuration) {
            throw WebForwardsError.invalidConfiguration(error)
        }
        let profile = self.profile
        let credentials = try await withStageTimeout("Web forwards sign-in", timeouts.authenticate) { [auth] in
            try await auth.authenticate(profile: profile)
        }
        var instance = try await auth.authorized(profile: profile, credentials: credentials) { credentials in
            try await withStageTimeout("Finding workstation", timeouts.resolve) { [ec2] in
                try await ec2.resolveInstance(tagKey: profile.instanceTagKey, tagValue: profile.instanceTagValue,
                                             region: profile.resourceRegion, credentials: credentials)
            }
        }
        guard !instance.state.isTerminal else { throw EC2Error.instanceTerminated(instanceId: instance.id) }
        if instance.state != .running {
            let instanceId = instance.id
            instance = try await auth.authorized(profile: profile, credentials: credentials) { credentials in
                try await withStageTimeout("Starting workstation", timeouts.start) { [ec2, timeouts] in
                    try await ec2.startInstance(instanceId: instanceId, region: profile.resourceRegion, credentials: credentials)
                    return try await ec2.pollUntilRunning(instanceId: instanceId, region: profile.resourceRegion,
                        credentials: credentials, timeout: timeouts.start, interval: timeouts.startPollInterval)
                }
            }
        }
        try await auth.authorized(profile: profile, credentials: credentials) { credentials in
            try await ssm.waitForSSMOnline(instanceId: instance.id, region: profile.resourceRegion,
                credentials: credentials, timeout: timeouts.ssm, interval: timeouts.ssmPollInterval)
        }
        let configuredUser = configuration.sshUser?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let user = try await auth.authorized(profile: profile, credentials: credentials) { credentials in
            configuredUser.isEmpty ? try await resolveUser(credentials, profile.resourceRegion) : configuredUser
        }
        pacURL = try writePAC(configuration, profile.id)
        try Task.checkCancellation()
        key = try await keyGenerator.generate()
        try Task.checkCancellation()
        guard let key else { throw WebForwardsError.keyGenerationFailed }
        let instanceId = instance.id
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
    }

    private func cleanup() async {
        let previous = handle
        handle = nil
        await previous?.terminate()
        key?.remove()
        key = nil
    }
}