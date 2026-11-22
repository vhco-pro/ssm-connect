#if os(Windows)
import Foundation
import SSMConnectWorkflow

/// The key-value store on Windows: `FileKeyValueStore` in the user's local application data,
/// rewritten atomically with an owner-only DACL on every change.
package enum WindowsKeyValueStore {
    /// `%LOCALAPPDATA%\SSM Connect\settings.json`.
    package static var defaultURL: URL {
        let base = ProcessInfo.processInfo.environment["LOCALAPPDATA"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("SSM Connect", isDirectory: true).appendingPathComponent("settings.json")
    }

    package static func make(url: URL = defaultURL) -> FileKeyValueStore {
        FileKeyValueStore(url: url, write: { try WindowsPrivateFiles.write($0, to: $1) })
    }
}
#endif
