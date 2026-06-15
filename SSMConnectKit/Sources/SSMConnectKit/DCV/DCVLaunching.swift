import Foundation

/// Launches Amazon DCV Viewer with an auto-login connection file (E4/E5, F-10, ADR-8).
protocol DCVLaunching: Sendable {
    /// True if DCV Viewer is installed.
    func isViewerInstalled() -> Bool
    /// Write a transient `.dcv` file, open it with DCV Viewer, then delete it immediately.
    /// Throws `DCVError.viewerNotInstalled` if the viewer is absent (no file is written).
    func launch(connectionFile: DCVConnectionFile) async throws
    /// Remove any orphaned `.dcv` temp files left by a previous crash (ADR-8, §8).
    func sweepOrphanedFiles()
}

enum DCVError: LocalizedError, Equatable {
    case viewerNotInstalled
    case launchFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case .viewerNotInstalled:
            return "Amazon DCV Viewer is required but not found at /Applications/DCV Viewer.app. "
                + "Install via `brew install --cask dcv-viewer` or download from https://download.amazondcv.com."
        case let .launchFailed(reason):
            return "Failed to launch DCV Viewer: \(reason)"
        }
    }
}

// MARK: - Injectable seams (so DCVLauncher is unit-testable without AppKit / disk)

/// Locates the installed DCV Viewer app bundle.
protocol DCVViewerLocating: Sendable {
    /// URL of the DCV Viewer app bundle, or `nil` if not installed.
    func viewerAppURL() -> URL?
}

/// Persists the transient connection file (`0600` temp file) and cleans it up.
protocol DCVConnectionFileStore: Sendable {
    func write(_ contents: String) throws -> URL
    func remove(_ url: URL)
    func sweepOrphans()
}

/// Opens a file with a specific application.
protocol DCVViewerOpening: Sendable {
    func open(fileURL: URL, withApp appURL: URL) async throws
}
