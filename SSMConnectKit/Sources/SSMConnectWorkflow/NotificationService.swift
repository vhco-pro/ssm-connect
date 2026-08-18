import Foundation
import SSMConnectDomain

/// Key lifecycle events surfaced as macOS notifications (H4, F-20).
public enum NotificationEvent: Equatable, Sendable {
    case connected
    case stopped
    case reconnecting
    case signInRequired

    public var title: String {
        switch self {
        case .connected: "Connected to workstation"
        case .stopped: "Workstation stopped"
        case .reconnecting: "Tunnel disconnected — reconnecting…"
        case .signInRequired: "SSO login required"
        }
    }

    public var body: String {
        switch self {
        case .connected: "Your SSM tunnel is up and DCV is launching."
        case .stopped: "The workstation instance has been stopped."
        case .reconnecting: "The tunnel dropped. Attempting to reconnect…"
        case .signInRequired: "Your AWS SSO session expired. Re-authenticating…"
        }
    }
}

