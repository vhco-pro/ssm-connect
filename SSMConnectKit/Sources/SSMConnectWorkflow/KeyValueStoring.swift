import Foundation
import SSMConnectDomain

/// The slice of `UserDefaults` that `ProfileStore` actually needs (G3, ADR-P2).
///
/// Exists so tests can persist into memory instead of the real preferences system. A
/// `UserDefaults(suiteName:)` is never truly throwaway: the suite is registered with `cfprefsd`
/// and flushed to `~/Library/Preferences/<suite>.plist` asynchronously, so a
/// `removePersistentDomain` in teardown races the daemon and leaves stray files on the
/// developer's machine. Injecting a store sidesteps that entirely.
package protocol KeyValueStoring: AnyObject {
    func data(forKey key: String) -> Data?
    func string(forKey key: String) -> String?
    func set(_ value: Any?, forKey key: String)
}

extension UserDefaults: KeyValueStoring {}

/// In-memory `KeyValueStoring` for tests and previews. Touches no files.
package final class InMemoryKeyValueStore: KeyValueStoring {
    private var storage: [String: Any] = [:]

    package init(storage: [String: Any] = [:]) { self.storage = storage }

    package func data(forKey key: String) -> Data? { storage[key] as? Data }

    package func string(forKey key: String) -> String? { storage[key] as? String }

    package func set(_ value: Any?, forKey key: String) {
        if let value {
            storage[key] = value
        } else {
            storage.removeValue(forKey: key)
        }
    }
}
