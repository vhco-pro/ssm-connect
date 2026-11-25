import Foundation
import SSMConnectDomain

/// App launch and quit hooks the workflows register with; each platform shell runs them.
@MainActor
package final class AppLaunchHandler {
    package static let shared = AppLaunchHandler()
    private var handlers: [(Bool) -> Void] = []
    package func register(_ handler: @escaping (Bool) -> Void) { handlers.append(handler) }
    package func run(explicit: Bool) { handlers.forEach { $0(explicit) } }

    package init() {}
}

/// Runs registered shutdown work when the app quits. The `ConnectionStateMachine` registers a
/// closure that kills the bundled `session-manager-plugin` child so it isn't orphaned holding the
/// local port (F-13). `applicationWillTerminate` can't await, so the work is synchronous.
@MainActor
package final class AppQuitHandler {
    package static let shared = AppQuitHandler()
    private var handlers: [() -> Void] = []

    package func register(_ handler: @escaping () -> Void) { handlers.append(handler) }
    package func runShutdown() { handlers.forEach { $0() } }

    package init() {}
}
