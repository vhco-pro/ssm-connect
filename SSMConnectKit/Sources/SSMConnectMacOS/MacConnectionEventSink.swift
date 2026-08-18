import Foundation
import SSMConnectDomain
import SSMConnectWorkflow

/// The macOS shell's response to what the connection flow reports (§7, §5.2).
///
/// Everything here is platform policy that used to sit inside the flow: putting the DCV password on
/// the pasteboard, scheduling its auto-clear, and posting user notifications. Moving it out is what
/// lets `SSMConnectWorkflow` compile without a clipboard or a notification framework, and it is the
/// same division `SSMConnect.Workflow` already had on the .NET side.
@MainActor
public final class MacConnectionEventSink: ConnectionEventSink {
    private let clipboard: ClipboardManager
    private let notifier: any Notifying

    public init(
        clipboard: ClipboardManager = ClipboardManager(pasteboard: NSPasteboardAdapter()),
        notifier: any Notifying = UserNotificationService()
    ) {
        self.clipboard = clipboard
        self.notifier = notifier
    }

    /// Ask for notification permission once. Previously the flow did this on launch, which made a
    /// connection rule out of an app-lifecycle concern.
    public func requestNotificationAuthorization() {
        Task { await notifier.requestAuthorization() }
    }

    /// The app observes `ConnectionStateMachine.state` through `@Observable`, so there is nothing to
    /// forward here. The method still exists because the port is shared with the Windows client,
    /// whose shell does need the push.
    public func stateChanged(_ state: ConnectionState) {}

    public func notify(_ event: NotificationEvent) {
        Task { await notifier.post(event) }
    }

    /// Copy the password so the user can paste it into the in-VM desktop login (F-11). The flow
    /// reports that a password exists; whether it reaches the pasteboard is decided here.
    public func passwordAvailable(_ password: String) {
        clipboard.copy(password)
    }

    public func settingsChanged(_ settings: AppSettings) {
        clipboard.setAutoClear(seconds: settings.clipboardAutoClearSeconds)
    }
}
