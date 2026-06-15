import Foundation

/// Menu-facing presentation helpers for `ConnectionStateMachine` (spec §5 dropdown layout).
extension ConnectionStateMachine {
    /// Title for the primary action button, context-aware per the current state.
    var actionTitle: String {
        switch state {
        case .disconnected: "Connect"
        case .authenticating, .resolving, .starting, .waitingForSSM, .tunneling: "Connecting…"
        case .connected: "Connected"
        case .error: "Retry Connect"
        }
    }

    /// Whether the primary action button is tappable.
    var actionEnabled: Bool {
        switch state {
        case .disconnected, .error: true
        case .authenticating, .resolving, .starting, .waitingForSSM, .tunneling, .connected: false
        }
    }

    /// Secondary, greyed detail line under the header (nil = hidden).
    var detailLine: String? {
        if state == .error { return errorMessage }
        if state == .connected {
            if let warningMessage { return warningMessage }
            if let expiry = credentialsExpiry {
                return "Connected · session expires \(Self.timeFormatter.string(from: expiry))"
            }
            return "Connected"
        }
        return nil
    }

    /// Run the primary action for the current state.
    func primaryAction() {
        switch state {
        case .disconnected, .error: connect()
        default: break
        }
    }

    /// Connection status detail lines for the menu when connected (F-12): instance id + state,
    /// tunnel pid/port, and elapsed connection time.
    var connectionDetailLines: [String] {
        guard state == .connected else { return [] }
        var lines: [String] = []
        if let instanceId {
            if let instanceState {
                lines.append("Instance: \(instanceId) (\(instanceState.rawValue))")
            } else {
                lines.append("Instance: \(instanceId)")
            }
        }
        if let tunnelPID, let localPort {
            lines.append("Tunnel: pid \(tunnelPID) · localhost:\(localPort)")
        }
        if let connectedAt {
            lines.append("Up \(Self.elapsed(since: connectedAt))")
        }
        return lines
    }

    /// Masked DCV password for the menu (F-12); nil when no password is held.
    var maskedPassword: String? {
        guard let password, !password.isEmpty else { return nil }
        return String(repeating: "•", count: min(password.count, 12))
    }

    private static func elapsed(since start: Date) -> String {
        let seconds = Int(Date().timeIntervalSince(start))
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let secs = seconds % 60
        if hours > 0 { return String(format: "%dh %02dm", hours, minutes) }
        if minutes > 0 { return String(format: "%dm %02ds", minutes, secs) }
        return "\(secs)s"
    }

    // 12-hour clock with explicit AM/PM (SSO sessions last ~12 h, so numerals can repeat).
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"
        return formatter
    }()
}
