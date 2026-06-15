import Foundation
import UserNotifications

/// Key lifecycle events surfaced as macOS notifications (H4, F-20).
enum NotificationEvent: Equatable, Sendable {
    case connected
    case stopped
    case reconnecting
    case signInRequired

    var title: String {
        switch self {
        case .connected: "Connected to workstation"
        case .stopped: "Workstation stopped"
        case .reconnecting: "Tunnel disconnected — reconnecting…"
        case .signInRequired: "SSO login required"
        }
    }

    var body: String {
        switch self {
        case .connected: "Your SSM tunnel is up and DCV is launching."
        case .stopped: "The workstation instance has been stopped."
        case .reconnecting: "The tunnel dropped. Attempting to reconnect…"
        case .signInRequired: "Your AWS SSO session expired. Re-authenticating…"
        }
    }
}

/// Posts macOS notifications for key events (H4, F-20). Protocol-based for testability (ADR-P2).
protocol Notifying: Sendable {
    /// Request notification authorization once (no-op if already decided).
    func requestAuthorization() async
    /// Post a notification for `event`, respecting the user's macOS notification settings.
    func post(_ event: NotificationEvent) async
}

/// `UNUserNotificationCenter`-backed implementation (F-20).
struct UserNotificationService: Notifying {
    func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
    }

    func post(_ event: NotificationEvent) async {
        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        try? await UNUserNotificationCenter.current().add(request)
    }
}

/// No-op notifier (tests / previews / when notifications are undesirable).
struct SilentNotificationService: Notifying {
    func requestAuthorization() async {}
    func post(_ event: NotificationEvent) async {}
}
