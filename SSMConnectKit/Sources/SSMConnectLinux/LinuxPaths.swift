#if os(Linux)
import Foundation
import SSMConnectWorkflow

/// Where SSM Connect keeps its files on Linux, by the XDG base directory specification: settings
/// in `$XDG_CONFIG_HOME/ssm-connect` (default `~/.config/ssm-connect`), and transport state
/// (DCV files, PAC files, editor leases) in `$XDG_STATE_HOME/ssm-connect` (default
/// `~/.local/state/ssm-connect`). A relative XDG value is invalid and ignored, as the
/// specification requires.
package struct LinuxPaths: Sendable {
    package let home: URL
    package let config: URL
    package let state: URL

    package init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        let home = URL(fileURLWithPath: environment["HOME"] ?? NSHomeDirectory(), isDirectory: true)
        func base(_ variable: String, _ fallback: String) -> URL {
            if let value = environment[variable], value.hasPrefix("/") { return URL(fileURLWithPath: value, isDirectory: true) }
            return home.appendingPathComponent(fallback, isDirectory: true)
        }
        self.home = home
        config = base("XDG_CONFIG_HOME", ".config").appendingPathComponent("ssm-connect", isDirectory: true)
        state = base("XDG_STATE_HOME", ".local/state").appendingPathComponent("ssm-connect", isDirectory: true)
    }

    /// The key-value store's document.
    package var settings: URL { config.appendingPathComponent("settings.json") }
}

/// The key-value store on Linux: `FileKeyValueStore` in the settings folder, written user-only.
package enum LinuxKeyValueStore {
    package static func make(paths: LinuxPaths = LinuxPaths()) -> FileKeyValueStore {
        FileKeyValueStore(url: paths.settings, write: { try LinuxPrivateFiles.write($0, to: $1) })
    }
}
#endif
