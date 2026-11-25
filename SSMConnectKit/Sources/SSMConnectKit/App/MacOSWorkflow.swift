import AppKit
import Darwin
import Foundation
import SSMConnectAWSClient

// The macOS composition of the shared workflows: the platform port, the services on SSM
// Connect's own AWS client as defaults, and the state machines' existing initializers, so
// callers in this package and the app shell construct them exactly as before.

extension ClientAuthProvider {
    /// SSO sign-in for the macOS app: the device authorization page opens in the default browser.
    package static func macOS() -> ClientAuthProvider {
        ClientAuthProvider(openURL: { url in Task { @MainActor in NSWorkspace.shared.open(url) } })
    }
}

extension WorkflowPlatform {
    /// macOS: POSIX signals for quit, and SSM Connect's AWS client for error text, the
    /// authorization rules and STS.
    package static let macOS = WorkflowPlatform(
        terminateChildProcess: { pid in
            guard pid > 0 else { return }
            kill(pid, SIGTERM)
            usleep(300_000) // 0.3s grace
            kill(pid, SIGKILL)
        },
        describeError: { AWSErrorText.message(for: $0) },
        isRejectedAuthorization: { ClientAuthProvider.isRejectedAuthorization($0) },
        isPermissionDenied: { ClientAuthProvider.isPermissionDenied($0) },
        isExpiredCredentials: { ConnectionStateMachine.defaultExpiredCredentialsCheck($0) },
        resolveUsername: { credentials, region in
            try await STSIdentityResolver(presigner: STSPresigner(region: region)).resolve(credentials: credentials).username
        },
        identityToken: { credentials, region in
            try STSPresigner(region: region).presignedGetCallerIdentityURL(credentials: credentials, now: Date())
        },
        ownerOnlyFiles: .posix
    )

    /// A copy with a different username lookup.
    package func with(resolveUsername lookup: @escaping @Sendable (AWSCredentials, String) async throws -> String) -> WorkflowPlatform {
        var copy = self
        copy.resolveUsername = lookup
        return copy
    }

    /// `macOS` with a different expired-credentials check.
    package func with(isExpiredCredentials check: @escaping @Sendable (Error) -> Bool) -> WorkflowPlatform {
        var copy = self
        copy.isExpiredCredentials = check
        return copy
    }
}

extension ConnectionStateMachine {
    /// Public entry point for the app shell: a state machine for a profile + settings, wired with
    /// the default production dependencies. The full dependency-injecting init stays internal so the
    /// provider protocols don't leak into the package's public API.
    public convenience init(profile: ConnectionProfile, settings: AppSettings) {
        self.init(profile: profile, settings: settings, timeouts: .default)
    }

    public convenience init(profile: ConnectionProfile, settings: AppSettings, authorization: AuthorizationSession) {
        self.init(authProvider: authorization, profile: profile, settings: settings)
    }

    /// The macOS services as defaults, for the app and the tests.
    package convenience init(
        authProvider: AuthProviding = ClientAuthProvider.macOS(),
        ec2: EC2Providing = ClientEC2Service(),
        ssm: SSMProviding = ClientSSMService(),
        tunnel: TunnelProvider = BundledPluginTunnel(),
        secrets: SecretsProviding = ClientSecretsService(),
        dcv: DCVLaunching = DCVLauncher(),
        readiness: WorkstationReadinessProbing = HTTPSReadinessProbe(),
        tunnelListener: TunnelListenerProbing = TCPListenerProbe(),
        instanceIds: InstanceIdPersisting = UserDefaultsInstanceIdStore(),
        clipboard: ClipboardManager = ClipboardManager(pasteboard: NSPasteboardAdapter()),
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
        self.init(platform: WorkflowPlatform.macOS.with(isExpiredCredentials: isExpiredCredentials),
                  authProvider: authProvider, ec2: ec2, ssm: ssm, tunnel: tunnel, secrets: secrets, dcv: dcv,
                  readiness: readiness, tunnelListener: tunnelListener, instanceIds: instanceIds,
                  clipboard: clipboard, log: log ?? .unified(), notifier: notifier, profile: profile,
                  settings: settings, timeouts: timeouts, maxReconnectAttempts: maxReconnectAttempts,
                  reconnectBackoff: reconnectBackoff, reconnectSleep: reconnectSleep)
    }

    /// Default check for expired or unauthorized SSO credentials across the AWS services: the
    /// rejected-authorization rules, or an expired-token or unauthorized-access type name.
    package nonisolated static func defaultExpiredCredentialsCheck(_ error: Error) -> Bool {
        if ClientAuthProvider.isRejectedAuthorization(error) { return true }
        let description = (error as? AWSServiceError)?.typeName ?? String(reflecting: error)
        return description.contains("ExpiredToken")
            || description.contains("UnauthorizedAccess")
            || description.contains("ExpiredTokenException")
    }
}

extension AuthorizationSession {
    public convenience init(profile: ConnectionProfile) {
        self.init(profile: profile, provider: ClientAuthProvider.macOS())
    }

    package convenience init(profile: ConnectionProfile, provider: AuthProviding,
                             now: @escaping @Sendable () -> Date = { Date() },
                             sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                             leadTime: TimeInterval = 300) {
        self.init(platform: .macOS, profile: profile, provider: provider, now: now, sleep: sleep, leadTime: leadTime)
    }
}

extension WebForwardsStateMachine {
    public convenience init(profile: ConnectionProfile, settings: AppSettings, log: ConnectionLog,
                            authorization: AuthorizationSession? = nil) {
        self.init(profile: profile, settings: settings, log: log, auth: authorization ?? ClientAuthProvider.macOS())
    }

    package convenience init(profile: ConnectionProfile, settings: AppSettings = .default, log: ConnectionLog? = nil,
         auth: AuthProviding = ClientAuthProvider.macOS(), ec2: EC2Providing = ClientEC2Service(),
         ssm: SSMProviding = ClientSSMService(), instanceConnect: InstanceConnectProviding = ClientInstanceConnectService(),
         keyGenerator: SSHKeyGenerating = SSHKeyGenerator(), tunnel: SSHTunnelProviding = SSHTunnel(),
         resolveUser: @escaping @Sendable (AWSCredentials, String) async throws -> String = WorkflowPlatform.macOS.resolveUsername,
         writePAC: @escaping @Sendable (WebForwardsConfiguration, UUID) throws -> URL = {
             try WebForwardsPAC.write(configuration: $0, profileID: $1)
         },
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         reconnectBackoff: Duration = .seconds(5), maxReconnectAttempts: Int = 3,
         timeouts: ConnectionTimeouts = .default, recoveryBudget: Duration = .seconds(30 * 60)) {
        self.init(platform: WorkflowPlatform.macOS.with(resolveUsername: resolveUser), profile: profile,
                  settings: settings, log: log ?? .unified(), auth: auth, ec2: ec2, ssm: ssm,
                  instanceConnect: instanceConnect, keyGenerator: keyGenerator, tunnel: tunnel, writePAC: writePAC,
                  sleep: sleep, reconnectBackoff: reconnectBackoff, maxReconnectAttempts: maxReconnectAttempts,
                  timeouts: timeouts, recoveryBudget: recoveryBudget)
    }
}


extension RemoteDevelopmentStateMachine {
    public convenience init(profile: ConnectionProfile, authorization: AuthorizationSession? = nil) {
        self.init(profile: profile, root: BrowserPrivateFiles.root.deletingLastPathComponent()
            .appendingPathComponent("RemoteAccess"), configURL: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh/config"),
            auth: authorization ?? ClientAuthProvider.macOS(), resumeStore: UserDefaults.standard)
    }

    package convenience init(profile: ConnectionProfile, root: URL, configURL: URL, auth: AuthProviding = ClientAuthProvider.macOS(),
         ec2: EC2Providing = ClientEC2Service(), ssm: SSMProviding = ClientSSMService(), keyGenerator: SSHKeyGenerating = SSHKeyGenerator(),
         helperPath: @escaping () -> String = { Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ssm-connect-proxy").path },
         pluginPath: @escaping () -> String? = BundledPluginTunnel.defaultPluginPath,
         editorPath: @escaping () -> String? = {
             NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode")?
                 .appendingPathComponent("Contents/Resources/app/bin/code").path
         }, editorPreflight: @escaping (String) async throws -> Void = RemoteEditorPreflight.check,
         ownerIdentity: @escaping () -> (pid: Int32, launchDate: Date, bundleID: String)? = {
             ApplicationLeaseOwner().current().map { ($0.pid, $0.launchDate, $0.bundleID) }
         },
         now: @escaping () -> Date = { Date() },
         renewalSleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         writeLease: @escaping (Data, URL) throws -> Void = { try BrowserPrivateFiles.write($0, to: $1) },
         launchEditor: @escaping (String, [String]) async throws -> Void = {
             _ = try await RemoteEditorPreflight.run($0, arguments: $1)
         }, resumeStore: (any KeyValueStoring)? = nil,
         recoverySleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         recoveryBudget: Duration = .seconds(30 * 60),
         leaseOwnerIsActive: @escaping (RemoteSSHLease) -> Bool = { $0.ownerProcessIsActive },
         sshAvailable: @escaping () -> Bool = { FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh") }) {
        self.init(platform: .macOS, profile: profile, root: root, configURL: configURL, auth: auth, ec2: ec2, ssm: ssm,
                  keyGenerator: keyGenerator, helperPath: helperPath, pluginPath: pluginPath, editorPath: editorPath,
                  editorPreflight: editorPreflight, ownerIdentity: ownerIdentity, now: now, renewalSleep: renewalSleep,
                  writeLease: writeLease, launchEditor: launchEditor, resumeStore: resumeStore,
                  recoverySleep: recoverySleep, recoveryBudget: recoveryBudget, leaseOwnerIsActive: leaseOwnerIsActive,
                  sshAvailable: sshAvailable)
    }
}

extension ProfileStore {
    public convenience init(defaults: UserDefaults = .standard) {
        self.init(store: defaults)
    }

    /// The macOS profile file access, for the app and the tests.
    package convenience init(store: any KeyValueStoring) {
        self.init(store: store, files: POSIXProfileFiles())
    }
}
