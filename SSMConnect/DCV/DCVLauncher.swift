import AppKit
import Foundation

/// Default `DCVLaunching`: writes a transient `0600` `.dcv` connection file, opens it with DCV
/// Viewer for auto-login, then deletes it immediately (F-10, ADR-8).
final class DCVLauncher: DCVLaunching {
    private let locator: DCVViewerLocating
    private let store: DCVConnectionFileStore
    private let opener: DCVViewerOpening

    init(
        locator: DCVViewerLocating = SystemDCVViewerLocator(),
        store: DCVConnectionFileStore = TempDCVConnectionFileStore(),
        opener: DCVViewerOpening = WorkspaceDCVViewerOpener()
    ) {
        self.locator = locator
        self.store = store
        self.opener = opener
    }

    func isViewerInstalled() -> Bool { locator.viewerAppURL() != nil }

    func launch(connectionFile: DCVConnectionFile) async throws {
        guard let appURL = locator.viewerAppURL() else { throw DCVError.viewerNotInstalled }

        let fileURL = try store.write(connectionFile.iniContent())
        // Delete the password-bearing file as soon as the viewer launch returns (or on error).
        defer { store.remove(fileURL) }

        do {
            try await opener.open(fileURL: fileURL, withApp: appURL)
        } catch {
            throw DCVError.launchFailed(reason: error.localizedDescription)
        }
    }

    func sweepOrphanedFiles() { store.sweepOrphans() }
}

// MARK: - Real seam implementations

/// Detects DCV Viewer at the standard path or via its bundle identifier.
struct SystemDCVViewerLocator: DCVViewerLocating {
    static let standardPath = "/Applications/DCV Viewer.app"
    static let bundleIdentifier = "com.amazon.dcvviewer"

    func viewerAppURL() -> URL? {
        if FileManager.default.fileExists(atPath: Self.standardPath) {
            return URL(fileURLWithPath: Self.standardPath)
        }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleIdentifier)
    }
}

/// Writes the connection file `0600` in the per-user temp directory and sweeps orphans.
struct TempDCVConnectionFileStore: DCVConnectionFileStore {
    var directory: URL = FileManager.default.temporaryDirectory

    func write(_ contents: String) throws -> URL {
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

    func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    func sweepOrphans() {
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
struct WorkspaceDCVViewerOpener: DCVViewerOpening {
    func open(fileURL: URL, withApp appURL: URL) async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        _ = try await NSWorkspace.shared.open([fileURL], withApplicationAt: appURL, configuration: configuration)
    }
}
