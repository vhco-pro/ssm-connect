#if os(Windows)
import Foundation
import Testing
@testable import SSMConnectDomain
@testable import SSMConnectWindows
@testable import SSMConnectWorkflow

/// Core-side Windows adapters (T17, AC-19, AC-16, AC-17).
@Suite("Windows adapters")
struct WindowsAdapterTests {
    static func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ssm-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    static func run(_ executable: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    static var system32: String { (ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows") + "\\System32" }

    // MARK: Private files

    @Test("A private file is written with an owner-only DACL and replaced atomically")
    func privateFiles() throws {
        let root = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("leases/lease.json")
        try WindowsPrivateFiles.write(Data("one".utf8), to: file)
        #expect(try Data(contentsOf: file) == Data("one".utf8))
        #expect(WindowsPrivateFiles.isOwnerOnly(file))
        #expect(WindowsPrivateFiles.isOwnerOnly(file.deletingLastPathComponent()))
        try WindowsPrivateFiles.write(Data("two".utf8), to: file)
        #expect(try Data(contentsOf: file) == Data("two".utf8))
        #expect(WindowsPrivateFiles.isOwnerOnly(file))
        #expect(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path) == ["lease.json"])
    }

    @Test("A file anyone else may read is not owner-only")
    func widenedFile() throws {
        let root = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("lease.json")
        try WindowsPrivateFiles.write(Data("x".utf8), to: file)
        #expect(try Self.run(Self.system32 + "\\icacls.exe", [file.nativePath, "/grant", "*S-1-1-0:R"]) == 0)
        #expect(!WindowsPrivateFiles.isOwnerOnly(file))
        #expect(!OwnerOnlyFiles.windows.isOwnerOnly(file, [:]))
    }

    @Test("A junction is never written through")
    func reparsePoint() throws {
        let root = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let junction = root.appendingPathComponent("junction")
        #expect(try Self.run(Self.system32 + "\\cmd.exe", ["/c", "mklink", "/J", junction.nativePath, target.nativePath]) == 0)
        #expect(throws: WindowsPrivateFiles.Failure.reparsePoint) { try WindowsPrivateFiles.write(Data("x".utf8), to: junction) }
        #expect(throws: WindowsPrivateFiles.Failure.reparsePoint) { try WindowsPrivateFiles.directory(junction) }
    }

    @Test("The publication lock excludes a second holder")
    func lock() throws {
        let root = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let lockFile = root.appendingPathComponent(".editor-publication.lock")
        var ran = false
        try OwnerOnlyFiles.windows.withExclusiveLock(lockFile) {
            ran = true
            #expect(throws: RemoteSSHError.configurationConflict) { try OwnerOnlyFiles.windows.withExclusiveLock(lockFile) {} }
        }
        #expect(ran && WindowsPrivateFiles.isOwnerOnly(lockFile))
        try OwnerOnlyFiles.windows.withExclusiveLock(lockFile) {}
    }

    // MARK: Key-value store

    @Test("The key-value store persists data and strings in an owner-only file")
    func keyValueStore() throws {
        let root = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("SSM Connect/settings.json")
        let store = WindowsKeyValueStore(url: url)
        store.set(Data([1, 2, 3]), forKey: "ssmconnect.profiles.v1")
        store.set("22222222-2222-4222-8222-222222222222", forKey: "ssmconnect.activeProfileID.v1")
        let reopened = WindowsKeyValueStore(url: url)
        #expect(reopened.data(forKey: "ssmconnect.profiles.v1") == Data([1, 2, 3]))
        #expect(reopened.string(forKey: "ssmconnect.activeProfileID.v1") == "22222222-2222-4222-8222-222222222222")
        reopened.set(nil, forKey: "ssmconnect.profiles.v1")
        #expect(WindowsKeyValueStore(url: url).data(forKey: "ssmconnect.profiles.v1") == nil)
        #expect(WindowsPrivateFiles.isOwnerOnly(url))
    }

    // MARK: Tools and process launch

    @Test("Tools are found where they are installed, and missing ones are reported")
    func tools() throws {
        let root = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = root.appendingPathComponent("app", isDirectory: true)
        let system = root.appendingPathComponent("Windows", isDirectory: true)
        let local = root.appendingPathComponent("Local", isDirectory: true)
        let environment = ["SystemRoot": system.path, "LOCALAPPDATA": local.path, "ProgramFiles": root.appendingPathComponent("PF").path]
        let empty = WindowsTools(helperDirectory: helper, environment: environment)
        let missing = empty.missing([.sessionManagerPlugin, .openSSH, .visualStudioCode])
        #expect(missing == [.sessionManagerPlugin, .openSSH, .visualStudioCode], "\(missing) \(String(describing: empty.pluginPath)) \(String(describing: empty.sshPath)) \(String(describing: empty.vsCodePath))")
        for file in [helper.appendingPathComponent("session-manager-plugin.exe"),
                     system.appendingPathComponent("System32/OpenSSH/ssh.exe"),
                     system.appendingPathComponent("System32/OpenSSH/ssh-keygen.exe"),
                     local.appendingPathComponent("Programs/Microsoft VS Code/bin/code.cmd")] {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(atPath: Self.system32 + "\\where.exe", toPath: file.path)
        }
        let tools = WindowsTools(helperDirectory: helper, environment: environment)
        #expect(tools.missing([.sessionManagerPlugin, .openSSH, .visualStudioCode]).isEmpty)
        #expect(tools.pluginPath == helper.appendingPathComponent("session-manager-plugin.exe").nativePath)
        #expect(tools.vsCodePath?.hasSuffix("code.cmd") == true)
    }

    @Test("A child process is started with the shared plugin command line")
    func launch() throws {
        let process = try WindowsProcessLauncher.start(Self.system32 + "\\cmd.exe", arguments: ["/c", "exit", "3"])
        process.waitUntilExit()
        #expect(process.terminationStatus == 3)
        let arguments = try PluginArguments.portForward(session: SSMSessionResponse(sessionId: "s", streamUrl: "wss://x", tokenValue: "t"),
                                                        region: "eu-central-1", instanceId: "i-1", localPort: 18443, remotePort: 8443)
        #expect(arguments.count == 5 && arguments[1] == "eu-central-1" && arguments[2] == "StartSession" && arguments[3].isEmpty)
        #expect(arguments[4].contains("AWS-StartPortForwardingSession") && arguments[4].contains("18443"))
    }

    // MARK: Browsers

    @Test("Chrome and Zen are discovered with their versions and offered only at a pinned version")
    func browsers() throws {
        let root = try Self.temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let programFiles = root.appendingPathComponent("PF", isDirectory: true)
        let chrome = programFiles.appendingPathComponent("Google/Chrome/Application", isDirectory: true)
        try FileManager.default.createDirectory(at: chrome.appendingPathComponent("131.0.6778.86"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: chrome.appendingPathComponent("130.0.1.2"), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: chrome.appendingPathComponent("chrome.exe").path, contents: Data())
        FileManager.default.createFile(atPath: chrome.appendingPathComponent("131.0.6778.86/chrome.dll").path, contents: Data())
        FileManager.default.createFile(atPath: chrome.appendingPathComponent("130.0.1.2/chrome.dll").path, contents: Data())
        let zen = programFiles.appendingPathComponent("Zen Browser", isDirectory: true)
        try FileManager.default.createDirectory(at: zen, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: zen.appendingPathComponent("zen.exe").path, contents: Data())
        try Data("[App]\r\nName=Zen\r\nVersion=1.23.1b\r\n".utf8).write(to: zen.appendingPathComponent("application.ini"))
        let environment = ["ProgramFiles": programFiles.path]

        let unpinned = WindowsBrowserDiscovery(environment: environment, pinned: [:])
        #expect(Set(unpinned.installed().map { "\($0.choice.rawValue) \($0.version)" }) == ["chrome 131.0.6778.86", "zen 1.23.1b"])
        #expect(unpinned.installedSupported().isEmpty && unpinned.supported(.zen, mode: .separate) == nil)
        #expect(WindowsBrowserDiscovery.pinnedVersions.isEmpty)

        let pinned = WindowsBrowserDiscovery(environment: environment, pinned: [.chrome: ["131.0.6778.86"], .zen: ["1.23.1b"]])
        #expect(pinned.supported(.chrome, mode: .separate)?.version == "131.0.6778.86")
        #expect(pinned.supported(.chrome, mode: .existing) == nil)
        #expect(pinned.supported(.zen, mode: .existing)?.version == "1.23.1b")
        let otherVersion = WindowsBrowserDiscovery(environment: environment, pinned: [.zen: ["1.24.0"]])
        #expect(otherVersion.supported(.zen, mode: .separate) == nil)
    }
}
#endif
