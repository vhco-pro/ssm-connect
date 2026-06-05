import SwiftUI

// Task A1, A3 — SwiftUI App lifecycle, MenuBarExtra (F-01, NF-10, NF-11)
// The menu shows a single current-state header + a context-aware primary action,
// with the full 8-state list tucked behind an expandable "All States" submenu
// (legend). The ConnectionStateMachine (Phase F) drives the whole flow.
@main
struct SSMConnectApp: App {
    // Task F1 — the full connection state machine drives the menu + menu-bar icon.
    @State private var machine = ConnectionStateMachine()

    var body: some Scene {
        // F-01: MenuBarExtra provides a menu-bar-only presence (no Dock icon via LSUIElement=true)
        MenuBarExtra {
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

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        } label: {
            // Menu-bar icon reflects the current connection state.
            Image(systemName: machine.state.sfSymbol)
        }
    }
}

