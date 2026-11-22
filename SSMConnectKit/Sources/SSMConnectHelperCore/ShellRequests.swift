import Foundation
import SSMConnectDomain
import SSMConnectHelperProtocol
import SSMConnectWorkflow

/// Requests the helper makes of its shell. Applications that hold the user's work (VS Code, DCV
/// Viewer, browsers) and the sign-in page start from the shell's own process, outside the
/// helper's container, so they survive a helper or shell failure.
package final class ShellRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: EventSink?

    package init() {}

    /// Connects the requests to the session's event stream.
    package func attach(_ sink: EventSink) { lock.withLock { self.sink = sink } }

    package func openURL(_ url: URL) {
        emit(name: "openURL", fields: ["url": url.absoluteString])
    }

    /// Asks the shell to start an application; `kind` is dcvViewer, vsCode or browser.
    package func launch(_ kind: String, fields: [String: String]) {
        emit(name: "launchApplication", fields: fields.merging(["kind": kind]) { _, new in new })
    }

    /// Puts text on the user's clipboard. Only this request carries it, to the shell alone.
    package func setClipboard(_ text: String) { emit(name: "setClipboard", fields: ["text": text]) }

    package func notify(title: String, body: String) { emit(name: "notify", fields: ["title": title, "body": body]) }

    private func emit(name: String, fields: [String: String]) {
        let sink = lock.withLock { self.sink }
        sink?.emit(workflow: "shell", name: name, fields: fields)
    }
}

/// DCV Viewer through the shell: the connection file is written owner-only to a temporary
/// directory, and the shell opens it with the viewer it found.
package struct ShellDCVLauncher: DCVLaunching {
    let requests: ShellRequests
    let directory: URL
    let viewerInstalled: @Sendable () -> Bool
    let writePrivate: @Sendable (Data, URL) throws -> Void

    package init(requests: ShellRequests, directory: URL, viewerInstalled: @escaping @Sendable () -> Bool,
                 writePrivate: @escaping @Sendable (Data, URL) throws -> Void) {
        self.requests = requests
        self.directory = directory
        self.viewerInstalled = viewerInstalled
        self.writePrivate = writePrivate
    }

    package func isViewerInstalled() -> Bool { viewerInstalled() }

    package func launch(connectionFile: DCVConnectionFile) async throws {
        guard viewerInstalled() else { throw DCVError.viewerNotInstalled }
        let url = directory.appendingPathComponent(DCVConnectionFile.tempFilePrefix + UUID().uuidString)
            .appendingPathExtension(DCVConnectionFile.fileExtension)
        try writePrivate(Data(connectionFile.iniContent().utf8), url)
        requests.launch("dcvViewer", fields: ["file": url.externalPath])
    }

    package func sweepOrphanedFiles() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(DCVConnectionFile.tempFilePrefix) && name.hasSuffix("." + DCVConnectionFile.fileExtension) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }
}

/// The managed browser through the shell: the core checks the browser is supported, and the
/// shell starts it with the profile's routing.
@MainActor package final class ShellBrowserOpener: BrowserOpening {
    let requests: ShellRequests
    let isSupported: (ConnectionProfile) -> Bool

    package init(requests: ShellRequests, isSupported: @escaping (ConnectionProfile) -> Bool) {
        self.requests = requests
        self.isSupported = isSupported
    }

    package func preflight(profile: ConnectionProfile) throws {
        guard isSupported(profile) else { throw CapabilityError.missing(.browser) }
    }

    package func open(profile: ConnectionProfile) async throws {
        requests.launch("browser", fields: ["profile": profile.id.uuidString,
                                            "browser": profile.webForwards?.browser?.rawValue ?? "",
                                            "mode": profile.webForwards?.browserMode?.rawValue ?? "",
                                            "socksPort": String(profile.webForwards?.socksPort ?? 1080)])
    }

    package func restore(profile: ConnectionProfile) throws {}
}

/// The clipboard through the shell, which clears it after the configured time.
package struct ShellPasteboard: Pasteboard {
    let requests: ShellRequests
    package init(requests: ShellRequests) { self.requests = requests }
    package func setString(_ value: String) { requests.setClipboard(value) }
    package func currentString() -> String? { nil }
}

/// Notifications through the shell's own notification support.
package struct ShellNotifier: Notifying {
    let requests: ShellRequests
    package init(requests: ShellRequests) { self.requests = requests }
    package func requestAuthorization() async {}
    package func post(_ event: NotificationEvent) async { requests.notify(title: event.title, body: event.body) }
}
