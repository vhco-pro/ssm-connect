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
    /// The installed, supported browser for a profile's choice and mode, or nil when unavailable.
    package var browserExecutable: @MainActor (ConnectionProfile) -> String?
    /// Where managed browsers keep their own profiles.
    package var browserProfiles: URL
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
                 editor: EditorServices, browserExecutable: @escaping @MainActor (ConnectionProfile) -> String?,
                 browserProfiles: URL, requests: ShellRequests) {
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
        self.browserExecutable = browserExecutable
        self.browserProfiles = browserProfiles
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
    /// The connection log the macOS Log window shows, shared by the workflows.
    package let log: ConnectionLog
    private let services: HelperServices
    private let browser: ShellBrowserOpener
    private let pollInterval: Duration

    /// `quit` is where the runtime registers its own quit work; the helper's exit runs it.
    package init(services: HelperServices, pollInterval: Duration = .milliseconds(50), quit: AppQuitHandler = .shared) {
        self.services = services
        self.pollInterval = pollInterval
        profiles = ProfileStore(store: services.keyValues, files: services.profileFiles)
        let profile = profiles.activeProfile
        authorization = AuthorizationSession(platform: services.platform, profile: profile, provider: services.auth)
        let log = ConnectionLog()
        self.log = log
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
        browser = ShellBrowserOpener(requests: services.requests, executable: services.browserExecutable,
                                     profiles: services.browserProfiles)
        // Connection files still waiting for a Viewer go when the helper ends.
        let dcv = services.dcv
        quit.register { dcv.removeWaitingFiles() }
    }

    /// The command table for the helper session.
    package nonisolated func commands() -> [String: CommandSpec] {
        func spec(_ workflow: String, admit: @escaping @Sendable @MainActor ([String: String]) throws -> Void = { _ in },
                  _ run: @escaping @Sendable @MainActor ([String: String], EventSink) async throws -> [String: String]) -> CommandSpec {
            CommandSpec(workflow: workflow,
                        admit: { arguments in try await admit(arguments) },
                        run: { arguments, events in
                            await self.startDetails(events)
                            return try await run(arguments, events)
                        })
        }
        return [
            "listProfiles": spec("profiles") { _, _ in try self.listProfiles() },
            "saveProfile": spec("profiles") { arguments, _ in try self.saveProfile(arguments) },
            "setActiveProfile": spec("profiles") { arguments, _ in try self.setActiveProfile(arguments) },
            "importProfile": spec("profiles") { arguments, _ in try self.importProfile(arguments) },
            "applyFileChanges": spec("profiles") { arguments, _ in try self.applyFileChanges(arguments) },
            "deleteProfile": spec("profiles") { arguments, _ in try self.deleteProfile(arguments) },
            "duplicateProfile": spec("profiles") { arguments, _ in try self.duplicateProfile(arguments) },
            "listAWSConfigProfiles": spec("profiles") { _, _ in try self.listAWSConfigProfiles() },
            "previewProfileFile": spec("profiles") { arguments, _ in try self.previewProfileFile(arguments) },
            "exportProfile": spec("profiles") { arguments, _ in try self.exportProfile(arguments) },
            "saveLocalCopy": spec("profiles") { arguments, _ in try self.saveLocalCopy(arguments) },
            "reviewFileChanges": spec("profiles") { arguments, _ in try self.reviewFileChanges(arguments) },
            "locateProfileFile": spec("profiles") { arguments, _ in try self.locateProfileFile(arguments) },
            "detachProfile": spec("profiles") { arguments, _ in try self.detachProfile(arguments) },
            "saveSettings": spec("profiles") { arguments, _ in try self.saveSettings(arguments) },
            "signIn": spec("authorization", admit: { _ in try self.requireConfigured() }) { _, _ in try await self.signIn() },
            "retryAuthorization": spec("authorization", admit: { _ in try self.requireConfigured() }) { _, _ in
                self.authorization.retry()
                return ["status": self.authorization.status.eventName]
            },
            "copyPassword": spec("desktop", admit: { _ in try self.requireConnected() }) { _, _ in
                self.connection.copyPassword()
                return [:]
            },
            "reconnect": spec("desktop", admit: { _ in try self.requireConnected() }) { _, events in try await self.reconnect(events) },
            "reconnectWorkspace": spec("editor", admit: { _ in try self.requireEditor() }) { _, events in
                try await self.editorWork(events) { self.editor.reconnectExistingWorkspace() }
            },
            "renewEditorAccess": spec("editor") { _, events in try await self.editorWork(events) { self.editor.renewAccess() } },
            "approveReplacement": spec("editor") { arguments, events in try await self.approveReplacement(arguments, events) },
            "cancelEditorRecovery": spec("editor") { _, events in
                self.editor.cancelRecovery()
                events.emit(workflow: "editor", name: "state", fields: ["state": self.editorState])
                return ["state": self.editorState]
            },
            "stopRemoteAccess": spec("editor") { _, events in
                self.editor.stop()
                events.emit(workflow: "editor", name: "state", fields: ["state": self.editorState])
                return ["state": self.editorState]
            },
            "restoreEditorSetup": spec("editor") { _, events in
                do { try self.editor.restoreSetup() }
                catch { throw HelperError(code: "restoreFailed", message: error.localizedDescription) }
                events.emit(workflow: "editor", name: "state", fields: ["state": self.editorState])
                return ["state": self.editorState]
            },
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
            "approveForwardingReplacement": spec("web") { arguments, events in try await self.approveForwardingReplacement(arguments, events) },
            "cancelForwardingRecovery": spec("web") { _, events in
                self.web.stop()
                events.emit(workflow: "web", name: "state", fields: ["state": self.web.state.rawValue])
                return ["state": self.web.state.rawValue]
            },
            "applyWebChanges": spec("web") { _, events in try await self.applyWebChanges(events) },
            "openForward": spec("browser") { arguments, _ in try self.openForward(arguments) },
            "copyPACURL": spec("browser") { _, _ in try self.copyPACURL() },
            "revealPACFile": spec("browser") { _, _ in try self.revealPACFile() },
            "applyBrowserSetup": spec("browser") { _, _ in try self.applyBrowserSetup() },
            "restoreBrowserSettings": spec("browser") { _, _ in try self.restoreBrowserSettings() },
            "getLog": spec("log") { _, _ in try self.getLog() },
            "clearLog": spec("log") { _, _ in
                self.log.clear()
                return ["entries": "[]"]
            },
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

    /// The profiles, the active one, and each attached file with whether it changed outside SSM
    /// Connect or cannot be read.
    private func listProfiles() throws -> [String: String] {
        profiles.refreshAttachedFiles()
        let data = try JSONEncoder().encode(profiles.profiles)
        let files = profiles.attachments.sorted { $0.key.uuidString < $1.key.uuidString }.map { id, attachment in
            ["id": id.uuidString, "path": attachment.url.path, "pending": String(profiles.pendingFiles[id] != nil),
             "error": profiles.fileErrors[id] ?? ""]
        }
        return ["profiles": String(decoding: data, as: UTF8.self), "active": profiles.activeProfileID?.uuidString ?? "",
                "files": String(decoding: try JSONEncoder().encode(files), as: UTF8.self),
                "settings": String(decoding: try JSONEncoder().encode(Self.settingsFields(profiles.settings)), as: UTF8.self)]
    }

    private func saveProfile(_ arguments: [String: String]) throws -> [String: String] {
        guard let json = arguments["profile"],
              let profile = try? JSONDecoder().decode(ConnectionProfile.self, from: Data(json.utf8)) else {
            throw HelperError(code: "invalidProfile", message: "The profile could not be read.")
        }
        if let attachment = profiles.attachments[profile.id] {
            // An attached file is saved as on macOS: with consent to canonical formatting, and
            // only while the file is unchanged since SSM Connect last read it.
            do {
                try profiles.saveEditedProfile(profile, expected: attachment.revision,
                                               acceptCanonicalFormatting: arguments["acceptFormatting"] == "true")
            } catch let error as PortableProfileError {
                switch error {
                case .formattingConsentRequired:
                    throw HelperError(code: "formattingConsentRequired", message: error.localizedDescription)
                case .conflict:
                    throw HelperError(code: "fileConflict", message: error.localizedDescription)
                case .invalid:
                    throw HelperError(code: "invalidProfile", message: error.localizedDescription)
                }
            }
        } else if !profiles.updateProfile(profile) {
            profiles.addProfile(profile)
        }
        apply()
        return ["id": profile.id.uuidString]
    }

    /// Takes an attached file's outside changes into its local profile.
    private func applyFileChanges(_ arguments: [String: String]) throws -> [String: String] {
        guard let id = arguments["id"].flatMap(UUID.init(uuidString:)) else {
            throw HelperError(code: "unknownProfile", message: "That profile does not exist.")
        }
        profiles.refreshAttachedFiles()
        do { try profiles.applyPendingFile(id) }
        catch { throw HelperError(code: "applyFailed", message: error.localizedDescription) }
        apply()
        return ["id": id.uuidString]
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

    // MARK: Connection and editor actions the macOS menu offers (AC-29)

    private func reconnect(_ events: EventSink) async throws -> [String: String] {
        connection.reconnect()
        _ = try await follow("desktop", events, cancel: {
            self.connection.disconnect()
            await self.connection.awaitInFlightTask()
        }) {
            switch self.connection.state {
            case .connected: return .done(["state": "connected"])
            case .error: return .failed(HelperError(code: "connectFailed", message: self.connection.errorMessage ?? "The connection failed."))
            default: return .running(self.connection.state.rawValue)
            }
        }
        await connection.awaitInFlightTask()
        return ["state": connection.state.rawValue]
    }

    /// The editor workflow's state for the shells: what macOS's menu shows for it.
    var editorState: String {
        if editor.isRenewingLease { return "renewing" }
        if editor.isRecovering { return "recovering" }
        if editor.isOpening { return "opening" }
        if editor.pendingReplacement != nil { return "replacementPending" }
        return editor.isActive ? "active" : "idle"
    }

    /// Starts editor work and follows it until the editor is no longer opening, recovering or
    /// renewing; cancelling it cancels the recovery, as Cancel Recovery does.
    private func editorWork(_ events: EventSink, _ start: () -> Void) async throws -> [String: String] {
        start()
        return try await follow("editor", events, cancel: { self.editor.cancelRecovery() }) {
            if let message = self.editor.errorMessage, !self.editor.isOpening, !self.editor.isRecovering, !self.editor.isRenewingLease {
                return .failed(HelperError(code: "editorFailed", message: message))
            }
            let state = self.editorState
            return ["opening", "recovering", "renewing"].contains(state) ? .running(state) : .done(["state": state])
        }
    }

    /// Review Replacement Workstation: approves the replacement waiting for review (the one the
    /// shell showed, when it names one).
    private func approveReplacement(_ arguments: [String: String], _ events: EventSink) async throws -> [String: String] {
        guard let pending = editor.pendingReplacement else {
            throw HelperError(code: "noReplacement", message: "No replacement workstation is waiting for review.")
        }
        if let id = arguments["id"], id != pending.id.uuidString {
            throw HelperError(code: "replacementChanged", message: "The replacement waiting for review changed. Review it again.")
        }
        return try await editorWork(events) { self.editor.approveReplacement(pending.id) }
    }

    /// Everything the shells show and use to offer and enable controls, as macOS's menu reads it
    /// from the workflows: one flat map, sent as a `details` event whenever it changes.
    package func details() -> [String: String] {
        func json<T: Encodable>(_ value: T) -> String { (try? JSONEncoder().encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "" }
        let replacement = editor.pendingReplacement.map {
            ["id": $0.id.uuidString, "previous": $0.previousInstanceID, "instance": $0.instanceID, "user": $0.user,
             "profile": $0.profile.name, "account": $0.profile.accountId, "region": $0.profile.resourceRegion]
        }
        let webReplacement = web.pendingReplacement.map {
            ["id": $0.id.uuidString, "previous": $0.previousInstanceID, "instance": $0.instanceID, "user": $0.user]
        }
        let forwards = (web.profile.webForwards?.localForwards ?? []).map {
            ["name": $0.name, "localPort": String($0.localPort), "openPath": $0.openPath ?? ""]
        }
        return [
            "profiles": String(profiles.profiles.count),
            "authorization.status": authorization.status.eventName,
            "authorization.detail": authorization.detailLine ?? "",
            "desktop.state": connection.state.rawValue,
            "desktop.maskedPassword": connection.maskedPassword ?? "",
            "desktop.detailLines": connection.connectionDetailLines.joined(separator: "\n"),
            "desktop.pendingProfile": connection.pendingProfile?.name ?? "",
            "editor.enabled": String(editor.profile.remoteDevelopment?.enabled == true),
            "editor.state": editorState,
            "editor.setupInstalled": String(editor.setupInstalled),
            "editor.setupConfigPath": editor.setupConfigPath,
            "editor.leaseMessage": editor.leaseMessage ?? "",
            "editor.recoveryMessage": editor.recoveryMessage ?? "",
            "editor.error": editor.errorMessage ?? "",
            "editor.replacement": replacement.map(json) ?? "",
            "web.enabled": String(web.profile.webForwards?.enabled == true),
            "web.state": web.state.rawValue,
            "web.socks": String(web.profile.webForwards?.socksPort != nil),
            "web.browserMode": web.profile.webForwards?.browserMode?.rawValue ?? "",
            "web.openingBrowser": String(web.isOpeningBrowser),
            "web.pendingChanges": String(web.pendingProfile != nil),
            "web.recoveryMessage": web.recoveryMessage ?? "",
            "web.error": web.errorMessage ?? "",
            "web.replacement": webReplacement.map(json) ?? "",
            "web.forwards": json(forwards),
        ]
    }

    private var detailsTask: Task<Void, Never>?

    /// The first admitted command, which only comes after the handshake, starts the details stream.
    private func startDetails(_ events: EventSink) {
        guard detailsTask == nil else { return }
        detailsTask = streamDetails(to: events)
    }

    /// Sends `details` whenever it changes, until the task is cancelled.
    package func streamDetails(to events: EventSink, interval: Duration = .milliseconds(250)) -> Task<Void, Never> {
        Task { @MainActor in
            var last: [String: String] = [:]
            while !Task.isCancelled {
                let current = self.details()
                if current != last {
                    events.emit(workflow: "details", name: "details", fields: current)
                    last = current
                }
                try? await Task.sleep(for: interval)
            }
        }
    }

    // MARK: Web forwards, browser and log actions the macOS menu offers (AC-29)

    private func approveForwardingReplacement(_ arguments: [String: String], _ events: EventSink) async throws -> [String: String] {
        guard let pending = web.pendingReplacement else {
            throw HelperError(code: "noReplacement", message: "No forwarding replacement is waiting for review.")
        }
        if let id = arguments["id"], id != pending.id.uuidString {
            throw HelperError(code: "replacementChanged", message: "The replacement waiting for review changed. Review it again.")
        }
        web.approveReplacement(pending.id)
        return try await followWeb(events)
    }

    /// Apply Changes: reconnects web forwards with the saved settings, as macOS does.
    private func applyWebChanges(_ events: EventSink) async throws -> [String: String] {
        guard web.pendingProfile != nil else {
            throw HelperError(code: "noPendingChanges", message: "No saved web forward changes are waiting.")
        }
        await web.applyPendingConfiguration()
        return try await followWeb(events)
    }

    private func followWeb(_ events: EventSink) async throws -> [String: String] {
        try await follow("web", events, cancel: {
            self.web.stop()
            await self.web.awaitStopped()
        }) {
            switch self.web.state {
            case .on: return .done(["state": "on"])
            case .error: return .failed(HelperError(code: "webForwardsFailed", message: self.web.errorMessage ?? "Web forwards failed."))
            case .off: return .done(["state": "off"])
            default: return .running(self.web.state.rawValue)
            }
        }
    }

    /// Open <forward>: the forward's page on its local port, while web forwards are on.
    private func openForward(_ arguments: [String: String]) throws -> [String: String] {
        guard web.state == .on else { throw HelperError(code: "webForwardsOff", message: "Turn on web forwards first.") }
        guard let forward = web.profile.webForwards?.localForwards.first(where: { $0.name == arguments["name"] }),
              let path = forward.openPath, !path.isEmpty,
              let url = URL(string: "http://127.0.0.1:\(forward.localPort)\(path)") else {
            throw HelperError(code: "unknownForward", message: "That local forward has no page to open.")
        }
        services.requests.openURL(url)
        return ["url": url.absoluteString]
    }

    private func pacURL() throws -> URL {
        guard let url = web.pacURL else { throw HelperError(code: "noPAC", message: "No PAC file has been written for this profile yet.") }
        return url
    }

    private func copyPACURL() throws -> [String: String] {
        let url = try pacURL()
        services.requests.setClipboard(url.absoluteString)
        return ["url": url.absoluteString]
    }

    private func revealPACFile() throws -> [String: String] {
        let url = try pacURL()
        services.requests.reveal(url)
        return ["path": url.externalPath]
    }

    /// Apply Browser Setup changes an existing Zen profile's proxy settings (Use My Browser). The shells
    /// offer it only where Zen is supported, and no Windows or Linux Zen is pinned yet, so it is refused
    /// by the missing capability, before any change.
    private func applyBrowserSetup() throws -> [String: String] {
        let profile = web.profile
        guard profile.webForwards?.browserMode == .existing else {
            throw HelperError(code: "notUseMyBrowser", message: "Apply Browser Setup is for Use My Browser.")
        }
        do { try browser.preflight(profile: profile) }
        catch { throw HelperError(code: "browserUnavailable", message: error.localizedDescription) }
        throw HelperError(code: "browserUnavailable",
                          message: "Use My Browser needs Zen at a supported version, which is not available on this platform yet.")
    }

    private func restoreBrowserSettings() throws -> [String: String] {
        do { try browser.restore(profile: web.profile) }
        catch { throw HelperError(code: "restoreFailed", message: error.localizedDescription) }
        return [:]
    }

    /// The connection log, oldest first, as the Log window shows it.
    private func getLog() throws -> [String: String] {
        let formatter = ISO8601DateFormatter()
        let entries = log.entries.map { ["time": formatter.string(from: $0.timestamp), "category": $0.category.rawValue, "message": $0.message] }
        return ["entries": String(decoding: try JSONEncoder().encode(entries), as: UTF8.self)]
    }

    // MARK: Profile and settings actions the macOS settings window offers (AC-29)

    private func profileID(_ arguments: [String: String]) throws -> UUID {
        guard let id = arguments["id"].flatMap(UUID.init(uuidString:)), profiles.profiles.contains(where: { $0.id == id }) else {
            throw HelperError(code: "unknownProfile", message: "That profile does not exist.")
        }
        return id
    }

    /// As on macOS, the last profile cannot be deleted, and the first remaining one becomes active
    /// when the active one goes. An attached file is never touched.
    private func deleteProfile(_ arguments: [String: String]) throws -> [String: String] {
        let id = try profileID(arguments)
        guard profiles.profiles.count > 1 else {
            throw HelperError(code: "lastProfile", message: "The last profile cannot be deleted.")
        }
        profiles.deleteProfile(id)
        apply()
        return ["id": id.uuidString, "active": profiles.activeProfileID?.uuidString ?? ""]
    }

    private func duplicateProfile(_ arguments: [String: String]) throws -> [String: String] {
        let id = try profileID(arguments)
        guard let copy = profiles.duplicateProfile(id) else {
            throw HelperError(code: "duplicateFailed", message: profiles.operationError ?? "The profile could not be duplicated.")
        }
        return ["id": copy.id.uuidString]
    }

    /// The SSO profiles in `~/.aws/config` the user can start a new profile from.
    private func listAWSConfigProfiles() throws -> [String: String] {
        ["profiles": String(decoding: try JSONEncoder().encode(profiles.importableProfiles()), as: UTF8.self)]
    }

    /// What Open Profile File shows before the user attaches or imports: nothing is stored yet.
    private func previewProfileFile(_ arguments: [String: String]) throws -> [String: String] {
        guard let path = arguments["path"] else { throw HelperError(code: "invalidPath", message: "No profile file was given.") }
        let snapshot = try services.profileFiles.read(URL(fileURLWithPath: path))
        let profile = try snapshot.document.profile(localID: UUID())
        let document = try ProfileDocumentCodec.write(snapshot.document, format: .json)
        return ["profile": String(decoding: try JSONEncoder().encode(profile), as: UTF8.self),
                "document": String(decoding: document, as: UTF8.self), "writable": String(snapshot.isWritable)]
    }

    private func exportProfile(_ arguments: [String: String]) throws -> [String: String] {
        let id = try profileID(arguments)
        guard let path = arguments["path"] else { throw HelperError(code: "invalidPath", message: "No export file was given.") }
        let url = URL(fileURLWithPath: path)
        do {
            _ = try services.profileFiles.save(try profiles.exportDocument(id), to: url,
                                               expected: try services.profileFiles.existingRevision(url), beforeCommit: {})
        } catch { throw HelperError(code: "exportFailed", message: error.localizedDescription) }
        return ["path": path]
    }

    /// Save a Local Copy from the settings window (the stored profile) or the profile editor (its edits).
    private func saveLocalCopy(_ arguments: [String: String]) throws -> [String: String] {
        let profile: ConnectionProfile
        if let json = arguments["profile"] {
            guard let edited = try? JSONDecoder().decode(ConnectionProfile.self, from: Data(json.utf8)) else {
                throw HelperError(code: "invalidProfile", message: "The profile could not be read.")
            }
            profile = edited
        } else {
            let id = try profileID(arguments)
            guard let stored = profiles.profiles.first(where: { $0.id == id }) else {
                throw HelperError(code: "unknownProfile", message: "That profile does not exist.")
            }
            profile = stored
        }
        do { return ["id": try profiles.saveLocalCopy(profile, preservingFrom: profile.id).id.uuidString] }
        catch { throw HelperError(code: "saveFailed", message: error.localizedDescription) }
    }

    /// Reload / Review Changes: the outside changes waiting for Apply, if any.
    private func reviewFileChanges(_ arguments: [String: String]) throws -> [String: String] {
        let id = try profileID(arguments)
        profiles.refreshAttachedFiles()
        guard let pending = profiles.pendingFiles[id] else { return ["pending": "false", "document": ""] }
        let document = try ProfileDocumentCodec.write(pending.document, format: .json)
        return ["pending": "true", "document": String(decoding: document, as: UTF8.self)]
    }

    private func locateProfileFile(_ arguments: [String: String]) throws -> [String: String] {
        let id = try profileID(arguments)
        guard let path = arguments["path"] else { throw HelperError(code: "invalidPath", message: "No profile file was given.") }
        do { try profiles.locateFile(id, at: URL(fileURLWithPath: path)) }
        catch { throw HelperError(code: "locateFailed", message: error.localizedDescription) }
        return ["id": id.uuidString]
    }

    private func detachProfile(_ arguments: [String: String]) throws -> [String: String] {
        let id = try profileID(arguments)
        profiles.detachFile(id)
        return ["id": id.uuidString]
    }

    /// The settings fields the shells read and write, under the names the parity inventory uses.
    static func settingsFields(_ settings: AppSettings) -> [String: String] {
        ["connectOnLaunch": String(settings.autoConnect), "autoReconnect": String(settings.autoReconnect),
         "clipboardAutoClearSeconds": String(settings.clipboardAutoClearSeconds)]
    }

    /// Saves the fields given and keeps the others.
    private func saveSettings(_ arguments: [String: String]) throws -> [String: String] {
        var settings = profiles.settings
        if let value = arguments["connectOnLaunch"] { settings.autoConnect = value == "true" }
        if let value = arguments["autoReconnect"] { settings.autoReconnect = value == "true" }
        if let value = arguments["clipboardAutoClearSeconds"] {
            guard let seconds = Int(value), seconds >= 0 else {
                throw HelperError(code: "invalidSettings", message: "The clipboard time must be zero or more seconds.")
            }
            settings.clipboardAutoClearSeconds = seconds
        }
        profiles.settings = settings
        apply()
        return Self.settingsFields(settings)
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
        // A killed helper's connection files are removed here; the macOS app sweeps at launch.
        services.dcv.sweepOrphanedFiles()
        connection.connect()
        _ = try await follow("desktop", events, cancel: {
            self.connection.disconnect()
            await self.connection.awaitInFlightTask()
        }) {
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
        return try await follow("web", events, cancel: {
            self.web.stop()
            await self.web.awaitStopped()
        }) {
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

    /// Emits a state event at each change until the workflow settles. Cancelling the command runs
    /// `cancel`, which returns once the workflow is torn down, and sends that state, since the tray
    /// shows the last state event. The authorization status is streamed alongside as its own
    /// workflow: a connect waiting for an explicit sign-in shows `signInRequired`, so the shell can
    /// tell the user to sign in, and the action resumes once they have.
    private func follow(_ workflow: String, _ events: EventSink, cancel: @escaping () async -> Void,
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
                await cancel()
                let final: String
                switch check() {
                case let .running(value): final = value
                case let .done(value): final = value["state"] ?? "done"
                case .failed: final = "error"
                }
                if final != last { events.emit(workflow: workflow, name: "state", fields: ["state": final]) }
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
