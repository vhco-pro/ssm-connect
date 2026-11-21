import Foundation
import UserNotifications
import SSMConnectAWS
import SSMConnectDomain
import SSMConnectWorkflow

/// `UNUserNotificationCenter`-backed implementation (F-20).
package struct UserNotificationService: Notifying {
    package func requestAuthorization() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
    }

    package func post(_ event: NotificationEvent) async {
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

    package init() {}
}
