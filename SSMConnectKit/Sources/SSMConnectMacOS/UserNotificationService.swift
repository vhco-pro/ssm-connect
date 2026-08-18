import Foundation
import UserNotifications
import SSMConnectWorkflow
import SSMConnectDomain

/// `UNUserNotificationCenter`-backed implementation (F-20).
public struct UserNotificationService: Notifying {
    public init() {}

    public func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
    }

    public func post(_ event: NotificationEvent) async {
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
