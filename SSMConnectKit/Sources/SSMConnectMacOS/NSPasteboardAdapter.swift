import AppKit
import Foundation
import SSMConnectDomain
import SSMConnectWorkflow

/// `PasteboardWriting` backed by the general `NSPasteboard`.
public struct NSPasteboardAdapter: PasteboardWriting {
    public init() {}

    public func setString(_ value: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(value, forType: .string)
    }

    public func currentString() -> String? {
        NSPasteboard.general.string(forType: .string)
    }
}
