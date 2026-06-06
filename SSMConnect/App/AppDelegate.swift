import AppKit

/// Runs registered shutdown work when the app quits. The `ConnectionStateMachine` registers a
/// closure that kills the bundled `session-manager-plugin` child so it isn't orphaned holding the
/// local port (F-13). `applicationWillTerminate` can't await, so the work is synchronous.
@MainActor
final class AppQuitHandler {
    static let shared = AppQuitHandler()
    private var handler: (() -> Void)?

    func register(_ handler: @escaping () -> Void) { self.handler = handler }
    func runShutdown() { handler?() }
}

/// Minimal app delegate: on quit, tear down the active tunnel so no plugin process is orphaned.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppQuitHandler.shared.runShutdown() }
    }
}
