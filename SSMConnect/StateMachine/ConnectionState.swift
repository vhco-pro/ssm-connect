import SwiftUI

// Task A4 — 8-state connection lifecycle enum per spec §5 icon table
// Each case maps to an SF Symbol name + color + tooltip string.
// The enum is CaseIterable for exhaustive iteration (e.g. placeholder menu, tests).
enum ConnectionState: String, CaseIterable {
    case disconnected    // F-01: idle / not connected
    case authenticating  // F-04, F-05: SSO login in progress
    case resolving       // F-06: DescribeInstances by tag
    case starting        // F-07: StartInstances + polling
    case waitingForSSM   // F-08: DescribeInstanceInformation polling
    case tunneling       // F-09: StartSession + plugin launch
    case connected       // F-09, F-10: tunnel active
    case error           // any failure state

    // Spec §5: SF Symbol per state
    var sfSymbol: String {
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
    var color: Color {
        switch self {
        case .disconnected:   .gray
        case .authenticating, .resolving, .starting, .waitingForSSM, .tunneling: .yellow
        case .connected:      .green
        case .error:          .red
        }
    }

    // Spec §5: Tooltip per state
    var tooltip: String {
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

    /// Whether this state represents an in-progress (transitional) phase.
    var isTransitioning: Bool {
        switch self {
        case .authenticating, .resolving, .starting, .waitingForSSM, .tunneling: true
        case .disconnected, .connected, .error: false
        }
    }
}
