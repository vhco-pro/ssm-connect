import AppKit
import Foundation
import SSMConnectAWS
import SSMConnectDomain
import SSMConnectWorkflow

/// `Pasteboard` backed by the general `NSPasteboard`.
package struct NSPasteboardAdapter: SSMConnectWorkflow.Pasteboard {
    package func setString(_ value: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(value, forType: .string)
    }

    package func currentString() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    package init() {}
}
