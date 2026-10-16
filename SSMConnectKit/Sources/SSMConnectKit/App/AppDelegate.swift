import AppKit
import Carbon

@MainActor
final class AppLaunchHandler {
    static let shared = AppLaunchHandler()
    private var handlers: [(Bool) -> Void] = []
    func register(_ handler: @escaping (Bool) -> Void) { handlers.append(handler) }
    func run(explicit: Bool) { handlers.forEach { $0(explicit) } }

    static func isExplicit(eventID: AEEventID?, loginFlag: Bool, propertyData: OSType?) -> Bool {
        eventID == kAEOpenApplication && !loginFlag && propertyData != keyAELaunchedAsLogInItem
    }
}

/// Runs registered shutdown work when the app quits. The `ConnectionStateMachine` registers a
/// closure that kills the bundled `session-manager-plugin` child so it isn't orphaned holding the
/// local port (F-13). `applicationWillTerminate` can't await, so the work is synchronous.
@MainActor
final class AppQuitHandler {
    static let shared = AppQuitHandler()
    private var handlers: [() -> Void] = []

    func register(_ handler: @escaping () -> Void) { handlers.append(handler) }
    func runShutdown() { handlers.forEach { $0() } }
}

/// Minimal app delegate: on quit, tear down the active tunnel so no plugin process is orphaned.
public final class AppDelegate: NSObject, NSApplicationDelegate {
    public override init() { super.init() }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            let event = NSAppleEventManager.shared().currentAppleEvent
            let explicit = AppLaunchHandler.isExplicit(eventID: event?.eventID,
                loginFlag: event?.paramDescriptor(forKeyword: AEKeyword(keyAELaunchedAsLogInItem)) != nil,
                propertyData: event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue)
            AppLaunchHandler.shared.run(explicit: explicit)
        }
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated { AppLaunchHandler.shared.run(explicit: true) }
        return true
    }

    public func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppQuitHandler.shared.runShutdown() }
    }
}
