import AppKit
import Foundation

/// `Pasteboard` backed by the general `NSPasteboard`.
struct NSPasteboardAdapter: Pasteboard {
    func setString(_ value: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(value, forType: .string)
    }

    func currentString() -> String? {
        NSPasteboard.general.string(forType: .string)
    }
}
