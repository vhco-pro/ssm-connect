import SwiftUI

// Task A1, A3 — SwiftUI App lifecycle, MenuBarExtra (F-01, NF-10, NF-11)
// The menu shows a single current-state header + a context-aware primary action,
// with the full 8-state list tucked behind an expandable "All States" submenu
// (legend). Phase F's ConnectionStateMachine will drive `auth.connectionState`.
@main
struct SSMConnectApp: App {
    // Task B5 — auth scaffold driving the menu until the full state machine lands (Phase F).
    @State private var auth = AuthViewModel()

    var body: some Scene {
        // F-01: MenuBarExtra provides a menu-bar-only presence (no Dock icon via LSUIElement=true)
        MenuBarExtra {
            // Header: the CURRENT connection state only (icon + label), non-interactive.
            Label {
                Text(auth.connectionState.tooltip)
            } icon: {
                Image(systemName: auth.connectionState.sfSymbol)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(auth.connectionState.color)
            }
            .disabled(true)

            // Secondary detail line: session expiry, or the last error message.
            if let detail = auth.detailLine {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Context-aware primary action (Connect / Connecting… / Connected / Retry).
            Button(auth.actionTitle) {
                auth.signIn()
            }
            .disabled(!auth.actionEnabled)

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
            Image(systemName: auth.connectionState.sfSymbol)
        }
    }
}
