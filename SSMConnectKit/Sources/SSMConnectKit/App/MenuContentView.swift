import SwiftUI

/// The MenuBarExtra dropdown content (H7, F-01/F-12). Factored into its own `View` so it can use
/// `@Environment(\.openWindow)` (Show Log) and `SettingsLink`. Re-applies the active profile /
/// settings each time it appears so a change in the Settings window takes effect on next connect.
public struct MenuContentView: View {
    @Bindable var machine: ConnectionStateMachine
    let store: ProfileStore
    @Environment(\.openWindow) private var openWindow

    public init(machine: ConnectionStateMachine, store: ProfileStore) {
        self.machine = machine
        self.store = store
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

            // Expandable legend: all 8 states behind a submenu (spec §5 icon table).
            Menu("All States") {
                ForEach(ConnectionState.allCases, id: \.self) { state in
                    Label {
                        Text(state.tooltip)
                    } icon: {
                        Image(systemName: state.sfSymbol)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(state.color)
                    }
                }
            }

            Divider()

            Button("Show Log") {
                openWindow(id: SSMConnectWindow.log)
            }

            SettingsLink {
                Text("Settings…")
            }
            .keyboardShortcut(",")

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        // Re-apply the latest active profile / settings each time the menu opens, so a change
        // made in the Settings window takes effect on the next connect (Phase G).
        .onAppear { machine.apply(profile: store.activeProfile, settings: store.settings) }
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
}
