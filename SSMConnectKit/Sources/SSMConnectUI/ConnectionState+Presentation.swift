import SwiftUI
import SSMConnectDomain
import SSMConnectWorkflow
import SSMConnectMacOS

/// How each connection state is drawn (spec §5 icon table).
///
/// Deliberately separate from the `ConnectionState` value itself: the enum is a domain type shared
/// with the Windows client through `contracts/`, and it cannot carry a SwiftUI `Color` without
/// dragging SwiftUI into the portable workflow (spec §5.2, MR-02). Everything here is macOS
/// presentation and has no cross-platform meaning — the Windows shell picks its own icons.
public extension ConnectionState {
    // Spec §5: SF Symbol per state
    public var sfSymbol: String {
        switch self {
        case .disconnected:   "desktopcomputer"
        case .authenticating: "person.badge.key"
        case .resolving:      "magnifyingglass"
        case .starting:       "power"
        case .waitingForSSM:  "antenna.radiowaves.left.and.right"
        case .tunneling:      "link"
        case .connected:      "desktopcomputer.and.arrow.down"
        case .error:          "exclamationmark.triangle"
        }
    }

    // Spec §5: Color per state
    public var color: Color {
        switch self {
        case .disconnected:   .gray
        case .authenticating, .resolving, .starting, .waitingForSSM, .tunneling: .yellow
        case .connected:      .green
        case .error:          .red
        }
    }

    // Spec §5: Tooltip per state
    public var tooltip: String {
        switch self {
        case .disconnected:   "Workstation — Disconnected"
        case .authenticating: "Workstation — Signing in…"
        case .resolving:      "Workstation — Finding instance…"
        case .starting:       "Workstation — Starting instance…"
        case .waitingForSSM:  "Workstation — Waiting for SSM…"
        case .tunneling:      "Workstation — Opening tunnel…"
        case .connected:      "Workstation — Connected"
        case .error:          "Workstation — Error"
        }
    }
}
