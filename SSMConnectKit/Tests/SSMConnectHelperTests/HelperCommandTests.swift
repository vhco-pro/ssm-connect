import Foundation
import Testing
@testable import SSMConnectDomain
@testable import SSMConnectHelperCore
@testable import SSMConnectHelperProtocol
@testable import SSMConnectWorkflow

/// The helper's command table with fake services (T48, AC-11, AC-12, AC-13, AC-15, AC-27): every
/// shell action is one command mapped to its shared workflow, ends in one terminal result, and
/// streams that workflow's state as ordered events; applications start at the shell's request.
@Suite("Helper commands")
@MainActor
struct HelperCommandTests {
    final class Outbox: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [Frame] = []
        func send(_ frame: Frame) { lock.withLock { frames.append(frame) } }
        var all: [Frame] { lock.withLock { frames } }
        func result(_ id: String) -> Outcome? {
            all.lazy.compactMap { if case let .result(rid, outcome) = $0, rid == id { return outcome } else { return nil } }.first
        }
        func rejection(_ id: String) -> HelperError? {
            all.lazy.compactMap { if case let .rejected(rid, error) = $0, rid == id { return error } else { return nil } }.first
        }
        func events(_ workflow: String) -> [String] {
            all.compactMap {
                if case let .event(_, w, name, fields) = $0, w == workflow { return name == "state" ? fields["state"] : "\(name):\(fields["kind"] ?? "")" }
                return nil
            }
        }
        func launches(_ kind: String) -> [[String: String]] {
            all.compactMap {
                if case let .event(_, "shell", "launchApplication", fields) = $0, fields["kind"] == kind { return fields }
                return nil
            }
        }
    }

    struct Keys: SSHKeyGenerating {
        func generate() async throws -> SSHKeyMaterial {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("private".utf8).write(to: directory.appendingPathComponent("key"))
            try Data("ssh-ed25519 test".utf8).write(to: directory.appendingPathComponent("key.pub"))
            return SSHKeyMaterial(directory: directory, publicKey: "ssh-ed25519 test")
        }
    }
    struct Connect: InstanceConnectProviding {
        func sendPublicKey(instanceId: String, user: String, publicKey: String, region: String, credentials: AWSCredentials) async throws {}
    }
    struct SSH: SSHTunnelProviding {
        func unavailableCapabilities() -> [Capability] { [] }
        func start(session: SSMSessionResponse, region: String, instanceId: String, user: String, keyPath: String,
                   configuration: WebForwardsConfiguration) async throws -> TunnelHandle { MockTunnelHandle() }
    }
    struct Ready: WorkstationReadinessProbing {
        func waitUntilReady(port: Int, timeout: Duration, interval: Duration) async -> Bool { true }
    }
    struct Listening: TunnelListenerProbing {
        func isListening(host: String, port: Int, timeout: Duration) async -> Bool { true }
    }
    final class Board: Pasteboard, @unchecked Sendable {
        var value: String?
        func setString(_ string: String) { value = string }
        func currentString() -> String? { value }
    }
    final class InstanceIds: InstanceIdPersisting, @unchecked Sendable {
        private var storage: [UUID: String] = [:]
        func lastInstanceId(forProfile id: UUID) -> String? { storage[id] }
        func setLastInstanceId(_ instanceId: String, forProfile id: UUID) { storage[id] = instanceId }
    }
    struct Owner: LeaseOwnerProbing {
        func current() -> LeaseOwnerIdentity? { LeaseOwnerIdentity(pid: 4242, launchDate: Date(timeIntervalSince1970: 1_800_000_000), bundleID: "helper") }
        func isActive(_ owner: LeaseOwnerIdentity) -> Bool { owner.pid == 4242 }
    }
    struct Files: ProfileFileAccessing {
        let snapshot: ProfileFileSnapshot?
        func read(_ url: URL) throws -> ProfileFileSnapshot {
            guard let snapshot else { throw CocoaError(.fileNoSuchFile) }
            return snapshot
        }
        func save(_ document: PortableProfileDocument, to url: URL, expected: ProfileFileRevision?,
                  beforeCommit: () throws -> Void) throws -> ProfileFileRevision { try #require(snapshot).revision }
        func existingRevision(_ url: URL) throws -> ProfileFileRevision? { snapshot?.revision }
    }

    static func configured(webForwards: Bool = false, editor: Bool = false) -> ConnectionProfile {
        var profile = ConnectionProfile(name: "Workstation", ssoStartUrl: "https://d-0123456789.awsapps.com/start",
                                        ssoRegion: "eu-west-1", accountId: "111122223333", roleName: "Admin",
                                        resourceRegion: "eu-central-1", instanceTagKey: "Name", instanceTagValue: "ws",
                                        secretId: "ec2/workstation-dcv-password", localPort: 18443, remotePort: 8443)
        profile.id = UUID(uuidString: "55555555-5555-4555-8555-555555555555")!
        if webForwards { profile.webForwards = .init(enabled: true, sshUser: "ec2-user", browser: .zen, browserMode: .separate) }
        if editor { profile.remoteDevelopment = .init(enabled: true) }
        return profile
    }

    struct Fixture {
        let runtime: HelperRuntime
        let session: HelperSession
        let outbox: Outbox
        let auth: MockAuthProvider
        let ec2: MockEC2Service
        let root: URL
        /// The runtime's own quit work, so a test can end this helper without running other fixtures' work.
        let quit: AppQuitHandler
    }

    static func fixture(auth: MockAuthProvider = MockAuthProvider(), browserSupported: Bool = true,
                        files: ProfileFileSnapshot? = nil, dcvCleanupDelay: Duration = ShellDCVLauncher.viewerReadWindow,
                        dcvNow: @escaping @Sendable () -> Date = { Date() },
                        isRejectedAuthorization: @escaping @Sendable (any Error) -> Bool = { _ in false },
                        profileFiles: (any ProfileFileAccessing)? = nil) async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("helper-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let ec2 = MockEC2Service()
        ec2.resolveResult = .success(EC2Instance(id: "i-0123456789abcdef0", state: .running, privateIpAddress: "10.0.0.1"))
        let requests = ShellRequests()
        let platform = WorkflowPlatform(terminateChildProcess: { _ in }, describeError: { _ in nil },
            isRejectedAuthorization: isRejectedAuthorization, isPermissionDenied: { _ in false }, isExpiredCredentials: { _ in false },
            resolveUsername: { _, _ in "ec2-user" }, identityToken: { _, _ in "token" },
            ownerOnlyFiles: OwnerOnlyFiles(isOwnerOnly: { _, _ in true }, withExclusiveLock: { _, body in try body() }))
        #if os(Windows)
        // Windows judges executables by extension: use a real one.
        let executable = root.appendingPathComponent("tool.exe")
        let system = ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows"
        try FileManager.default.copyItem(atPath: system + "\\System32\\where.exe", toPath: executable.path)
        #else
        let executable = root.appendingPathComponent("tool")
        _ = FileManager.default.createFile(atPath: executable.path, contents: Data("#!/bin/sh\n".utf8),
                                           attributes: [.posixPermissions: 0o755])
        #endif
        let services = HelperServices(
            platform: platform, auth: auth, ec2: ec2, ssm: MockSSMService(), secrets: MockSecretsService(),
            instanceConnect: Connect(), tunnel: MockTunnelProvider(), sshTunnel: SSH(), keyGenerator: Keys(),
            dcv: ShellDCVLauncher(requests: requests, directory: root, viewerInstalled: { true },
                                  writePrivate: { data, url in try data.write(to: url) }, cleanupDelay: dcvCleanupDelay,
                                  now: dcvNow),
            readiness: Ready(), tunnelListener: Listening(), instanceIds: InstanceIds(), keyValues: InMemoryKeyValueStore(),
            profileFiles: profileFiles ?? Files(snapshot: files), pasteboard: Board(), notifier: SilentNotificationService(),
            writePAC: { _, _ in root.appendingPathComponent("proxy.pac") },
            editor: .init(root: root.appendingPathComponent("access"), sshConfig: root.appendingPathComponent("ssh/config"),
                          helperPath: { executable.path }, pluginPath: { executable.path }, editorPath: { executable.path },
                          editorPreflight: { _ in }, owner: Owner(), sshAvailable: { true }),
            browserExecutable: { _ in browserSupported ? root.appendingPathComponent("chrome").path : nil },
            browserProfiles: root.appendingPathComponent("Browsers", isDirectory: true), requests: requests)
        let quit = AppQuitHandler()
        let runtime = HelperRuntime(services: services, pollInterval: .milliseconds(5), quit: quit)
        let outbox = Outbox()
        let session = HelperSession(build: "b", commands: runtime.commands(), send: { outbox.send($0) })
        await session.receive(.hello(build: "b", protocolVersion: 1))
        requests.attach(session.events)
        return Fixture(runtime: runtime, session: session, outbox: outbox, auth: auth, ec2: ec2, root: root, quit: quit)
    }

    static func run(_ fixture: Fixture, _ id: String, _ name: String, _ arguments: [String: String] = [:]) async {
        await fixture.session.receive(.command(id: id, name: name, arguments: arguments))
        await fixture.session.awaitIdle()
    }

    static func save(_ fixture: Fixture, _ profile: ConnectionProfile) async throws {
        let json = String(decoding: try JSONEncoder().encode(profile), as: UTF8.self)
        await run(fixture, "save-\(UUID())", "saveProfile", ["profile": json])
        await run(fixture, "active-\(UUID())", "setActiveProfile", ["id": profile.id.uuidString])
    }

    // MARK: Profiles

    @Test("Profiles are saved, listed, activated and imported through commands")
    func profiles() async throws {
        let imported = Self.configured()
        let snapshot = ProfileFileSnapshot(url: URL(fileURLWithPath: "/tmp/workstation.ssmconnect"),
            document: try PortableProfileDocument(profile: imported),
            revision: ProfileFileRevision(digest: "d", inode: 1, device: 1, permissions: 0o600, metadataVersion: "1"), isWritable: true)
        let f = try await Self.fixture(files: snapshot)
        try await Self.save(f, Self.configured())
        await Self.run(f, "list", "listProfiles")
        guard case let .completed(value) = f.outbox.result("list") else { Issue.record("list: \(String(describing: f.outbox.result("list")))"); return }
        #expect(value["active"] == Self.configured().id.uuidString)
        let listed = try JSONDecoder().decode([ConnectionProfile].self, from: Data(try #require(value["profiles"]).utf8))
        #expect(listed.map(\.id) == [Self.configured().id])
        await Self.run(f, "import", "importProfile", ["path": "/tmp/workstation.ssmconnect", "attach": "true"])
        guard case let .completed(importedValue) = f.outbox.result("import") else { Issue.record("import failed"); return }
        #expect(importedValue["id"] != nil && f.runtime.profiles.profiles.count == 2)
        await Self.run(f, "bad", "setActiveProfile", ["id": UUID().uuidString])
        guard case let .failed(error) = f.outbox.result("bad") else { Issue.record("bad id accepted"); return }
        #expect(error.code == "unknownProfile")
    }

    @Test("An attached profile file is saved only with consent and never over outside changes, which can be applied instead")
    func attachedFileSave() async throws {
        let f = try await Self.fixture(profileFiles: PortableProfileFiles(replace: { data, url in try data.write(to: url, options: .atomic) }))
        let file = f.root.appendingPathComponent("workstation.json")
        try ProfileDocumentCodec.write(try PortableProfileDocument(profile: Self.configured()), format: .json).write(to: file)
        await Self.run(f, "i", "importProfile", ["path": file.path, "attach": "true"])
        guard case let .completed(imported) = f.outbox.result("i"), let id = imported["id"] else { Issue.record("import failed"); return }
        await Self.run(f, "l", "listProfiles")
        guard case let .completed(listed) = f.outbox.result("l") else { Issue.record("list failed"); return }
        let files = try JSONDecoder().decode([[String: String]].self, from: Data(try #require(listed["files"]).utf8))
        #expect(files == [["id": id, "path": file.path, "pending": "false", "error": ""]])
        var profile = try #require(f.runtime.profiles.profiles.first { $0.id.uuidString == id })
        profile.roleName = "Developer"
        let json = String(decoding: try JSONEncoder().encode(profile), as: UTF8.self)

        // The first save to an attached file needs consent to its canonical formatting.
        await Self.run(f, "s1", "saveProfile", ["profile": json])
        #expect(f.outbox.result("s1").flatMap { if case let .failed(e) = $0 { e.code } else { nil } } == "formattingConsentRequired")
        #expect(try String(contentsOf: file, encoding: .utf8).contains("Admin"))
        await Self.run(f, "s2", "saveProfile", ["profile": json, "acceptFormatting": "true"])
        #expect(f.outbox.result("s2").map { if case .completed = $0 { true } else { false } } == true)
        #expect(try String(contentsOf: file, encoding: .utf8).contains("Developer"))

        // A change made outside SSM Connect is never overwritten; it can be applied instead.
        let saved = try String(contentsOf: file, encoding: .utf8)
        try Data(saved.replacingOccurrences(of: "Developer", with: "Auditor").utf8).write(to: file)
        let outsideBytes = try Data(contentsOf: file)
        profile.roleName = "Operator"
        await Self.run(f, "s3", "saveProfile", ["profile": String(decoding: try JSONEncoder().encode(profile), as: UTF8.self),
                                               "acceptFormatting": "true"])
        #expect(f.outbox.result("s3").flatMap { if case let .failed(e) = $0 { e.code } else { nil } } == "fileConflict")
        #expect(try Data(contentsOf: file) == outsideBytes)
        await Self.run(f, "a", "applyFileChanges", ["id": id])
        #expect(f.outbox.result("a").map { if case .completed = $0 { true } else { false } } == true)
        #expect(f.runtime.profiles.profiles.first { $0.id.uuidString == id }?.roleName == "Auditor")
    }

    // MARK: Desktop

    @Test("Connect is refused before any effect while the profile is not configured")
    func connectRefused() async throws {
        let f = try await Self.fixture()
        await Self.run(f, "c", "connect")
        #expect(f.outbox.rejection("c")?.code == "notConfigured")
        #expect(f.auth.authenticateCallCount == 0 && f.ec2.resolveCount == 0)
    }

    @Test("Connect streams the workflow's states, asks the shell to open DCV Viewer, and disconnects")
    func connectAndDisconnect() async throws {
        let f = try await Self.fixture()
        try await Self.save(f, Self.configured())
        await Self.run(f, "c", "connect")
        guard case let .completed(value) = f.outbox.result("c") else { Issue.record("connect: \(String(describing: f.outbox.result("c")))"); return }
        #expect(value["state"] == ConnectionState.connected.rawValue)
        #expect(f.outbox.events("desktop").last == "connected")
        let launch = try #require(f.outbox.launches("dcvViewer").first, "warning: \(value["warning"] ?? "")")
        #expect(launch["file"].map { FileManager.default.fileExists(atPath: $0) } == true)
        await Self.run(f, "s", "stopWorkstation")
        guard case .completed = f.outbox.result("s") else { Issue.record("stop failed"); return }
        #expect(f.ec2.stopCount == 1)
        await Self.run(f, "d", "disconnect")
        guard case let .completed(disconnected) = f.outbox.result("d") else { Issue.record("disconnect failed"); return }
        #expect(disconnected["state"] == ConnectionState.disconnected.rawValue)
    }

    @Test("The DCV connection file is deleted once the viewer has had time to read it")
    func connectionFileRemoved() async throws {
        let f = try await Self.fixture(dcvCleanupDelay: .milliseconds(200))
        try await Self.save(f, Self.configured())
        await Self.run(f, "c", "connect")
        let file = try #require(f.outbox.launches("dcvViewer").first?["file"])
        #expect(FileManager.default.fileExists(atPath: file))
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while FileManager.default.fileExists(atPath: file), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!FileManager.default.fileExists(atPath: file))
        await Self.run(f, "d", "disconnect")
    }

    // MARK: DCV connection file window (AC-30)

    static func dcvFiles(_ f: Fixture) -> Set<String> {
        Set(((try? FileManager.default.contentsOfDirectory(atPath: f.root.path)) ?? []).filter {
            $0.hasPrefix(DCVConnectionFile.tempFilePrefix) && $0.hasSuffix("." + DCVConnectionFile.fileExtension)
        })
    }

    static func leftover(_ f: Fixture, age: TimeInterval, now: Date = Date()) throws -> String {
        let name = DCVConnectionFile.tempFilePrefix + UUID().uuidString + "." + DCVConnectionFile.fileExtension
        let url = f.root.appendingPathComponent(name)
        try Data("leftover".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
        return name
    }

    @Test("On Windows and Linux the Viewer gets 120 seconds to read the connection file, and Connect does not wait for them")
    func dcvWindowIsLong() async throws {
        #expect(ShellDCVLauncher.viewerReadWindow == .seconds(120))
        let f = try await Self.fixture()
        try await Self.save(f, Self.configured())
        let started = ContinuousClock.now
        await Self.run(f, "c", "connect")
        #expect(ContinuousClock.now - started < .seconds(10))
        guard case .completed = f.outbox.result("c") else { Issue.record("connect: \(String(describing: f.outbox.result("c")))"); return }
        let file = try #require(f.outbox.launches("dcvViewer").first?["file"])
        #expect(FileManager.default.fileExists(atPath: file))
        await Self.run(f, "d", "disconnect")
    }

    @Test("Ending the helper removes a connection file still waiting for its window")
    func quitRemovesWaitingFile() async throws {
        let f = try await Self.fixture()
        try await Self.save(f, Self.configured())
        await Self.run(f, "c", "connect")
        let file = try #require(f.outbox.launches("dcvViewer").first?["file"])
        #expect(FileManager.default.fileExists(atPath: file))
        await HelperExit.end(f.session, quit: f.quit)
        #expect(!FileManager.default.fileExists(atPath: file))
    }

    @Test("A connect removes connection files a killed helper left once their window has passed, and keeps younger ones")
    func connectSweepsOldLeftovers() async throws {
        let f = try await Self.fixture()
        try await Self.save(f, Self.configured(webForwards: false))
        let old = try Self.leftover(f, age: 200)
        let young = try Self.leftover(f, age: 10)
        await Self.run(f, "c", "connect")
        let files = Self.dcvFiles(f)
        #expect(!files.contains(old))
        #expect(files.contains(young))
        let file = try #require(f.outbox.launches("dcvViewer").first?["file"])
        #expect(FileManager.default.fileExists(atPath: file))
        await Self.run(f, "d", "disconnect")
    }

    @Test("A reconnect keeps the earlier connection file until its own window ends, even after the clock moves forward")
    func reconnectKeepsLiveFile() async throws {
        final class Clock: @unchecked Sendable {
            private let lock = NSLock()
            private var offset: TimeInterval = 0
            func advance(_ seconds: TimeInterval) { lock.withLock { offset += seconds } }
            func now() -> Date { lock.withLock { Date().addingTimeInterval(offset) } }
        }
        let clock = Clock()
        let f = try await Self.fixture(dcvNow: { clock.now() })
        try await Self.save(f, Self.configured())
        await Self.run(f, "c1", "connect")
        let first = try #require(f.outbox.launches("dcvViewer").first?["file"])
        await Self.run(f, "d1", "disconnect")
        clock.advance(10)
        await Self.run(f, "c2", "connect")
        #expect(FileManager.default.fileExists(atPath: first))
        await Self.run(f, "d2", "disconnect")
        clock.advance(300)
        await Self.run(f, "c3", "connect")
        #expect(FileManager.default.fileExists(atPath: first))
        #expect(f.outbox.launches("dcvViewer").count == 3)
        await Self.run(f, "d3", "disconnect")
    }

    #if os(Linux) || os(Windows)
    @Test("The missing-Viewer message names this platform's own install")
    func missingViewerMessage() {
        let message = DCVError.viewerNotInstalled.errorDescription ?? ""
        #expect(!message.contains("/Applications"))
        #expect(!message.contains("brew"))
        #if os(Linux)
        #expect(message.contains(".deb") && message.contains(".rpm"))
        #else
        #expect(message.contains("MSI"))
        #endif
        #expect(message.contains("https://download.amazondcv.com"))
    }
    #endif

    @Test("Ending the helper cancels its commands and runs the workflows' quit work")
    func endRunsQuitWork() async throws {
        let f = try await Self.fixture()
        try await Self.save(f, Self.configured(webForwards: true))
        await Self.run(f, "w", "startWebForwards")
        let quit = AppQuitHandler()
        var ran = 0
        quit.register { ran += 1 }
        await HelperExit.end(f.session, quit: quit)
        #expect(ran == 1)
        #expect(await f.session.isEnded)
    }

    @Test("A connect after a rejected refresh reports that sign-in is required, then resumes after one explicit sign-in")
    func signInRequiredThenResume() async throws {
        let auth = MockAuthProvider(refreshOutcome: .failure(AuthError.signInRequired))
        let f = try await Self.fixture(auth: auth, isRejectedAuthorization: { ($0 as? AuthError) == .signInRequired })
        try await Self.save(f, Self.configured())
        await f.session.receive(.command(id: "c", name: "connect", arguments: [:]))
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !f.outbox.events("authorization").contains("signInRequired"), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(f.outbox.events("authorization").contains("signInRequired"))
        #expect(f.outbox.result("c") == nil, "the connect waits for the sign-in")
        await f.session.receive(.command(id: "s", name: "signIn", arguments: [:]))
        await f.session.awaitIdle()
        guard case let .completed(value) = f.outbox.result("c") else { Issue.record("connect: \(String(describing: f.outbox.result("c")))"); return }
        #expect(value["state"] == ConnectionState.connected.rawValue)
        #expect(f.outbox.events("authorization").last == "ready")
        #expect(auth.authenticateCallCount == 1)
        await Self.run(f, "d", "disconnect")
    }

    @Test("Stopping the workstation is refused while not connected")
    func stopRefused() async throws {
        let f = try await Self.fixture()
        try await Self.save(f, Self.configured())
        await Self.run(f, "s", "stopWorkstation")
        #expect(f.outbox.rejection("s")?.code == "notConnected" && f.ec2.stopCount == 0)
    }

    @Test("Cancelling a connect tears the connection down with one cancelled result, and tells the shell")
    func cancelConnect() async throws {
        let f = try await Self.fixture(auth: MockAuthProvider(delay: .seconds(5)))
        try await Self.save(f, Self.configured())
        await f.session.receive(.command(id: "c", name: "connect", arguments: [:]))
        try await Task.sleep(for: .milliseconds(50))
        await f.session.receive(.cancel(id: "c"))
        await f.session.awaitIdle()
        #expect(f.outbox.result("c") == .cancelled)
        #expect(f.runtime.connection.state == .disconnected)
        // The tray shows the last state event, so the torn-down connection's state is the last one.
        #expect(f.outbox.events("desktop").last == "disconnected")
    }

    @Test("Sign-in runs the shared authorization workflow")
    func signIn() async throws {
        let f = try await Self.fixture()
        try await Self.save(f, Self.configured())
        await Self.run(f, "i", "signIn")
        #expect(f.outbox.result("i") == .completed(["status": "ready"]))
        #expect(f.auth.authenticateCallCount == 1)
    }

    // MARK: Editor, web forwards and browser

    @Test("Opening the editor asks the shell to start VS Code with the workflow's arguments")
    func editor() async throws {
        let f = try await Self.fixture()
        try await Self.save(f, Self.configured(webForwards: true, editor: true))
        await Self.run(f, "setup", "installEditorSetup", ["consent": "true"])
        guard case .completed = f.outbox.result("setup") else { Issue.record("setup: \(String(describing: f.outbox.result("setup")))"); return }
        await Self.run(f, "e", "openEditor")
        guard case .completed = f.outbox.result("e") else { Issue.record("editor: \(String(describing: f.outbox.result("e")))"); return }
        let launch = try #require(f.outbox.launches("vsCode").first)
        #expect(launch["arguments"]?.split(separator: "\u{1F}").contains("--new-window") == true)
        #expect(f.outbox.events("editor") == ["opening", "launched"])
    }

    @Test("Web forwards start and stop through the shared workflow")
    func webForwards() async throws {
        let f = try await Self.fixture()
        try await Self.save(f, Self.configured(webForwards: true))
        await Self.run(f, "w", "startWebForwards")
        #expect(f.outbox.result("w") == .completed(["state": "on"]))
        await Self.run(f, "x", "stopWebForwards")
        #expect(f.outbox.result("x") == .completed(["state": WebForwardsStateMachine.State.off.rawValue]))
    }

    @Test("The managed browser opens with the private-domain routing macOS uses, and an unsupported one is refused by name")
    func browser() async throws {
        let f = try await Self.fixture()
        var chrome = Self.configured(webForwards: true)
        chrome.webForwards?.browser = .chrome
        chrome.webForwards?.browserMode = .separate
        chrome.webForwards?.proxySuffixes = [".corp.example"]
        try await Self.save(f, chrome)
        await Self.run(f, "b", "openBrowser")
        guard case .completed = f.outbox.result("b") else { Issue.record("browser: \(String(describing: f.outbox.result("b")))"); return }
        let launch = try #require(f.outbox.launches("browser").first)
        #expect(launch["path"] == f.root.appendingPathComponent("chrome").path)
        let arguments = (launch["arguments"] ?? "").split(separator: "\u{1F}").map(String.init)
        // Only the private suffixes go through SOCKS, without a direct fallback; nothing else does.
        #expect(!arguments.contains { $0.hasPrefix("--proxy-server") })
        let pacArgument = try #require(arguments.first { $0.hasPrefix("--proxy-pac-url=data:application/x-ns-proxy-autoconfig;base64,") })
        let pac = String(decoding: try #require(Data(base64Encoded: String(pacArgument.split(separator: ",", maxSplits: 1)[1]))), as: UTF8.self)
        #expect(pac.contains("dnsDomainIs(host, \".corp.example\")) return \"SOCKS5 127.0.0.1:1080\";"))
        #expect(pac.contains("return \"DIRECT\";"))
        // Its own profile folder, owner-only, never the user's own browser profile.
        let directory = try #require(arguments.first { $0.hasPrefix("--user-data-dir=") }).dropFirst("--user-data-dir=".count)
        #expect(String(directory).hasSuffix(chrome.id.uuidString))
        #expect(FileManager.default.fileExists(atPath: String(directory)))
        #expect(arguments.contains("--no-first-run") && arguments.last == "about:blank")

        // Zen keeps the same routing in its profile's preferences.
        var zen = chrome
        zen.webForwards?.browser = .zen
        try await Self.save(f, zen)
        await Self.run(f, "z", "openBrowser")
        let zenLaunch = try #require(f.outbox.launches("browser").last)
        let zenArguments = (zenLaunch["arguments"] ?? "").split(separator: "\u{1F}").map(String.init)
        let profileIndex = try #require(zenArguments.firstIndex(of: "--profile"))
        let preferences = try String(contentsOfFile: zenArguments[profileIndex + 1] + "/user.js", encoding: .utf8)
        #expect(preferences.contains("user_pref(\"network.proxy.type\", 2);"))
        #expect(preferences.contains("user_pref(\"network.proxy.failover_direct\", false);"))
        #expect(preferences.contains("\"network.proxy.autoconfig_url\", \"data:application/x-ns-proxy-autoconfig;base64,"))

        let unsupported = try await Self.fixture(browserSupported: false)
        try await Self.save(unsupported, chrome)
        await Self.run(unsupported, "b", "openBrowser")
        guard case let .failed(error) = unsupported.outbox.result("b") else { Issue.record("unsupported accepted"); return }
        #expect(error.message == CapabilityError.missing(.browser).errorDescription)
        #expect(unsupported.outbox.launches("browser").isEmpty)
    }

    @Test("Every shell action has a command")
    func table() async throws {
        let f = try await Self.fixture()
        #expect(Set(f.runtime.commands().keys) == ["listProfiles", "saveProfile", "setActiveProfile", "importProfile", "applyFileChanges", "signIn",
                                                    "connect", "disconnect", "stopWorkstation", "installEditorSetup", "openEditor",
                                                    "startWebForwards", "stopWebForwards", "openBrowser"])
    }
}
