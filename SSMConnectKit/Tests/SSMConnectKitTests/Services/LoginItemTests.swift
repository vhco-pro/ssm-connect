import Foundation
import Testing
@testable import SSMConnectKit

/// In-memory `LoginItemControlling` for tests (G9). Records the desired state without touching
/// the real `SMAppService` registration.
final class FakeLoginItem: LoginItemControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var enabled = false
    var setError: Error?

    var isEnabled: Bool { lock.lock(); defer { lock.unlock() }; return enabled }

    func setEnabled(_ enabled: Bool) throws {
        if let setError { throw setError }
        lock.lock(); self.enabled = enabled; lock.unlock()
    }
}

@Suite("LoginItem")
struct LoginItemTests {
    @Test("enabling and disabling toggles the reported status")
    func toggle() throws {
        let item = FakeLoginItem()
        #expect(item.isEnabled == false)
        try item.setEnabled(true)
        #expect(item.isEnabled == true)
        try item.setEnabled(false)
        #expect(item.isEnabled == false)
    }

    @Test("a failing registration leaves the status unchanged")
    func failureKeepsStatus() {
        let item = FakeLoginItem()
        struct Boom: Error {}
        item.setError = Boom()
        #expect(throws: Boom.self) { try item.setEnabled(true) }
        #expect(item.isEnabled == false)
    }
}
