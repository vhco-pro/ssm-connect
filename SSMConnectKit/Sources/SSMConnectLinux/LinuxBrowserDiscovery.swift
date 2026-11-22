#if os(Linux)
import Foundation
import SSMConnectDomain
import SSMConnectWorkflow

/// A browser installed on this Linux machine.
package struct LinuxBrowser: Equatable, Sendable {
    package let choice: ManagedBrowserChoice
    package let executable: URL
    package let version: String
}

/// Chrome and Zen discovery on Linux. As on macOS and Windows, each product and mode is supported
/// only at the exact version its native Linux tests passed on (`pinnedVersions`); any other
/// version, and any other product or packaging (Flatpak and Snap builds start through their own
/// launchers), is unavailable. Chrome supports Separate Browser; Zen supports both modes.
package struct LinuxBrowserDiscovery: Sendable {
    /// Where to look: Chrome executables, and folders holding Zen's `zen` and application.ini.
    package struct Candidates: Sendable {
        package var chrome: [URL]
        package var zen: [URL]

        package init(chrome: [URL], zen: [URL]) {
            self.chrome = chrome
            self.zen = zen
        }

        /// Google's RPM and DEB packages, and Zen's per-user tarball install or a system copy.
        package static func standard(home: URL) -> Candidates {
            Candidates(chrome: [URL(fileURLWithPath: "/opt/google/chrome/chrome")],
                       zen: [home.appendingPathComponent(".tarball-installations/zen", isDirectory: true),
                             URL(fileURLWithPath: "/opt/zen", isDirectory: true)])
        }
    }

    /// Versions recorded by the Linux native acceptance run (T29): Chrome from Google's DEB package
    /// on Ubuntu 24.04. Zen is not pinned, because no Linux run has tested its tarball install.
    package static let pinnedVersions: [ManagedBrowserChoice: Set<String>] = [.chrome: ["158.0.8127.36"]]

    package var candidates: Candidates
    package var pinned: [ManagedBrowserChoice: Set<String>]
    package var chromeVersion: @Sendable (URL) -> String?

    package init(candidates: Candidates = .standard(home: LinuxPaths().home),
                 pinned: [ManagedBrowserChoice: Set<String>] = LinuxBrowserDiscovery.pinnedVersions,
                 chromeVersion: @escaping @Sendable (URL) -> String? = LinuxBrowserDiscovery.runChromeVersion) {
        self.candidates = candidates
        self.pinned = pinned
        self.chromeVersion = chromeVersion
    }

    /// Installed Chrome and Zen, with their versions.
    package func installed() -> [LinuxBrowser] {
        var found: [LinuxBrowser] = []
        for chrome in candidates.chrome where FileManager.default.isExecutableFile(atPath: chrome.path) {
            if let version = chromeVersion(chrome) { found.append(LinuxBrowser(choice: .chrome, executable: chrome, version: version)) }
        }
        for directory in candidates.zen {
            let zen = directory.appendingPathComponent("zen")
            if FileManager.default.isExecutableFile(atPath: zen.path), let version = BrowserVersions.zen(in: directory) {
                found.append(LinuxBrowser(choice: .zen, executable: zen, version: version))
            }
        }
        return found
    }

    /// Installed browsers at a pinned version.
    package func installedSupported() -> [LinuxBrowser] {
        installed().filter { pinned[$0.choice]?.contains($0.version) == true }
    }

    /// The installed, pinned browser for a profile's choice and mode, or nil when unavailable.
    package func supported(_ choice: ManagedBrowserChoice, mode: BrowserMode) -> LinuxBrowser? {
        guard choice == .zen || (choice == .chrome && mode == .separate) else { return nil }
        return installedSupported().first { $0.choice == choice }
    }

    /// The four-part version in `chrome --version` output, such as "Google Chrome 131.0.6778.85".
    package static func parseChromeVersion(_ output: String) -> String? {
        output.split(whereSeparator: \.isWhitespace).map(String.init).last { token in
            let parts = token.split(separator: ".")
            return parts.count == 4 && parts.allSatisfy { Int($0) != nil }
        }
    }

    /// Chrome on Linux keeps no version file, so its version comes from `--version`.
    package static func runChromeVersion(_ executable: URL) -> String? {
        let process = ChildProcess(executable: executable.path, arguments: ["--version"], captureOutput: true)
        guard (try? process.run()) != nil else { return nil }
        let data = process.capturedOutput()
        guard process.terminationStatus == 0 else { return nil }
        return parseChromeVersion(String(decoding: data, as: UTF8.self))
    }
}
#endif
