import AppKit
import Foundation
import SSMConnectDomain
import SSMConnectWorkflow

/// Default `DCVLaunching`: writes a transient `0600` `.dcv` connection file, opens it with DCV
/// Viewer for auto-login, then deletes it immediately (F-10, ADR-8).
public final class DCVLauncher: DCVLaunching {
    private let locator: DCVViewerLocating
    private let store: DCVConnectionFileStore
    private let opener: DCVViewerOpening
    /// Sets Viewer prefs that must land before launch (HiDPI/Retina — CL-06). Best-effort.
    private let configurator: DCVViewerConfiguring
    /// Grace period to keep the `.dcv` file on disk after launching DCV Viewer. The viewer reads
    /// the connection file *asynchronously* after `open` returns (which only signals launch, not
    /// read); deleting it immediately races that read and the viewer fails with a bogus
    /// "DNS resolution (domain: 'file')" error. We hold the `0600` file for this window so the
    /// viewer reliably reads it, then delete it. A crash within the window is covered by the
    /// startup sweep (ADR-8).
    private let cleanupDelay: Duration

    public init(
        locator: DCVViewerLocating = SystemDCVViewerLocator(),
        store: DCVConnectionFileStore = TempDCVConnectionFileStore(),
        opener: DCVViewerOpening = WorkspaceDCVViewerOpener(),
        configurator: DCVViewerConfiguring = GLibKeyfileDCVViewerConfigurator(),
        cleanupDelay: Duration = .seconds(5)
    ) {
        self.locator = locator
        self.store = store
        self.opener = opener
        self.configurator = configurator
        self.cleanupDelay = cleanupDelay
    }

    public func isViewerInstalled() -> Bool { locator.viewerAppURL() != nil }

    public func launch(connectionFile: DCVConnectionFile) async throws {
        guard let appURL = locator.viewerAppURL() else { throw DCVError.viewerNotInstalled }

        // CL-06: enable Viewer HiDPI before launch on a Retina client (best-effort, never blocks).
        let backingScale = await MainActor.run { NSScreen.main?.backingScaleFactor ?? 1 }
        configurator.ensurePreferredSettings(backingScale: backingScale)

        let fileURL = try store.write(connectionFile.iniContent())

        do {
            try await opener.open(fileURL: fileURL, withApp: appURL)
        } catch {
            store.remove(fileURL) // launch failed — remove the password-bearing file now
            throw DCVError.launchFailed(reason: error.localizedDescription)
        }

        // Let DCV Viewer read the file before we delete it (see `cleanupDelay`).
        try? await Task.sleep(for: cleanupDelay)
        store.remove(fileURL)
    }

    public func sweepOrphanedFiles() { store.sweepOrphans() }
}

// MARK: - Real seam implementations

/// Detects DCV Viewer at the standard path or via its bundle identifier.
public struct SystemDCVViewerLocator: DCVViewerLocating {
    public init() {}

    public static let standardPath = "/Applications/DCV Viewer.app"
    public static let bundleIdentifier = "com.amazon.dcvviewer"

    public func viewerAppURL() -> URL? {
        if FileManager.default.fileExists(atPath: Self.standardPath) {
            return URL(fileURLWithPath: Self.standardPath)
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier)
    }
}

/// Writes the connection file `0600` in the per-user temp directory and sweeps orphans.
public struct TempDCVConnectionFileStore: DCVConnectionFileStore {
    public init() {}

    public var directory: URL = FileManager.default.temporaryDirectory

    public func write(_ contents: String) throws -> URL {
        let name = "\(DCVConnectionFile.tempFilePrefix)\(UUID().uuidString).\(DCVConnectionFile.fileExtension)"
        let url = directory.appendingPathComponent(name)
        let created = FileManager.default.createFile(
            atPath: url.path,
            contents: Data(contents.utf8),
            attributes: [.posixPermissions: 0o600]
        )
        guard created else { throw DCVError.launchFailed(reason: "could not write DCV connection file") }
        return url
    }

    public func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    public func sweepOrphans() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for item in items
        where item.lastPathComponent.hasPrefix(DCVConnectionFile.tempFilePrefix)
            && item.pathExtension == DCVConnectionFile.fileExtension {
            try? fm.removeItem(at: item)
        }
    }
}

/// Opens the connection file with DCV Viewer via `NSWorkspace`.
public struct WorkspaceDCVViewerOpener: DCVViewerOpening {
    public init() {}

    public func open(fileURL: URL, withApp appURL: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.open([fileURL], withApplicationAt: appURL, configuration: configuration)
    }
}
