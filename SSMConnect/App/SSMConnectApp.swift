import SwiftUI

// Task A1, A3 — SwiftUI App lifecycle, MenuBarExtra (F-01, NF-10, NF-11)
// The menu shows a single current-state header + a context-aware primary action,
// with the full 8-state list tucked behind an expandable "All States" submenu
// (legend). The ConnectionStateMachine (Phase F) drives the whole flow; the
// ProfileStore (Phase G) supplies the active profile + global settings.
@main
struct SSMConnectApp: App {
    // Phase G — persisted profiles + settings. No profile is baked in; first launch starts
    // empty and the menu/Settings guide the user to import one from ~/.aws/config (F-18).
    @State private var store: ProfileStore
    // Task F1 — the full connection state machine drives the menu + menu-bar icon.
    @State private var machine: ConnectionStateMachine
    private let loginItem: LoginItemControlling = SMAppServiceLoginItem()

    init() {
        let store = ProfileStore()
        let machine = ConnectionStateMachine(profile: store.activeProfile, settings: store.settings)
        _store = State(initialValue: store)
        _machine = State(initialValue: machine)
        machine.onLaunch()
    }

    var body: some Scene {
        // F-01: MenuBarExtra provides a menu-bar-only presence (no Dock icon via LSUIElement=true)
        MenuBarExtra {
            MenuContentView(machine: machine, store: store)
        } label: {
            // Menu-bar icon reflects the current connection state.
            Image(systemName: machine.state.sfSymbol)
        }

        // Phase G — standard Settings window (⌘,): profiles + global settings + login item.
        Settings {
            SettingsView(store: store, loginItem: loginItem)
        }

        // Phase H — connection-log window (F-19), opened from "Show Log".
        Window("Connection Log", id: SSMConnectWindow.log) {
            LogView(log: machine.log)
        }
        .windowResizability(.contentMinSize)
    }
}


