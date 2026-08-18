import Foundation
import SSMConnectDomain

/// Abstraction over the macOS pasteboard so `ClipboardManager` is testable without AppKit (E8).
public protocol PasteboardWriting: Sendable {
    func setString(_ value: String)
    func currentString() -> String?
}

/// Copies the DCV password to the clipboard (so the user can paste it for the in-VM desktop login)
/// with optional auto-clear hygiene (E8, F-11, NF-03).
public final class ClipboardManager: @unchecked Sendable {
    private let pasteboard: PasteboardWriting
    /// Auto-clear delay; `nil` or `<= .zero` disables clearing. Mutable so it can be synced from
    /// `AppSettings.clipboardAutoClearSeconds` while the app runs (see `setAutoClear(seconds:)`).
    private var autoClearAfter: Duration?
    private let lock = NSLock()
    private var pendingClear: Task<Void, Never>?

    public init(pasteboard: PasteboardWriting, autoClearAfter: Duration? = .seconds(30)) {
        self.pasteboard = pasteboard
        self.autoClearAfter = autoClearAfter
    }

    /// Sync the auto-clear delay from settings; `seconds <= 0` disables auto-clear (NF-03).
    public func setAutoClear(seconds: Int) {
        lock.lock(); defer { lock.unlock() }
        autoClearAfter = seconds > 0 ? .seconds(seconds) : nil
    }

    /// Copy `value` and (if enabled) schedule an auto-clear. Returns the clear task for testing.
    @discardableResult
    public func copy(_ value: String) -> Task<Void, Never>? {
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
    public func clearIfStillPresent(_ value: String) {
        if pasteboard.currentString() == value {
            pasteboard.setString("")
        }
    }
}
