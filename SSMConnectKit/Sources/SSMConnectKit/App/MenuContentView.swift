import SwiftUI

/// The MenuBarExtra dropdown content (H7, F-01/F-12). Factored into its own `View` so it can use
/// `@Environment(\.openWindow)` (Show Log) and `SettingsLink`. Re-applies the active profile /
/// settings each time it appears so a change in the Settings window takes effect on next connect.
public struct MenuContentView: View {
    @Bindable var machine: ConnectionStateMachine
    let store: ProfileStore
    let webForwards: WebForwardsStateMachine?
    let remoteDevelopment: RemoteDevelopmentStateMachine?
    @Environment(\.openWindow) private var openWindow
    @State private var browserBootstrap = BrowserBootstrap()

    public init(machine: ConnectionStateMachine, store: ProfileStore, webForwards: WebForwardsStateMachine? = nil,
                remoteDevelopment: RemoteDevelopmentStateMachine? = nil) {
        self.machine = machine
        self.store = store
        self.webForwards = webForwards
        self.remoteDevelopment = remoteDevelopment
    }

    public var body: some View {
        Group {
            // Header: the CURRENT connection state only (icon + label), non-interactive.
            Label {
                Text(machine.state.tooltip)
            } icon: {
                Image(systemName: machine.state.sfSymbol)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(machine.state.color)
            }
            .disabled(true)

            // Secondary detail line: session expiry / warning, or the last error message.
            if let detail = machine.detailLine {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(machine.authorizationSessions.indices, id: \.self) { index in
                let authorization = machine.authorizationSessions[index]
                if let detail = authorization.detailLine {
                    Text("\(authorization.profile.name): \(detail)").font(.caption).foregroundStyle(.secondary)
                    if authorization.status == .signInRequired {
                        Button("Sign In with SSO") { authorization.signIn() }
                    } else if case .unavailable = authorization.status {
                        Button("Retry Authorization") { authorization.retry() }
                    }
                }
            }
            if let pending = machine.pendingProfile {
                Text("Saved profile changes pending: \(pending.name). Reconnect to apply.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            // Live connection details (instance, tunnel, elapsed) when connected (F-12).
            ForEach(machine.connectionDetailLines, id: \.self) { line in
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let masked = machine.maskedPassword {
                Text("Password: \(masked)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            if !store.hasProfiles {
                // First launch: nothing is configured. Guide the user to set up a profile.
                Text("No workstation configured.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                SettingsLink { Text("Set Up a Workstation…") }
                    .keyboardShortcut(",")
            } else {
                // Context-aware primary action (Connect / Connecting… / Connected / Retry).
                Button(machine.actionTitle) {
                    machine.primaryAction()
                }
                .disabled(!machine.actionEnabled)
            }

            // Connected-only actions (F-11/F-14/F-15).
            if machine.state == .connected {
                if machine.maskedPassword != nil {
                    Button("Copy Password") { machine.copyPassword() }
                }
                Button("Reconnect") { machine.reconnect() }
                Button("Stop Workstation…") {
                    if confirmStopWorkstation() { machine.stopWorkstation() }
                }
                Button("Disconnect") { machine.disconnect() }
            }

            if let remoteDevelopment, remoteDevelopment.profile.remoteDevelopment?.enabled == true || remoteDevelopment.isActive {
                Divider()
                Button(remoteDevelopment.isOpening ? "Opening VS Code" : "Open VS Code") {
                    do {
                        if !remoteDevelopment.setupInstalled {
                            guard confirm("Set up native VS Code access?", "Add an app-owned SSH Include to \(remoteDevelopment.setupConfigPath). Your existing SSH hosts remain unchanged. Microsoft Remote - SSH handles its server installation and workspace trust. No DCV session or web proxy is started.") else { return }
                            try remoteDevelopment.installSetup(consent: true)
                        }
                        remoteDevelopment.open()
                    } catch { showBrowserError(error) }
                }
                .disabled(remoteDevelopment.isOpening)
                if remoteDevelopment.editorLaunched { Text("VS Code launched") }
                if let expiry = remoteDevelopment.leaseExpiry {
                    Text("Editor lease expires \(expiry.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error = remoteDevelopment.errorMessage { Text(error).font(.caption).foregroundStyle(.secondary) }
                if remoteDevelopment.isActive {
                    Button("Stop Remote Access") {
                        if confirm("Stop native editor access?", "This drops the editor's owned SSH channels. VS Code windows and unsaved buffers remain open; DCV and web forwards are unchanged.") {
                            remoteDevelopment.stop()
                        }
                    }
                }
                if remoteDevelopment.setupInstalled {
                    Button("Restore Editor Setup") {
                        do {
                            if confirm("Restore editor SSH setup?", "Remove only the still-owned Include and stop editor access. Independently changed SSH configuration is never overwritten.") {
                                try remoteDevelopment.restoreSetup()
                            }
                        } catch { showBrowserError(error) }
                    }
                }
            }

            if let webForwards, webForwards.profile.webForwards?.enabled == true || webForwards.state != .off {
                Divider()
                Text("Web Forwards: \(webForwards.state.rawValue)")
                if let error = webForwards.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                }
                Button(webForwards.state == .on || webForwards.state == .starting ? "Turn Off Web Forwards" : "Turn On Web Forwards") {
                    if webForwards.state == .on || webForwards.state == .starting { webForwards.stop() }
                    else { webForwards.connect() }
                }
                ForEach(webForwards.profile.webForwards?.localForwards ?? []) { forward in
                    if let path = forward.openPath, !path.isEmpty {
                        Button("Open \(forward.name)") {
                            if let url = URL(string: "http://127.0.0.1:\(forward.localPort)\(path)") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .disabled(webForwards.state != .on)
                    }
                }
                if webForwards.profile.webForwards?.socksPort != nil {
                    Button(webForwards.isOpeningBrowser ? "Opening Browser" : "Open Browser") {
                        openBrowser(webForwards)
                    }
                    .disabled(webForwards.isOpeningBrowser)
                    if let error = webForwards.browserErrorMessage {
                        Text(error).font(.caption).foregroundStyle(.secondary)
                    }
                    Menu("Advanced") {
                        Text("Manual setup for other browser windows")
                        Button("Copy PAC URL") {
                            guard let url = webForwards.pacURL else { return }
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url.absoluteString, forType: .string)
                        }
                        .disabled(webForwards.pacURL == nil)
                        Button("Reveal PAC File") {
                            if let url = webForwards.pacURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        }
                        .disabled(webForwards.pacURL == nil)
                        if webForwards.profile.webForwards?.browserMode == .existing {
                            Button("Apply Browser Setup") {
                                do {
                                    try browserBootstrap.preflightApply(profile: webForwards.profile)
                                    let (browser, routing) = try browserBootstrap.resolve(profile: webForwards.profile)
                                    if confirm("Apply browser routing?", "\(browser.choice.name): \(routing.profilePath)\nWorkstation: \(webForwards.profile.name)\nThis explicitly replaces this proxy scope's workstation owner. Matching domains fail while disconnected; public sites stay direct. The original proxy values remain available through Restore.") {
                                        try browserBootstrap.applyExisting(profile: webForwards.profile)
                                    }
                                } catch { showBrowserError(error) }
                            }
                            .disabled(webForwards.pendingProfile != nil)
                            Button("Restore Browser Settings") {
                                do {
                                    if confirm("Restore browser proxy settings?", "Close Zen first. Restore keeps unrelated preferences and refuses newer proxy changes.") {
                                        try browserBootstrap.restore(profile: webForwards.profile)
                                    }
                                } catch { showBrowserError(error) }
                            }
                        }
                    }
                }
            }

            if let webForwards, webForwards.pendingProfile != nil {
                Text("Saved web-forward changes pending")
                Button("Apply Changes") { applyBrowserChanges(webForwards) }
                    .disabled(webForwards.isOpeningBrowser)
            }

            Divider()

            Button("Show Log") {
                openWindow(id: SSMConnectWindow.log)
            }

            SettingsLink {
                Text("Settings")
            }
            .keyboardShortcut(",")

            Button("About") {
                openWindow(id: SSMConnectWindow.about)
                NSApplication.shared.activate(ignoringOtherApps: true)
            }

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .onAppear(perform: applyLatestConfiguration)
        .onChange(of: store.activeProfile) { applyLatestConfiguration() }
        .onChange(of: store.settings) { applyLatestConfiguration() }
    }

    private func applyLatestConfiguration() {
        machine.apply(profile: store.activeProfile, settings: store.settings)
        webForwards?.apply(profile: store.activeProfile, settings: store.settings)
        remoteDevelopment?.apply(profile: store.activeProfile)
        if webForwards?.profile.webForwards?.enabled == true { webForwards?.preparePAC() }
    }

    private func openBrowser(_ web: WebForwardsStateMachine) {
        do {
            guard web.pendingProfile == nil else { throw BrowserBootstrapError.pendingChanges }
            if web.profile.webForwards?.browserMode == nil {
                let alert = NSAlert()
                alert.messageText = "Choose a browser mode"
                alert.informativeText = "Separate Browser keeps its own logins. Use My Browser requires explicit Zen profile setup in Settings."
                alert.addButton(withTitle: "Separate Browser")
                alert.addButton(withTitle: "Use My Browser")
                alert.addButton(withTitle: "Cancel")
                let result = alert.runModal()
                guard result != .alertThirdButtonReturn else { return }
                var profile = web.profile
                profile.webForwards?.browserMode = result == .alertFirstButtonReturn ? .separate : .existing
                guard store.updateProfile(profile) else {
                    throw PortableProfileError.invalid(store.operationError ?? "The profile could not be saved.")
                }
                web.apply(profile: profile, settings: store.settings)
            }
            try browserBootstrap.preflight(profile: web.profile)
            if try browserBootstrap.needsSetup(profile: web.profile) {
                let (browser, routing) = try browserBootstrap.resolve(profile: web.profile)
                let scope = "\(browser.choice.name): \(routing.profilePath)\nWorkstation: \(web.profile.name)\n"
                guard confirm("Set up browser proxy settings?", scope
                    + "This changes only this profile's proxy routing. Matching domains keep using 127.0.0.1:\(routing.port) and fail while disconnected, even after quitting SSM Connect. Other sites stay direct. Logins are not imported or read. Restore is explicit.") else { return }
                try browserBootstrap.setupExisting(profile: web.profile, consent: true)
            }
            web.openBrowser(using: browserBootstrap)
        } catch { showBrowserError(error) }
    }

    private func applyBrowserChanges(_ web: WebForwardsStateMachine) {
        guard let profile = web.pendingProfile else { return }
        do {
            if profile.webForwards?.socksPort != nil && profile.webForwards?.browserMode != nil {
                try browserBootstrap.preflightApply(profile: profile)
            }
            guard confirm("Apply saved changes?", "This reconnects web forwards with the saved settings. Close the routed browser first; its tabs and logins remain in its profile. DCV stays connected.") else { return }
            if profile.webForwards?.browserMode == .existing { try browserBootstrap.applyExisting(profile: profile) }
            Task { await web.applyPendingConfiguration() }
        } catch { showBrowserError(error) }
    }

    private func confirm(_ title: String, _ message: String) -> Bool {
        NSApplication.shared.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showBrowserError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Browser setup"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Synchronous confirmation before stopping the workstation (H6, F-15). An `NSAlert` is
    /// reliable from a menu-bar action; SwiftUI confirmation dialogs are awkward inside menus.
    private func confirmStopWorkstation() -> Bool {
        let alert = NSAlert()
        alert.messageText = "Stop the workstation?"
        alert.informativeText = "This stops the EC2 instance. Unsaved work in the session may be lost. "
            + "You can start it again by connecting."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Stop Workstation")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// Window identifiers for the app's auxiliary scenes.
public enum SSMConnectWindow {
    public static let log = "connection-log"
    public static let about = "about-ssm-connect"
}
