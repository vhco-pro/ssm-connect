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

/// Posts macOS notifications for key events (H4, F-20). Protocol-based for testability (ADR-P2).
public protocol Notifying: Sendable {
    /// Request notification authorization once (no-op if already decided).
    func requestAuthorization() async
    /// Post a notification for `event`, respecting the user's macOS notification settings.
    func post(_ event: NotificationEvent) async
}


/// No-op notifier (tests / previews / when notifications are undesirable).
public struct SilentNotificationService: Notifying {
    public init() {}

    public func requestAuthorization() async {}
    public func post(_ event: NotificationEvent) async {}
}
