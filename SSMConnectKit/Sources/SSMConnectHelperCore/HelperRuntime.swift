import Foundation
import SSMConnectDomain
import SSMConnectHelperProtocol
import SSMConnectWorkflow

/// What the helper composes the shared workflows from: production services on Windows and
/// Linux, fakes in tests.
package struct HelperServices {
    package var platform: WorkflowPlatform
    package var auth: AuthProviding
    package var ec2: EC2Providing
    package var ssm: SSMProviding
    package var secrets: SecretsProviding
    package var instanceConnect: InstanceConnectProviding
    package var tunnel: TunnelProvider
    package var sshTunnel: SSHTunnelProviding
    package var keyGenerator: SSHKeyGenerating
    package var dcv: DCVLaunching
    package var readiness: WorkstationReadinessProbing
    package var tunnelListener: TunnelListenerProbing
    package var instanceIds: InstanceIdPersisting
    package var keyValues: any KeyValueStoring
    package var profileFiles: ProfileFileAccessing
    package var pasteboard: Pasteboard
    package var notifier: Notifying
    package var writePAC: @Sendable (WebForwardsConfiguration, UUID) throws -> URL
    package var editor: EditorServices
    package var browserSupported: @MainActor (ConnectionProfile) -> Bool
    package var requests: ShellRequests

    /// The editor workflow's platform pieces.
    package struct EditorServices {
        package var root: URL
        package var sshConfig: URL
        package var helperPath: () -> String
        package var pluginPath: () -> String?
        package var editorPath: () -> String?
        package var editorPreflight: (String) async throws -> Void
        package var owner: LeaseOwnerProbing
        package var sshAvailable: () -> Bool

        package init(root: URL, sshConfig: URL, helperPath: @escaping () -> String, pluginPath: @escaping () -> String?,
                     editorPath: @escaping () -> String?, editorPreflight: @escaping (String) async throws -> Void,
                     owner: LeaseOwnerProbing, sshAvailable: @escaping () -> Bool) {
            self.root = root
            self.sshConfig = sshConfig
            self.helperPath = helperPath
            self.pluginPath = pluginPath
            self.editorPath = editorPath
            self.editorPreflight = editorPreflight
            self.owner = owner
            self.sshAvailable = sshAvailable
        }
    }

    package init(platform: WorkflowPlatform, auth: AuthProviding, ec2: EC2Providing, ssm: SSMProviding,
                 secrets: SecretsProviding, instanceConnect: InstanceConnectProviding, tunnel: TunnelProvider,
                 sshTunnel: SSHTunnelProviding, keyGenerator: SSHKeyGenerating, dcv: DCVLaunching,
                 readiness: WorkstationReadinessProbing, tunnelListener: TunnelListenerProbing,
                 instanceIds: InstanceIdPersisting, keyValues: any KeyValueStoring, profileFiles: ProfileFileAccessing,
                 pasteboard: Pasteboard, notifier: Notifying,
                 writePAC: @escaping @Sendable (WebForwardsConfiguration, UUID) throws -> URL,
                 editor: EditorServices, browserSupported: @escaping @MainActor (ConnectionProfile) -> Bool,
                 requests: ShellRequests) {
        self.platform = platform
        self.auth = auth
        self.ec2 = ec2
        self.ssm = ssm
        self.secrets = secrets
        self.instanceConnect = instanceConnect
        self.tunnel = tunnel
        self.sshTunnel = sshTunnel
        self.keyGenerator = keyGenerator
        self.dcv = dcv
        self.readiness = readiness
        self.tunnelListener = tunnelListener
        self.instanceIds = instanceIds
        self.keyValues = keyValues
        self.profileFiles = profileFiles
        self.pasteboard = pasteboard
        self.notifier = notifier
        self.writePAC = writePAC
        self.editor = editor
        self.browserSupported = browserSupported
        self.requests = requests
    }
}

/// The helper's workflows and its command table. Each shell action is one command, mapped to
/// the shared workflow that owns it; the workflow's state streams to the shell as ordered events.
/// The core alone decides: a command is refused before any effect when the active profile cannot
/// run it, and each admitted command ends in exactly one terminal result.
@MainActor package final class HelperRuntime {
    package let profiles: ProfileStore
    package let authorization: AuthorizationSession
    package let connection: ConnectionStateMachine
    package let web: WebForwardsStateMachine
    package let editor: RemoteDevelopmentStateMachine
    private let services: HelperServices
    private let browser: ShellBrowserOpener
    private let pollInterval: Duration

    package init(services: HelperServices, pollInterval: Duration = .milliseconds(50)) {
        self.services = services
        self.pollInterval = pollInterval
        profiles = ProfileStore(store: services.keyValues, files: services.profileFiles)
        let profile = profiles.activeProfile
        authorization = AuthorizationSession(platform: services.platform, profile: profile, provider: services.auth)
        let log = ConnectionLog()
        connection = ConnectionStateMachine(platform: services.platform, authProvider: authorization, ec2: services.ec2,
            ssm: services.ssm, tunnel: services.tunnel, secrets: services.secrets, dcv: services.dcv,
            readiness: services.readiness, tunnelListener: services.tunnelListener, instanceIds: services.instanceIds,
            clipboard: ClipboardManager(pasteboard: services.pasteboard), log: log, notifier: services.notifier,
            profile: profile, settings: profiles.settings)
        web = WebForwardsStateMachine(platform: services.platform, profile: profile, settings: profiles.settings, log: log,
            auth: authorization, ec2: services.ec2, ssm: services.ssm, instanceConnect: services.instanceConnect,
            keyGenerator: services.keyGenerator, tunnel: services.sshTunnel, writePAC: services.writePAC)
        let editorServices = services.editor
        let requests = services.requests
        editor = RemoteDevelopmentStateMachine(platform: services.platform, profile: profile, root: editorServices.root,
            configURL: editorServices.sshConfig, auth: authorization, ec2: services.ec2, ssm: services.ssm,
            keyGenerator: services.keyGenerator, helperPath: editorServices.helperPath, pluginPath: editorServices.pluginPath,
            editorPath: editorServices.editorPath, editorPreflight: editorServices.editorPreflight,
            ownerIdentity: { editorServices.owner.current().map { ($0.pid, $0.launchDate, $0.bundleID) } },
            launchEditor: { path, arguments in
                requests.launch("vsCode", fields: ["path": path, "arguments": arguments.joined(separator: "\u{1F}")])
            },
            resumeStore: services.keyValues,
            leaseOwnerIsActive: { editorServices.owner.isActive($0.owner) }, sshAvailable: editorServices.sshAvailable)
        browser = ShellBrowserOpener(requests: services.requests, isSupported: services.browserSupported)
    }

    /// The command table for the helper session.
    package nonisolated func commands() -> [String: CommandSpec] {
        func spec(_ workflow: String, admit: @escaping @Sendable @MainActor ([String: String]) throws -> Void = { _ in },
                  _ run: @escaping @Sendable @MainActor ([String: String], EventSink) async throws -> [String: String]) -> CommandSpec {
            CommandSpec(workflow: workflow,
                        admit: { arguments in try await admit(arguments) },
                        run: { arguments, events in try await run(arguments, events) })
        }
        return [
            "listProfiles": spec("profiles") { _, _ in try self.listProfiles() },
            "saveProfile": spec("profiles") { arguments, _ in try self.saveProfile(arguments) },
            "setActiveProfile": spec("profiles") { arguments, _ in try self.setActiveProfile(arguments) },
            "importProfile": spec("profiles") { arguments, _ in try self.importProfile(arguments) },
            "signIn": spec("authorization", admit: { _ in try self.requireConfigured() }) { _, _ in try await self.signIn() },
            "connect": spec("desktop", admit: { _ in try self.requireConfigured() }) { _, events in try await self.connect(events) },
            "disconnect": spec("desktop") { _, events in try await self.disconnect(events) },
            "stopWorkstation": spec("desktop", admit: { _ in try self.requireConnected() }) { _, events in
                try await self.stopWorkstation(events)
            },
            "installEditorSetup": spec("editor") { arguments, _ in try self.installEditorSetup(arguments) },
            "openEditor": spec("editor", admit: { _ in try self.requireEditor() }) { _, events in try await self.openEditor(events) },
            "startWebForwards": spec("web", admit: { _ in try self.requireWebForwards() }) { _, events in
                try await self.startWebForwards(events)
            },
            "stopWebForwards": spec("web") { _, events in try await self.stopWebForwards(events) },
            "openBrowser": spec("browser", admit: { _ in try self.requireWebForwards() }) { _, events in
                try await self.openBrowser(events)
            },
        ]
    }

    // MARK: Admission

    private func requireConfigured() throws {
        guard profiles.activeProfile.isConfigured else {
            throw HelperError(code: "notConfigured", message: "Configure the profile's SSO, account, role, region and instance tag first.")
        }
    }

    private func requireConnected() throws {
        guard connection.state == .connected else {
            throw HelperError(code: "notConnected", message: "The workstation is not connected.")
        }
    }

    private func requireEditor() throws {
        try requireConfigured()
        guard profiles.activeProfile.remoteDevelopment?.enabled == true else {
            throw HelperError(code: "editorOff", message: "Turn on remote development for this profile first.")
        }
    }

    private func requireWebForwards() throws {
        try requireConfigured()
        guard profiles.activeProfile.webForwards?.enabled == true else {
            throw HelperError(code: "webForwardsOff", message: "Turn on web forwards for this profile first.")
        }
    }

    // MARK: Profiles

    private func listProfiles() throws -> [String: String] {
        let data = try JSONEncoder().encode(profiles.profiles)
        return ["profiles": String(decoding: data, as: UTF8.self), "active": profiles.activeProfileID?.uuidString ?? ""]
    }

    private func saveProfile(_ arguments: [String: String]) throws -> [String: String] {
        guard let json = arguments["profile"],
              let profile = try? JSONDecoder().decode(ConnectionProfile.self, from: Data(json.utf8)) else {
            throw HelperError(code: "invalidProfile", message: "The profile could not be read.")
        }
        if !profiles.updateProfile(profile) { profiles.addProfile(profile) }
        apply()
        return ["id": profile.id.uuidString]
    }

    private func setActiveProfile(_ arguments: [String: String]) throws -> [String: String] {
        guard let id = arguments["id"].flatMap(UUID.init(uuidString:)), profiles.profiles.contains(where: { $0.id == id }) else {
            throw HelperError(code: "unknownProfile", message: "That profile does not exist.")
        }
        profiles.setActiveProfile(id)
        apply()
        return ["id": id.uuidString]
    }

    private func importProfile(_ arguments: [String: String]) throws -> [String: String] {
        guard let path = arguments["path"] else { throw HelperError(code: "invalidPath", message: "No profile file was given.") }
        let snapshot = try services.profileFiles.read(URL(fileURLWithPath: path))
        let profile = try profiles.importFile(snapshot, attach: arguments["attach"] == "true")
        apply()
        return ["id": profile.id.uuidString]
    }

    /// Hands the active profile to the workflows; a connected workflow stages it as today.
    private func apply() {
        let profile = profiles.activeProfile
        authorization.apply(profile: profile)
        connection.apply(profile: profile, settings: profiles.settings)
        web.apply(profile: profile, settings: profiles.settings)
        editor.apply(profile: profile)
    }

    // MARK: Workflows

    private func signIn() async throws -> [String: String] {
        _ = try await authorization.signIn(profile: profiles.activeProfile)
        return ["status": "ready"]
    }

    private func connect(_ events: EventSink) async throws -> [String: String] {
        connection.connect()
        _ = try await follow("desktop", events, cancel: { self.connection.disconnect() }) {
            switch self.connection.state {
            case .connected: return .done(["state": "connected"])
            case .error: return .failed(HelperError(code: "connectFailed", message: self.connection.errorMessage ?? "The connection failed."))
            default: return .running(self.connection.state.rawValue)
            }
        }
        // The desktop launch (DCV Viewer, or its warning) finishes the connect flow.
        await connection.awaitInFlightTask()
        return ["state": connection.state.rawValue, "warning": connection.warningMessage ?? ""]
    }

    private func disconnect(_ events: EventSink) async throws -> [String: String] {
        connection.disconnect()
        await connection.awaitInFlightTask()
        events.emit(workflow: "desktop", name: "state", fields: ["state": connection.state.rawValue])
        return ["state": connection.state.rawValue]
    }

    private func stopWorkstation(_ events: EventSink) async throws -> [String: String] {
        connection.stopWorkstation()
        await connection.awaitInFlightTask()
        events.emit(workflow: "desktop", name: "state", fields: ["state": connection.state.rawValue])
        if connection.state == .error {
            throw HelperError(code: "stopFailed", message: connection.errorMessage ?? "The workstation could not be stopped.")
        }
        return ["state": connection.state.rawValue]
    }

    private func installEditorSetup(_ arguments: [String: String]) throws -> [String: String] {
        try editor.installSetup(consent: arguments["consent"] == "true")
        return ["installed": "true"]
    }

    private func openEditor(_ events: EventSink) async throws -> [String: String] {
        editor.open()
        events.emit(workflow: "editor", name: "state", fields: ["state": "opening"])
        await editor.awaitOpening()
        if let message = editor.errorMessage {
            events.emit(workflow: "editor", name: "state", fields: ["state": "error", "message": message])
            throw HelperError(code: "editorFailed", message: message)
        }
        events.emit(workflow: "editor", name: "state", fields: ["state": "launched"])
        return ["launched": String(editor.editorLaunched)]
    }

    private func startWebForwards(_ events: EventSink) async throws -> [String: String] {
        web.connect()
        return try await follow("web", events, cancel: { self.web.stop() }) {
            switch self.web.state {
            case .on: return .done(["state": "on"])
            case .error: return .failed(HelperError(code: "webForwardsFailed", message: self.web.errorMessage ?? "Web forwards failed."))
            default: return .running(self.web.state.rawValue)
            }
        }
    }

    private func stopWebForwards(_ events: EventSink) async throws -> [String: String] {
        web.stop()
        await web.awaitStopped()
        events.emit(workflow: "web", name: "state", fields: ["state": web.state.rawValue])
        return ["state": web.state.rawValue]
    }

    private func openBrowser(_ events: EventSink) async throws -> [String: String] {
        web.openBrowser(using: browser)
        await web.awaitBrowserOpened()
        if let message = web.browserErrorMessage { throw HelperError(code: "browserFailed", message: message) }
        events.emit(workflow: "web", name: "state", fields: ["state": web.state.rawValue])
        return ["state": web.state.rawValue]
    }

    private enum Progress { case running(String), done([String: String]), failed(HelperError) }

    /// Emits a state event at each change until the workflow settles; cancelling the command
    /// tears the workflow down. The authorization status is streamed alongside as its own
    /// workflow: a connect waiting for an explicit sign-in shows `signInRequired`, so the shell can
    /// tell the user to sign in, and the action resumes once they have.
    private func follow(_ workflow: String, _ events: EventSink, cancel: @escaping () -> Void,
                        _ check: () -> Progress) async throws -> [String: String] {
        var last = ""
        var lastAuthorization = ""
        while true {
            let authorizationState = authorization.status.eventName
            if authorizationState != lastAuthorization {
                events.emit(workflow: "authorization", name: "state",
                            fields: ["state": authorizationState, "detail": authorization.detailLine ?? ""])
                lastAuthorization = authorizationState
            }
            let progress = check()
            let state: String
            switch progress {
            case let .running(value): state = value
            case let .done(value): state = value["state"] ?? "done"
            case .failed: state = "error"
            }
            if state != last {
                events.emit(workflow: workflow, name: "state", fields: ["state": state])
                last = state
            }
            switch progress {
            case .running: break
            case let .done(value): return value
            case let .failed(error): throw error
            }
            do { try await Task.sleep(for: pollInterval) }
            catch {
                cancel()
                throw CancellationError()
            }
        }
    }
}

/// How the helper ends, whether its shell closed stdin or the session ended: every running command
/// is cancelled and answered, then the workflows' quit work runs, as the macOS app runs it when it
/// quits. That ends a connected desktop's plugin, removes the web forwards key and the editor's
/// leases and keys, so no transient access artifact outlives the helper.
package enum HelperExit {
    /// `quit` defaults to the shared handler the workflows register with.
    @MainActor package static func end(_ session: HelperSession, quit: AppQuitHandler? = nil) async {
        await session.shutdown()
        (quit ?? .shared).runShutdown()
    }
}

extension AuthorizationSession.Status {
    /// The status as it appears in the helper's `authorization` state events.
    var eventName: String {
        switch self {
        case .idle: "idle"
        case .ready: "ready"
        case .refreshing: "refreshing"
        case .signInRequired: "signInRequired"
        case .signingIn: "signingIn"
        case .unavailable: "unavailable"
        }
    }
}
