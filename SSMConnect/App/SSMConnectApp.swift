import SwiftUI

// Task A1, A3 — SwiftUI App lifecycle, MenuBarExtra (F-01, NF-10, NF-11)
// Phase A: static placeholder menu displaying the 8 SF Symbol states from spec §5.
// The menu-bar icon uses the disconnected state by default; later phases wire the
// ConnectionStateMachine to drive icon + menu content dynamically.
@main
struct SSMConnectApp: App {
    var body: some Scene {
        // F-01: MenuBarExtra provides a menu-bar-only presence (no Dock icon via LSUIElement=true)
        MenuBarExtra {
            // Task A3 — Placeholder menu showing all 8 connection states (spec §5 icon table)
            Section("Connection States") {
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
            // Menu-bar icon: disconnected state as default placeholder
            Image(systemName: ConnectionState.disconnected.sfSymbol)
        }
    }
}
