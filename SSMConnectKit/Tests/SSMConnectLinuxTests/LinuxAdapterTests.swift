#if os(Linux)
import Foundation
import Glibc
import Testing
@testable import SSMConnectDomain
@testable import SSMConnectLinux
@testable import SSMConnectWorkflow

/// Core-side Linux adapters (T22, AC-19, AC-16, AC-17).
@Suite("Linux adapters")
struct LinuxAdapterTests {
    static func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ssm-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func mode(_ url: URL) -> Int {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else { return -1 }
        return Int(metadata.st_mode & 0o7777)
    }

    static func executable(_ url: URL, _ script: String = "#!/bin/sh\nexit 0\n") throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    // MARK: Private files

    @Test("A private file is user-only, in a user-only folder, and replaced atomically")
    func privateFiles() throws {
        let root = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("leases/lease.json")
        try LinuxPrivateFiles.write(Data("one".utf8), to: file)
        #expect(try Data(contentsOf: file) == Data("one".utf8))
        #expect(Self.mode(file) == 0o600)
        #expect(Self.mode(file.deletingLastPathComponent()) == 0o700)
        try LinuxPrivateFiles.write(Data("two".utf8), to: file)
        #expect(try Data(contentsOf: file) == Data("two".utf8))
        #expect(Self.mode(file) == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path) == ["lease.json"])
        #expect(LinuxPrivateFiles.isOwnerOnly(file))
        #expect(OwnerOnlyFiles.posix.isOwnerOnly(file, try FileManager.default.attributesOfItem(atPath: file.path)))
    }

    @Test("A folder of SSM Connect's that others could enter is made user-only")
    func widenedFolder() throws {
        let root = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("state")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try LinuxPrivateFiles.write(Data("x".utf8), to: folder.appendingPathComponent("settings.json"))
        #expect(Self.mode(folder) == 0o700)
    }

    @Test("A file anyone else may read is not user-only")
    func widenedFile() throws {
        let root = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("lease.json")
        try LinuxPrivateFiles.write(Data("x".utf8), to: file)
        chmod(file.path, 0o644)
        #expect(!LinuxPrivateFiles.isOwnerOnly(file))
    }

    @Test("A symbolic link is never written through")
    func symbolicLink() throws {
        let root = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("elsewhere.txt")
        try Data("keep".utf8).write(to: target)
        let link = root.appendingPathComponent("private/lease.json")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: LinuxPrivateFiles.Failure.self) { try LinuxPrivateFiles.write(Data("new".utf8), to: link) }
        #expect(try Data(contentsOf: target) == Data("keep".utf8))

        let linkedFolder = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linkedFolder, withDestinationURL: root.appendingPathComponent("private"))
        #expect(throws: LinuxPrivateFiles.Failure.self) {
            try LinuxPrivateFiles.write(Data("new".utf8), to: linkedFolder.appendingPathComponent("other.json"))
        }
    }

    @Test("Browser private files on Linux use the same user-only writer")
    func browserPrivateFiles() throws {
        let root = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Browsers/zen/user.js")
        try BrowserPrivateFiles.write(Data("pref".utf8), to: file)
        #expect(Self.mode(file) == 0o600)
        #expect(Self.mode(file.deletingLastPathComponent()) == 0o700)
    }

    // MARK: Paths and key-value store

    @Test("Settings and state follow the XDG base directories, with their defaults")
    func paths() {
        let explicit = LinuxPaths(environment: ["HOME": "/home/u", "XDG_CONFIG_HOME": "/cfg", "XDG_STATE_HOME": "/st"])
        #expect(explicit.settings.path == "/cfg/ssm-connect/settings.json")
        #expect(explicit.state.path == "/st/ssm-connect")
        let defaults = LinuxPaths(environment: ["HOME": "/home/u"])
        #expect(defaults.settings.path == "/home/u/.config/ssm-connect/settings.json")
        #expect(defaults.state.path == "/home/u/.local/state/ssm-connect")
        #expect(defaults.home.path == "/home/u")
        // A relative XDG value is invalid by the specification and ignored.
        #expect(LinuxPaths(environment: ["HOME": "/home/u", "XDG_CONFIG_HOME": "relative"]).settings.path
                == "/home/u/.config/ssm-connect/settings.json")
    }

    @Test("The key-value store keeps data and strings in one user-only document")
    func keyValueStore() throws {
        let root = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = LinuxPaths(environment: ["HOME": root.path])
        let store = LinuxKeyValueStore.make(paths: paths)
        store.set(Data([1, 2, 3]), forKey: "profiles")
        store.set("abc", forKey: "active")
        let reopened = LinuxKeyValueStore.make(paths: paths)
        #expect(reopened.data(forKey: "profiles") == Data([1, 2, 3]))
        #expect(reopened.string(forKey: "active") == "abc")
        #expect(reopened.data(forKey: "active") == nil)
        reopened.set(nil, forKey: "active")
        #expect(LinuxKeyValueStore.make(paths: paths).string(forKey: "active") == nil)
        #expect(Self.mode(paths.settings) == 0o600)
        #expect(Self.mode(paths.settings.deletingLastPathComponent()) == 0o700)
    }

    // MARK: Tools

    @Test("The plugin and proxy are found beside the helper, SSH and VS Code on PATH or their install folders")
    func tools() throws {
        let root = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("libexec")
        let bin = root.appendingPathComponent("bin")
        let tools = LinuxTools(helperDirectory: helper, environment: ["PATH": bin.path], fallbackDirectories: [])
        #expect(tools.pluginPath == nil)
        #expect(tools.missing(Capability.allCases).contains(.sessionManagerPlugin))
        #expect(tools.missing([.openSSH, .visualStudioCode]) == [.openSSH, .visualStudioCode])

        try Self.executable(helper.appendingPathComponent("session-manager-plugin"))
        try Self.executable(helper.appendingPathComponent("ssm-connect-proxy"))
        try Self.executable(bin.appendingPathComponent("ssh"))
        try Self.executable(bin.appendingPathComponent("code"))
        #expect(tools.pluginPath == helper.appendingPathComponent("session-manager-plugin").path)
        #expect(tools.proxyPath == helper.appendingPathComponent("ssm-connect-proxy").path)
        #expect(tools.sshPath == bin.appendingPathComponent("ssh").path)
        #expect(tools.vsCodePath == bin.appendingPathComponent("code").path)
        #expect(tools.missing([.sessionManagerPlugin, .openSSH, .visualStudioCode]).isEmpty)
    }

    @Test("A file that is not executable is not a tool, and install folders are searched after PATH")
    func toolFallbacks() throws {
        let root = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let bin = root.appendingPathComponent("bin")
        let codeInstall = root.appendingPathComponent("share/code/bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        try Data("not executable".utf8).write(to: bin.appendingPathComponent("code"))
        try Self.executable(codeInstall.appendingPathComponent("code"))
        let tools = LinuxTools(helperDirectory: root, environment: ["PATH": bin.path], fallbackDirectories: [codeInstall.path])
        #expect(tools.vsCodePath == codeInstall.appendingPathComponent("code").path)
    }

    // MARK: Browsers

    @Test("Chrome and Zen are found with their versions, and only pinned versions are supported")
    func browsers() throws {
        let root = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let chrome = root.appendingPathComponent("opt/google/chrome/chrome")
        try Self.executable(chrome)
        let zen = root.appendingPathComponent("home/.tarball-installations/zen")
        try Self.executable(zen.appendingPathComponent("zen"))
        try Data("[App]\nVendor=Zen\nVersion=1.17.3b\nBuildID=1\n".utf8).write(to: zen.appendingPathComponent("application.ini"))

        let candidates = LinuxBrowserDiscovery.Candidates(chrome: [chrome], zen: [zen])
        let unpinned = LinuxBrowserDiscovery(candidates: candidates, pinned: [:], chromeVersion: { _ in "131.0.6778.85" })
        #expect(unpinned.installed() == [LinuxBrowser(choice: .chrome, executable: chrome, version: "131.0.6778.85"),
                                         LinuxBrowser(choice: .zen, executable: zen.appendingPathComponent("zen"), version: "1.17.3b")])
        #expect(unpinned.installedSupported().isEmpty)
        #expect(unpinned.supported(.zen, mode: .separate) == nil)

        let pinned = LinuxBrowserDiscovery(candidates: candidates, pinned: [.chrome: ["131.0.6778.85"], .zen: ["1.17.3b"]],
                                           chromeVersion: { _ in "131.0.6778.85" })
        #expect(pinned.supported(.chrome, mode: .separate)?.executable == chrome)
        #expect(pinned.supported(.chrome, mode: .existing) == nil)
        #expect(pinned.supported(.zen, mode: .existing)?.version == "1.17.3b")
        let otherVersion = LinuxBrowserDiscovery(candidates: candidates, pinned: [.chrome: ["130.0.0.0"]],
                                                 chromeVersion: { _ in "131.0.6778.85" })
        #expect(otherVersion.supported(.chrome, mode: .separate) == nil)
    }

    @Test("Chrome's version is read while a child that closed its inherited descriptors still runs")
    func chromeVersionBesideSSH() throws {
        // OpenSSH closes every descriptor above stderr when it starts. Started with Foundation's
        // Process, as web forwards start it, such a child left Foundation's process monitor
        // blocked in waitpid until it exited, so no other child was reaped: the version probe
        // never returned and the helper hung on Open Browser.
        let root = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let closer = Process()
        closer.executableURL = URL(fileURLWithPath: "/bin/bash")
        closer.arguments = ["-c", "for f in /proc/$$/fd/*; do n=${f##*/}; [ \"$n\" -gt 2 ] && eval \"exec $n>&-\"; done; sleep 8"]
        try closer.run()
        defer { closer.terminate() }
        Thread.sleep(forTimeInterval: 0.5)

        let chrome = root.appendingPathComponent("chrome")
        try Data("#!/bin/sh\necho 'Google Chrome 158.0.8127.36 '\n".utf8).write(to: chrome)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: chrome.path)
        let answered = DispatchSemaphore(value: 0)
        let version = Locked<String?>(nil)
        Thread.detachNewThread {
            version.set(LinuxBrowserDiscovery.runChromeVersion(chrome))
            answered.signal()
        }
        #expect(answered.wait(timeout: .now() + 3) == .success)
        #expect(version.get() == "158.0.8127.36")
    }

    @Test("A child's exit is seen while another closed its descriptors, and SIGTERM reaches children")
    func childProcessesAreWaitedForAlone() throws {
        // The helper ignores SIGTERM to handle it through a dispatch source; children must not
        // inherit that, or terminate() could not end ssh or the plugin.
        let previous = signal(SIGTERM, SIG_IGN)
        defer { signal(SIGTERM, previous) }
        let closer = ChildProcess(executable: "/bin/bash", arguments: [
            "-c", "for f in /proc/$$/fd/*; do n=${f##*/}; [ \"$n\" -gt 2 ] && eval \"exec $n>&-\"; done; sleep 30",
        ])
        try closer.run()
        Thread.sleep(forTimeInterval: 0.5)

        let exited = DispatchSemaphore(value: 0)
        let code = Locked<Int32?>(nil)
        let short = ChildProcess(executable: "/bin/sh", arguments: ["-c", "exit 3"])
        short.onExit { code.set($0); exited.signal() }
        try short.run()
        #expect(exited.wait(timeout: .now() + 2) == .success)
        #expect(code.get() == 3 && short.terminationStatus == 3 && !short.isRunning)

        #expect(closer.isRunning)
        closer.terminate()
        let ended = DispatchSemaphore(value: 0)
        Thread.detachNewThread { closer.waitUntilExit(); ended.signal() }
        #expect(ended.wait(timeout: .now() + 2) == .success)
        #expect(closer.terminationStatus == SIGTERM)
    }

    @Test("Chrome's version is read from its --version output")
    func chromeVersionOutput() {
        #expect(LinuxBrowserDiscovery.parseChromeVersion("Google Chrome 131.0.6778.85 \n") == "131.0.6778.85")
        #expect(LinuxBrowserDiscovery.parseChromeVersion("Google Chrome for Testing 131.0.6778.85") == "131.0.6778.85")
        #expect(LinuxBrowserDiscovery.parseChromeVersion("garbage") == nil)
    }

    @Test("The default candidates are the system packages and Zen's per-user tarball install")
    func defaultCandidates() {
        let candidates = LinuxBrowserDiscovery.Candidates.standard(home: URL(fileURLWithPath: "/home/u"))
        #expect(candidates.chrome.map(\.path) == ["/opt/google/chrome/chrome"])
        #expect(candidates.zen.map(\.path) == ["/home/u/.tarball-installations/zen", "/opt/zen"])
    }
}
/// A value shared with the thread that produces it.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.withLock { value } }
    func set(_ newValue: Value) { lock.withLock { value = newValue } }
}
#endif
