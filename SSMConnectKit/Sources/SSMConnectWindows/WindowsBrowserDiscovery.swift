#if os(Windows)
import Foundation
import SSMConnectDomain
import SSMConnectWorkflow

/// A browser installed on this Windows machine.
package struct WindowsBrowser: Equatable, Sendable {
    package let choice: ManagedBrowserChoice
    package let executable: URL
    package let version: String
}

/// Chrome and Zen discovery on Windows. As on macOS, each product and mode is supported only at
/// the exact version its native Windows tests passed on (`pinnedVersions`); any other version,
/// and any other product, is unavailable. Chrome supports Separate Browser; Zen supports both
/// Separate Browser and Use My Browser.
package struct WindowsBrowserDiscovery: Sendable {
    /// Versions recorded by the Windows native acceptance run (T28): a browser is offered for
    /// managed browsing only at a version that passed there.
    package static let pinnedVersions: [ManagedBrowserChoice: Set<String>] = [.chrome: ["158.0.8127.37"]]

    package var environment: [String: String]
    package var pinned: [ManagedBrowserChoice: Set<String>]

    package init(environment: [String: String] = ProcessInfo.processInfo.environment,
                 pinned: [ManagedBrowserChoice: Set<String>] = WindowsBrowserDiscovery.pinnedVersions) {
        self.environment = environment
        self.pinned = pinned
    }

    private func roots(_ variables: String...) -> [URL] {
        variables.compactMap { environment[$0] }.map { URL(fileURLWithPath: $0) }
    }

    /// Installed Chrome and Zen, with their versions.
    package func installed() -> [WindowsBrowser] {
        var found: [WindowsBrowser] = []
        for root in roots("ProgramFiles", "ProgramFiles(x86)", "LOCALAPPDATA") {
            let application = root.appendingPathComponent("Google/Chrome/Application", isDirectory: true)
            let chrome = application.appendingPathComponent("chrome.exe")
            if FileManager.default.fileExists(atPath: chrome.path), let version = Self.chromeVersion(in: application) {
                found.append(WindowsBrowser(choice: .chrome, executable: chrome, version: version))
            }
        }
        for root in roots("ProgramFiles", "LOCALAPPDATA") {
            let directory = root.appendingPathComponent("Zen Browser", isDirectory: true)
            let zen = directory.appendingPathComponent("zen.exe")
            if FileManager.default.fileExists(atPath: zen.path), let version = Self.zenVersion(in: directory) {
                found.append(WindowsBrowser(choice: .zen, executable: zen, version: version))
            }
        }
        return found
    }

    /// Installed browsers at a pinned version.
    package func installedSupported() -> [WindowsBrowser] {
        installed().filter { pinned[$0.choice]?.contains($0.version) == true }
    }

    /// The installed, pinned browser for a profile's choice and mode, or nil when unavailable.
    package func supported(_ choice: ManagedBrowserChoice, mode: BrowserMode) -> WindowsBrowser? {
        guard choice == .zen || (choice == .chrome && mode == .separate) else { return nil }
        return installedSupported().first { $0.choice == choice }
    }

    /// Chrome keeps each version in a folder named after it beside chrome.exe; the highest one
    /// holding chrome.dll is the installed version.
    static func chromeVersion(in application: URL) -> String? {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: application.path)) ?? []
        return names.filter { name in
            name.split(separator: ".").count == 4 && name.split(separator: ".").allSatisfy { Int($0) != nil }
                && FileManager.default.fileExists(atPath: application.appendingPathComponent(name).appendingPathComponent("chrome.dll").path)
        }.max { lhs, rhs in
            lhs.split(separator: ".").map { Int($0)! }.lexicographicallyPrecedes(rhs.split(separator: ".").map { Int($0)! })
        }
    }

    /// Zen records its version in application.ini beside zen.exe.
    static func zenVersion(in directory: URL) -> String? { BrowserVersions.zen(in: directory) }
}
#endif
