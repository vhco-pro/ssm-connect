import Foundation

/// Abstraction over the macOS pasteboard so `ClipboardManager` is testable without AppKit (E8).
protocol Pasteboard: Sendable {
    func setString(_ value: String)
    func currentString() -> String?
}

/// Copies the DCV password to the clipboard (so the user can paste it for the in-VM desktop login)
/// with optional auto-clear hygiene (E8, F-11, NF-03).
final class ClipboardManager: @unchecked Sendable {
    private let pasteboard: Pasteboard
    /// Auto-clear delay; `nil` or `<= .zero` disables clearing.
    private let autoClearAfter: Duration?
    private let lock = NSLock()
    private var pendingClear: Task<Void, Never>?

    init(pasteboard: Pasteboard = NSPasteboardAdapter(), autoClearAfter: Duration? = .seconds(30)) {
        self.pasteboard = pasteboard
        self.autoClearAfter = autoClearAfter
    }

    /// Copy `value` and (if enabled) schedule an auto-clear. Returns the clear task for testing.
    @discardableResult
    func copy(_ value: String) -> Task<Void, Never>? {
        pasteboard.setString(value)

        lock.lock()
        pendingClear?.cancel()
        guard let delay = autoClearAfter, delay > .zero else {
            pendingClear = nil
            lock.unlock()
            return nil
        }
        let task = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.clearIfStillPresent(value)
        }
        pendingClear = task
        lock.unlock()
        return task
    }

    /// Clear the clipboard only if it still holds `value` (don't clobber what the user copied later).
    func clearIfStillPresent(_ value: String) {
        if pasteboard.currentString() == value {
            pasteboard.setString("")
        }
    }
}
