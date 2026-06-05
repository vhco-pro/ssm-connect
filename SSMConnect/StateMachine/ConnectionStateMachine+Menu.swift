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

    // 12-hour clock with explicit AM/PM (SSO sessions last ~12 h, so numerals can repeat).
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"
        return formatter
    }()
}
