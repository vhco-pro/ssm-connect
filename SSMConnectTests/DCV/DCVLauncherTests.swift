import Foundation
import Testing
@testable import SSMConnect

@Suite("DCVLauncher")
struct DCVLauncherTests {
    private let viewerURL = URL(fileURLWithPath: "/Applications/DCV Viewer.app")
    private let connectionFile = DCVConnectionFile(port: 8443, password: "secret")

    @Test("isViewerInstalled reflects the locator")
    func installed() {
        let present = DCVLauncher(locator: FakeViewerLocator(url: viewerURL), store: SpyConnectionFileStore(), opener: SpyViewerOpener())
        let absent = DCVLauncher(locator: FakeViewerLocator(url: nil), store: SpyConnectionFileStore(), opener: SpyViewerOpener())
        #expect(present.isViewerInstalled())
        #expect(!absent.isViewerInstalled())
    }

    @Test("launch writes the file, opens it, then deletes it")
    func launchWritesOpensDeletes() async throws {
        let store = SpyConnectionFileStore()
        let opener = SpyViewerOpener()
        // cleanupDelay: .zero so the test doesn't wait the production grace period.
        let launcher = DCVLauncher(locator: FakeViewerLocator(url: viewerURL), store: store, opener: opener, cleanupDelay: .zero)

        try await launcher.launch(connectionFile: connectionFile)

        // wrote the auto-login content
        #expect(store.writtenContents.count == 1)
        #expect(store.writtenContents.first?.contains("password=secret") == true)
        // opened with DCV Viewer using the written file
        #expect(opener.openCount == 1)
        #expect(opener.lastFileURL == store.writtenURL)
        #expect(opener.lastAppURL == viewerURL)
        // deleted the password-bearing file afterward
        #expect(store.removedURLs == [store.writtenURL])
    }

    @Test("launch throws viewerNotInstalled and writes no file when the viewer is absent")
    func launchNoViewer() async {
        let store = SpyConnectionFileStore()
        let launcher = DCVLauncher(locator: FakeViewerLocator(url: nil), store: store, opener: SpyViewerOpener())

        await #expect(throws: DCVError.viewerNotInstalled) {
            try await launcher.launch(connectionFile: connectionFile)
        }
        #expect(store.writtenContents.isEmpty)
    }

    @Test("launch still deletes the file when the open call fails")
    func launchDeletesOnOpenFailure() async {
        let store = SpyConnectionFileStore()
        let opener = SpyViewerOpener()
        opener.openError = DummyOpenError()
        let launcher = DCVLauncher(locator: FakeViewerLocator(url: viewerURL), store: store, opener: opener)

        await #expect(throws: DCVError.self) {
            try await launcher.launch(connectionFile: connectionFile)
        }
        #expect(store.removedURLs == [store.writtenURL])
    }

    @Test("sweepOrphanedFiles delegates to the store")
    func sweep() {
        let store = SpyConnectionFileStore()
        let launcher = DCVLauncher(locator: FakeViewerLocator(url: viewerURL), store: store, opener: SpyViewerOpener())
        launcher.sweepOrphanedFiles()
        #expect(store.sweepCount == 1)
    }
}
