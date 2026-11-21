import AppKit
import Carbon
import SSMConnectAWS
import SSMConnectDomain
import SSMConnectWorkflow

extension AppLaunchHandler {
    package static func isExplicit(eventID: AEEventID?, loginFlag: Bool, propertyData: OSType?) -> Bool {
        eventID == kAEOpenApplication && !loginFlag && propertyData != keyAELaunchedAsLogInItem
    }
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
