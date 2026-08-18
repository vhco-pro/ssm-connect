import Foundation
import SSMConnectWorkflow

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
