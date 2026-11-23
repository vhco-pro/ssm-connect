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
/// directory, the shell opens it with the viewer it found, and the file is deleted once the
/// viewer has had time to read it, as on macOS. A crash within that window is covered by the sweep
/// at the next connect.
package struct ShellDCVLauncher: DCVLaunching {
    /// How long the connection file stays for the Viewer to read. A cold Viewer start on Ubuntu took
    /// about 70 seconds; Connect does not wait for the window.
    package static let viewerReadWindow: Duration = .seconds(120)

    /// The files this helper is still keeping for a Viewer, so neither a sweep nor a clock change
    /// removes one before its window ends.
    final class Waiting: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: Set<URL> = []
        func add(_ url: URL) { lock.withLock { _ = urls.insert(url) } }
        func remove(_ url: URL) { lock.withLock { _ = urls.remove(url) } }
        func contains(_ url: URL) -> Bool { lock.withLock { urls.contains(url) } }
        func takeAll() -> Set<URL> { lock.withLock { defer { urls = [] }; return urls } }
    }

    let requests: ShellRequests
    let directory: URL
    let viewerInstalled: @Sendable () -> Bool
    let writePrivate: @Sendable (Data, URL) throws -> Void
    let cleanupDelay: Duration
    let now: @Sendable () -> Date
    let waiting = Waiting()

    package init(requests: ShellRequests, directory: URL, viewerInstalled: @escaping @Sendable () -> Bool,
                 writePrivate: @escaping @Sendable (Data, URL) throws -> Void,
                 cleanupDelay: Duration = ShellDCVLauncher.viewerReadWindow, now: @escaping @Sendable () -> Date = { Date() }) {
        self.requests = requests
        self.directory = directory
        self.viewerInstalled = viewerInstalled
        self.writePrivate = writePrivate
        self.cleanupDelay = cleanupDelay
        self.now = now
    }

    package func isViewerInstalled() -> Bool { viewerInstalled() }

    package func launch(connectionFile: DCVConnectionFile) async throws {
        guard viewerInstalled() else { throw DCVError.viewerNotInstalled }
        let url = directory.appendingPathComponent(DCVConnectionFile.tempFilePrefix + UUID().uuidString)
            .appendingPathExtension(DCVConnectionFile.fileExtension)
        try writePrivate(Data(connectionFile.iniContent().utf8), url)
        waiting.add(url)
        requests.launch("dcvViewer", fields: ["file": url.externalPath])
        let delay = cleanupDelay
        let waiting = self.waiting
        Task.detached {
            try? await Task.sleep(for: delay)
            try? FileManager.default.removeItem(at: url)
            waiting.remove(url)
        }
    }

    /// Removes connection files a killed helper left: files this helper is not keeping whose
    /// modification time is older than the window. A younger one waits for a later sweep.
    package func sweepOrphanedFiles() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let window = TimeInterval(cleanupDelay.components.seconds)
        let cutoff = now().addingTimeInterval(-max(window, TimeInterval(Self.viewerReadWindow.components.seconds)))
        for name in names where name.hasPrefix(DCVConnectionFile.tempFilePrefix) && name.hasSuffix("." + DCVConnectionFile.fileExtension) {
            let url = directory.appendingPathComponent(name)
            guard !waiting.contains(url) else { continue }
            let modified = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
            if let modified, modified < cutoff { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// Removes the connection files still waiting for their window to end; the helper's quit work.
    package func removeWaitingFiles() {
        for url in waiting.takeAll() { try? FileManager.default.removeItem(at: url) }
    }
}

/// The managed browser through the shell, with the routing macOS uses: the core picks the installed,
/// supported browser and builds its command line, and the shell only starts it. The browser runs in
/// its own owner-only profile folder, and a PAC sends only the profile's private suffixes through
/// the SOCKS listener, with no direct fallback; everything else goes direct.
@MainActor package final class ShellBrowserOpener: BrowserOpening {
    let requests: ShellRequests
    let executable: (ConnectionProfile) -> String?
    let profiles: URL

    package init(requests: ShellRequests, executable: @escaping (ConnectionProfile) -> String?, profiles: URL) {
        self.requests = requests
        self.executable = executable
        self.profiles = profiles
    }

    package func preflight(profile: ConnectionProfile) throws {
        guard executable(profile) != nil else { throw CapabilityError.missing(.browser) }
    }

    package func open(profile: ConnectionProfile) async throws {
        guard let configuration = profile.webForwards, let choice = configuration.browser,
              let path = executable(profile) else { throw CapabilityError.missing(.browser) }
        try BrowserPrivateFiles.directory(profiles)
        let directory = profiles.appendingPathComponent(profile.id.uuidString, isDirectory: true)
        try BrowserPrivateFiles.directory(directory)
        let pac = "data:application/x-ns-proxy-autoconfig;base64,"
            + Data(try WebForwardsPAC.contents(configuration: configuration).utf8).base64EncodedString()
        let arguments: [String]
        switch choice {
        case .zen, .firefox:
            let preferences: [(String, String)] = [
                ("network.proxy.type", "2"), ("network.proxy.autoconfig_url", "\"\(pac)\""),
                ("network.proxy.socks_remote_dns", "true"), ("network.proxy.socks5_remote_dns", "true"),
                ("network.proxy.failover_direct", "false"), ("network.dns.disablePrefetch", "true"),
            ]
            let userJS = preferences.map { "user_pref(\"\($0.0)\", \($0.1));" }.joined(separator: "\n") + "\n"
            try BrowserPrivateFiles.write(Data(userJS.utf8), to: directory.appendingPathComponent("user.js"), createParent: false)
            arguments = ["--new-instance", "--profile", directory.externalPath, "--new-window", "about:blank"]
        default:
            arguments = ["--user-data-dir=\(directory.externalPath)", "--proxy-pac-url=\(pac)",
                         "--no-first-run", "--no-default-browser-check", "about:blank"]
        }
        requests.launch("browser", fields: ["path": path, "arguments": arguments.joined(separator: "\u{1F}")])
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
