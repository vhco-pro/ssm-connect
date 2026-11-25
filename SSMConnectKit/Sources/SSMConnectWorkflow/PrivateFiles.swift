import Foundation
import SSMConnectDomain

package enum BrowserBootstrapError: LocalizedError {
    case unavailable, chooseMode, chooseProfile, conflict, closeBrowser, pendingChanges, launchFailed, interruptedSetup
    package var errorDescription: String? {
        switch self {
        case .unavailable: "This browser/mode is not verified. Choose Chrome (Separate Browser) or Zen, or use Advanced manual setup."
        case .chooseMode: "Choose Use My Browser or Separate Browser in Settings."
        case .chooseProfile: "Select the existing Zen profile folder in Settings."
        case .conflict: "Browser proxy settings, policy or ownership conflict. Nothing was replaced. Use Separate Browser or resolve the conflict first."
        case .closeBrowser: "Close this browser yourself, including its separate windows, then retry. SSM Connect never force-closes browsers."
        case .pendingChanges: "Saved browser routing is pending. Close the routed browser, then use Apply Changes."
        case .launchFailed: "Browser launch failed. The web tunnel is still connected."
        case .interruptedSetup: "Browser setup was interrupted. Close the browser and use Restore Browser Settings to recover its prior proxy settings."
        }
    }
}

/// Owner-only private files on every platform: mode 0700/0600 with an atomic rename on macOS,
/// `LinuxPrivateFiles` on Linux, a protected current-user DACL with `MoveFileExW` on Windows.
package enum BrowserPrivateFiles {
    package static func directory(_ url: URL) throws {
        #if os(Windows)
        return try WindowsPrivateFiles.directory(url)
        #elseif os(Linux)
        do { return try LinuxPrivateFiles.directory(url) }
        catch LinuxPrivateFiles.Failure.unsafe { throw BrowserBootstrapError.conflict }
        #else
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        #endif
    }
    package static func write(_ data: Data, to url: URL, createParent: Bool = true) throws {
        #if os(Windows)
        do { return try WindowsPrivateFiles.write(data, to: url, createParent: createParent) }
        catch WindowsPrivateFiles.Failure.reparsePoint { throw BrowserBootstrapError.conflict }
        #elseif os(Linux)
        do { return try LinuxPrivateFiles.write(data, to: url, createParent: createParent) }
        catch LinuxPrivateFiles.Failure.unsafe { throw BrowserBootstrapError.conflict }
        #else
        if createParent { try directory(url.deletingLastPathComponent()) }
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
            throw BrowserBootstrapError.conflict
        }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard FileManager.default.createFile(atPath: temporary.path, contents: data,
                                            attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if rename(temporary.path, url.path) != 0 { throw CocoaError(.fileWriteUnknown) }
        #endif
    }
    package static var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(Bundle.main.bundleIdentifier ?? "SSMConnect", isDirectory: true)
            .appendingPathComponent("Browsers", isDirectory: true)
    }
}

@MainActor package protocol BrowserOpening {
    func preflight(profile: ConnectionProfile) throws
    func open(profile: ConnectionProfile) async throws
    func restore(profile: ConnectionProfile) throws
}

/// Owner-only file checks the editor workflow relies on, from the platform: on macOS POSIX
/// ownership, permission bits and `fcntl` locks (`OwnerOnlyFiles.posix`).
package struct OwnerOnlyFiles: Sendable {
    /// Whether the file at the URL, whose `FileManager` attributes are given, is owned by the
    /// current user with no access for anyone else (POSIX mode bits, or a Windows DACL).
    package var isOwnerOnly: @Sendable (URL, [FileAttributeKey: Any]) -> Bool
    /// Runs `body` holding an exclusive lock on the owner-only lock file at `url`, created if
    /// missing; throws `RemoteSSHError.configurationConflict` when the file is unsafe or locked.
    package var withExclusiveLock: @Sendable (URL, () throws -> Void) throws -> Void

    package init(isOwnerOnly: @escaping @Sendable (URL, [FileAttributeKey: Any]) -> Bool,
                 withExclusiveLock: @escaping @Sendable (URL, () throws -> Void) throws -> Void) {
        self.isOwnerOnly = isOwnerOnly
        self.withExclusiveLock = withExclusiveLock
    }
}
