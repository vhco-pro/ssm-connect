import Foundation

/// Global app settings that influence the connection lifecycle (F-03, F-13, NF-03).
///
/// Phase F uses the connection-relevant flags below; Phase G (Task G2) adds persistence
/// (`UserDefaults`), the settings UI, and the clipboard auto-clear delay binding.
public struct AppSettings: Equatable, Codable, Sendable {
    /// Trigger `connect()` automatically on app launch (F-03).
    package var autoConnect: Bool = false
    /// Retry the tunnel automatically if it drops unexpectedly (F-13).
    package var autoReconnect: Bool = true
    /// Seconds before the clipboard auto-clears after copying the DCV password (0 = disabled, NF-03).
    package var clipboardAutoClearSeconds: Int = 30

    package static let `default` = AppSettings()

    package init(autoConnect: Bool = false, autoReconnect: Bool = true, clipboardAutoClearSeconds: Int = 30) {
        self.autoConnect = autoConnect
        self.autoReconnect = autoReconnect
        self.clipboardAutoClearSeconds = clipboardAutoClearSeconds
    }
}
