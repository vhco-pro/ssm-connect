import Foundation
import Testing
@testable import SSMConnect

/// In-memory `Pasteboard` for clipboard tests.
final class FakePasteboard: Pasteboard, @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    func setString(_ value: String) { lock.lock(); self.value = value; lock.unlock() }
    func currentString() -> String? { lock.lock(); defer { lock.unlock() }; return value }
}

@Suite("ClipboardManager")
struct ClipboardManagerTests {
    @Test("copy places the value on the pasteboard")
    func copySetsValue() {
        let pb = FakePasteboard()
        let manager = ClipboardManager(pasteboard: pb, autoClearAfter: nil)
        manager.copy("hunter2")
        #expect(pb.currentString() == "hunter2")
    }

    @Test("auto-clear empties the pasteboard after the delay")
    func autoClears() async {
        let pb = FakePasteboard()
        let manager = ClipboardManager(pasteboard: pb, autoClearAfter: .milliseconds(5))
        let task = manager.copy("hunter2")
        await task?.value
        #expect(pb.currentString() == "")
    }

    @Test("auto-clear does not clobber a value the user copied afterward")
    func doesNotClobberLaterValue() async {
        let pb = FakePasteboard()
        let manager = ClipboardManager(pasteboard: pb, autoClearAfter: .milliseconds(5))
        let task = manager.copy("hunter2")
        pb.setString("something else")
        await task?.value
        #expect(pb.currentString() == "something else")
    }

    @Test("disabled auto-clear leaves the value in place")
    func disabledAutoClear() async {
        let pb = FakePasteboard()
        let manager = ClipboardManager(pasteboard: pb, autoClearAfter: nil)
        let task = manager.copy("hunter2")
        #expect(task == nil)
        #expect(pb.currentString() == "hunter2")
    }
}
