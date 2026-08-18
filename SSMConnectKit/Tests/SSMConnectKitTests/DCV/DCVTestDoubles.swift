import Foundation
@testable import SSMConnectDomain
@testable import SSMConnectWorkflow
@testable import SSMConnectAWS
@testable import SSMConnectMacOS
@testable import SSMConnectUI

/// Returns a configurable DCV Viewer location.
struct FakeViewerLocator: DCVViewerLocating {
    var url: URL?
    func viewerAppURL() -> URL? { url }
}

/// Records connection-file writes/removes/sweeps for assertions.
final class SpyConnectionFileStore: DCVConnectionFileStore, @unchecked Sendable {
    var writeError: Error?
    private(set) var writtenContents: [String] = []
    private(set) var writtenURL: URL?
    private(set) var removedURLs: [URL] = []
    private(set) var sweepCount = 0

    func write(_ contents: String) throws -> URL {
        if let writeError { throw writeError }
        writtenContents.append(contents)
        let url = URL(fileURLWithPath: "/tmp/\(DCVConnectionFile.tempFilePrefix)test.\(DCVConnectionFile.fileExtension)")
        writtenURL = url
        return url
    }

    func remove(_ url: URL) { removedURLs.append(url) }
    func sweepOrphans() { sweepCount += 1 }
}

/// Records open() calls; can be configured to throw.
final class SpyViewerOpener: DCVViewerOpening, @unchecked Sendable {
    var openError: Error?
    private(set) var openCount = 0
    private(set) var lastFileURL: URL?
    private(set) var lastAppURL: URL?

    func open(fileURL: URL, withApp appURL: URL) async throws {
        openCount += 1
        lastFileURL = fileURL
        lastAppURL = appURL
        if let openError { throw openError }
    }
}

/// Records ensurePreferredSettings calls; never touches disk (keeps launcher tests hermetic).
final class SpyViewerConfigurator: DCVViewerConfiguring, @unchecked Sendable {
    private(set) var calledScales: [CGFloat] = []
    func ensurePreferredSettings(backingScale: CGFloat) { calledScales.append(backingScale) }
}

struct DummyOpenError: Error {}
