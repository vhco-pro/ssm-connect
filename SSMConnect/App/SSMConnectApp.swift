import SwiftUI

// Task A1, A3 — SwiftUI App lifecycle, MenuBarExtra (F-01, NF-10, NF-11)
// The menu shows a single current-state header + a context-aware primary action,
// with the full 8-state list tucked behind an expandable "All States" submenu
// (legend). The ConnectionStateMachine (Phase F) drives the whole flow; the
// ProfileStore (Phase G) supplies the active profile + global settings.
@main
struct SSMConnectApp: App {
    // Phase G — persisted profiles + settings, seeded from ~/.aws/config on first launch.
    @State private var store: ProfileStore
    // Task F1 — the full connection state machine drives the menu + menu-bar icon.
    @State private var machine: ConnectionStateMachine
    private let loginItem: LoginItemControlling = SMAppServiceLoginItem()

    init() {
        let store = ProfileStore()
        store.seedIfEmpty()
        let machine = ConnectionStateMachine(profile: store.activeProfile, settings: store.settings)
        _store = State(initialValue: store)
        _machine = State(initialValue: machine)
        machine.onLaunch()
    }

    var body: some Scene {
        // F-01: MenuBarExtra provides a menu-bar-only presence (no Dock icon via LSUIElement=true)
        MenuBarExtra {
            menuContent
                // Re-apply the latest active profile / settings each time the menu opens, so a
                // change made in the Settings window takes effect on the next connect (Phase G).
                .onAppear { machine.apply(profile: store.activeProfile, settings: store.settings) }
        } label: {
            // Menu-bar icon reflects the current connection state.
            Image(systemName: machine.state.sfSymbol)
        }

        // Phase G — standard Settings window (⌘,): profiles + global settings + login item.
        Settings {
            SettingsView(store: store, loginItem: loginItem)
        }
    }

    @ViewBuilder
    private var menuContent: some View {
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

        Divider()

        // Context-aware primary action (Connect / Connecting… / Connected / Retry).
        Button(machine.actionTitle) {
            machine.primaryAction()
        }
        .disabled(!machine.actionEnabled)

        // Connected-only actions (F-11/F-14/F-15).
        if machine.state == .connected {
            if machine.password != nil {
                Button("Copy Password") { machine.copyPassword() }
            }
            Button("Reconnect") { machine.reconnect() }
            Button("Stop Workstation") { machine.stopWorkstation() }
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

        SettingsLink {
            Text("Settings…")
        }
        .keyboardShortcut(",")

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}


