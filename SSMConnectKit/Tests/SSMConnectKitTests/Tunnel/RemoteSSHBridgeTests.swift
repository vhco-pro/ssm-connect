import AppKit
import ApplicationServices
import Foundation
import Testing
@testable import SSMConnectKit

@Suite("Remote SSH bridge") struct RemoteSSHBridgeTests {
    @Test func nativeEditorArgumentsAndURIs() throws {
        let host = RemoteSSHConfiguration.alias(ConnectionProfile.example.id)
        #expect(try RemoteSSHConfiguration.arguments(alias: host, folder: nil) == ["--new-window", "--remote", "ssh-remote+" + host])
        let arguments = try RemoteSSHConfiguration.arguments(alias: host, folder: "/home/example/code/project.with spaces")
        #expect(arguments[1] == "--folder-uri")
        #expect(arguments[2].contains("project.with%20spaces"))
        #expect(throws: RemoteSSHError.self) { try RemoteSSHConfiguration.folderURI(alias: host, folder: "~/code") }
        #expect(throws: RemoteSSHError.self) { try RemoteSSHConfiguration.folderURI(alias: host, folder: "/code\nHost *") }
    }

    @Test @MainActor func editorCLITimeoutAndCancellationAreBounded() async throws {
        let started = ContinuousClock.now
        await #expect(throws: RemoteSSHError.self) {
            _ = try await RemoteEditorPreflight.run("/usr/bin/tail", arguments: ["-f", "/dev/null"], timeout: .milliseconds(50))
        }
        #expect(ContinuousClock.now - started < .seconds(2))
        let pending = Task { try await RemoteEditorPreflight.run("/usr/bin/tail", arguments: ["-f", "/dev/null"]) }
        try await Task.sleep(for: .milliseconds(50))
        pending.cancel()
        await #expect(throws: CancellationError.self) { _ = try await pending.value }
        await #expect(throws: RemoteSSHError.self) {
            _ = try await RemoteEditorPreflight.run("/usr/bin/yes", arguments: ["output"])
        }
        let result = try await RemoteEditorPreflight.run("/usr/bin/printf", arguments: ["ready"])
        #expect(String(decoding: result, as: UTF8.self) == "ready")
    }

    @Test @MainActor func profileSwitchCancelsPendingEditorOpen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var original = ConnectionProfile.example
        original.remoteDevelopment = .init(enabled: true)
        let ec2 = SequencedEC2Service(resolveResults: [.success(.stub(state: .running))])
        var enteredPreflight = false
        let machine = RemoteDevelopmentStateMachine(profile: original, root: root.appendingPathComponent("owned"),
            configURL: root.appendingPathComponent("user/config"), ec2: ec2,
            helperPath: { "/usr/bin/true" }, editorPath: { "/usr/bin/true" }, editorPreflight: { _ in
                enteredPreflight = true
                _ = try await RemoteEditorPreflight.run("/usr/bin/tail", arguments: ["-f", "/dev/null"], timeout: .seconds(1))
            })
        try machine.installSetup(consent: true)
        machine.open()
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !enteredPreflight && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(enteredPreflight)
        machine.apply(profile: original)
        #expect(machine.isOpening)
        var replacement = original
        replacement.id = UUID()
        replacement.name = "Replacement"
        machine.apply(profile: replacement)
        #expect(machine.profile == replacement)
        await machine.awaitOpening()
        #expect(!machine.isOpening)
        #expect(machine.errorMessage == nil)
        #expect(!machine.editorLaunched)
        #expect(ec2.resolveCount == 0)
    }

    @Test func configurationHasNoCredentialsOrSecurityBypass() throws {
        let lease = RemoteSSHLease(profile: .example, instanceID: "i-0123456789abcdef0", user: "example",
            keyPath: "/tmp/key with spaces", pluginPath: "/tmp/plugin", ownerPID: 1, ownerLaunchDate: Date(),
            ownerBundleID: "test", generation: UUID(), expiresAt: Date().addingTimeInterval(60))
        let contents = try RemoteSSHConfiguration.contents(lease: lease, leasePath: "/tmp/lease.json",
            helperPath: "/Applications/SSM Connect.app/Contents/Helpers/ssm-connect-proxy", knownHostsPath: "/tmp/known-hosts")
        #expect(contents.contains("StrictHostKeyChecking accept-new"))
        #expect(contents.contains("ForwardAgent no"))
        #expect(contents.contains("--configuration '/tmp/lease.json'"))
        #expect(!contents.contains("TokenValue"))
        #expect(!contents.contains("StrictHostKeyChecking no"))
        #expect(!contents.contains("/dev/null"))
        #expect(throws: RemoteSSHError.self) { try lease.validate(path: "/tmp/lease.json", ownerActive: false) }
    }

    @Test func leaseExpiryRenewsOnlyTheSameWorkstationIdentity() throws {
        let now = Date()
        let profile = ConnectionProfile.example
        let lease = RemoteSSHLease(profile: profile, instanceID: "i-0123456789abcdef0", user: "example",
            keyPath: "/tmp/key", pluginPath: "/tmp/plugin", ownerPID: 1, ownerLaunchDate: now,
            ownerBundleID: "test", generation: UUID(), expiresAt: now.addingTimeInterval(60))
        #expect(try lease.canReuse(profile: profile, instanceID: lease.instanceID, user: lease.user, now: now))
        #expect(try !lease.canReuse(profile: profile, instanceID: lease.instanceID, user: lease.user, now: lease.expiresAt))
        #expect(throws: RemoteSSHError.self) {
            try lease.canReuse(profile: profile, instanceID: "i-11111111111111111", user: lease.user, now: lease.expiresAt)
        }
        #expect(throws: RemoteSSHError.self) {
            try lease.canReuse(profile: profile, instanceID: lease.instanceID, user: "other", now: lease.expiresAt)
        }
        var changed = profile
        changed.instanceTagValue = "another-workstation"
        #expect(throws: RemoteSSHError.self) {
            try lease.canReuse(profile: changed, instanceID: lease.instanceID, user: lease.user, now: now)
        }
    }

    @Test @MainActor func reopeningExpiredLeaseCreatesFreshOwnedGeneration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var profile = ConnectionProfile.example
        profile.remoteDevelopment = .init(enabled: true)
        profile.webForwards = .init(enabled: true, sshUser: "example")
        let recorder = WebEventRecorder()
        let machine = RemoteDevelopmentStateMachine(profile: profile, root: root.appendingPathComponent("owned"),
            configURL: root.appendingPathComponent("user/config"), auth: MockAuthProvider(),
            ec2: MockEC2Service(), ssm: MockSSMService(), keyGenerator: FakeSSHKeyGenerator(recorder: recorder),
            helperPath: { "/usr/bin/true" }, editorPath: { "/usr/bin/true" }, editorPreflight: { _ in },
            ownerIdentity: { (12345, Date(), "test-owner") })
        defer { machine.stop() }
        try machine.installSetup(consent: true)
        machine.open()
        await machine.awaitOpening()
        try #require(machine.errorMessage == nil && machine.editorLaunched)
        let leaseURL = root.appendingPathComponent("owned/\(profile.id.uuidString)/lease.json")
        let first = try JSONDecoder().decode(RemoteSSHLease.self, from: Data(contentsOf: leaseURL))
        let expired = RemoteSSHLease(profile: first.profile, instanceID: first.instanceID, user: first.user,
            keyPath: first.keyPath, pluginPath: first.pluginPath, ownerPID: first.ownerPID,
            ownerLaunchDate: first.ownerLaunchDate, ownerBundleID: first.ownerBundleID,
            generation: first.generation, expiresAt: Date().addingTimeInterval(-1))
        try BrowserPrivateFiles.write(try JSONEncoder().encode(expired), to: leaseURL)
        machine.open()
        await machine.awaitOpening()
        try #require(machine.errorMessage == nil && machine.editorLaunched)
        let renewed = try JSONDecoder().decode(RemoteSSHLease.self, from: Data(contentsOf: leaseURL))
        #expect(renewed.generation != first.generation)
        #expect(renewed.keyPath != first.keyPath)
        #expect(renewed.expiresAt > Date())
        #expect(renewed.instanceID == first.instanceID && renewed.user == first.user)
        #expect(recorder.values == ["key", "key"])
    }

    @Test func sshIncludeConsentAndConditionalRestore() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("user/config")
        let original = "Host personal\n  HostName example.com\n"
        try BrowserPrivateFiles.write(Data(original.utf8), to: config)
        let setup = RemoteSSHSetup(root: root.appendingPathComponent("owned"), configURL: config)
        try setup.install(consent: false)
        #expect(try String(contentsOf: config, encoding: .utf8) == original)
        try setup.install(consent: true)
        #expect(setup.isInstalled)
        try setup.writeHost("Host ssm-connect-test\n  HostName i-0123456789abcdef0\n", profileID: UUID())
        try setup.restore()
        #expect(try String(contentsOf: config, encoding: .utf8) == original)
        try setup.install(consent: true)
        try BrowserPrivateFiles.write(Data(original.utf8), to: config)
        #expect(throws: RemoteSSHError.self) { try setup.restore() }
    }

    @Test @MainActor func repeatedOpenDeduplicatesAndReusesOwnedLease() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var profile = ConnectionProfile.example
        profile.remoteDevelopment = .init(enabled: true)
        profile.webForwards = .init(enabled: true, sshUser: "example")
        let auth = MockAuthProvider(delay: .milliseconds(50))
        let recorder = WebEventRecorder()
        let machine = RemoteDevelopmentStateMachine(profile: profile, root: root.appendingPathComponent("owned"),
            configURL: root.appendingPathComponent("user/config"), auth: auth,
            ec2: MockEC2Service(), ssm: MockSSMService(), keyGenerator: FakeSSHKeyGenerator(recorder: recorder),
            helperPath: { "/usr/bin/true" }, editorPath: { "/usr/bin/true" }, editorPreflight: { _ in },
            ownerIdentity: { (12345, Date(), "test-owner") })
        defer { machine.stop() }
        try machine.installSetup(consent: true)
        machine.open()
        machine.open()
        await machine.awaitOpening()
        try #require(machine.errorMessage == nil && machine.editorLaunched)
        #expect(auth.authenticateCallCount == 1)
        let leaseURL = root.appendingPathComponent("owned/\(profile.id.uuidString)/lease.json")
        let initial = try JSONDecoder().decode(RemoteSSHLease.self, from: Data(contentsOf: leaseURL))
        machine.open()
        await machine.awaitOpening()
        let reused = try JSONDecoder().decode(RemoteSSHLease.self, from: Data(contentsOf: leaseURL))
        #expect(reused.generation == initial.generation && reused.keyPath == initial.keyPath)
        #expect(recorder.values == ["key"])
    }

    @Test @MainActor func signInFailureIsRetryableWithoutWorkstationActions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var profile = ConnectionProfile.example
        profile.remoteDevelopment = .init(enabled: true)
        profile.webForwards = .init(enabled: true, sshUser: "example")
        let auth = MockAuthProvider(authenticateOutcome: .failure(AuthError.signInRequired))
        let ec2 = SequencedEC2Service(resolveResults: [.success(.stub(state: .running))])
        let recorder = WebEventRecorder()
        let machine = RemoteDevelopmentStateMachine(profile: profile, root: root.appendingPathComponent("owned"),
            configURL: root.appendingPathComponent("user/config"), auth: auth,
            ec2: ec2, ssm: MockSSMService(), keyGenerator: FakeSSHKeyGenerator(recorder: recorder),
            helperPath: { "/usr/bin/true" }, editorPath: { "/usr/bin/true" }, editorPreflight: { _ in },
            ownerIdentity: { (12345, Date(), "test-owner") })
        defer { machine.stop() }
        try machine.installSetup(consent: true)
        machine.open()
        await machine.awaitOpening()
        #expect(machine.errorMessage == AuthError.signInRequired.localizedDescription)
        #expect(ec2.resolveCount == 0 && recorder.values.isEmpty)
        #expect(!machine.editorLaunched && !machine.isActive)
        auth.authenticateOutcome = .success(.stub)
        machine.open()
        await machine.awaitOpening()
        #expect(machine.errorMessage == nil && machine.editorLaunched && machine.isActive)
        #expect(recorder.values == ["key"])
    }

    @Test @MainActor func freshSetupConsentAndMissingEditorRefuseBeforeAWS() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        var profile = ConnectionProfile.example
        profile.remoteDevelopment = .init(enabled: true)
        let auth = MockAuthProvider()
        let config = root.appendingPathComponent("user/config")
        let machine = RemoteDevelopmentStateMachine(profile: profile, root: root.appendingPathComponent("owned"),
            configURL: config, auth: auth, helperPath: { "/usr/bin/true" }, editorPath: { nil })
        try machine.installSetup(consent: false)
        machine.open()
        await machine.awaitOpening()
        #expect(!FileManager.default.fileExists(atPath: config.path))
        #expect(!machine.setupInstalled && auth.authenticateCallCount == 0)
        try machine.installSetup(consent: true)
        machine.open()
        await machine.awaitOpening()
        #expect(machine.setupInstalled && machine.errorMessage != nil)
        #expect(!machine.editorLaunched && auth.authenticateCallCount == 0)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SSM_REMOTE_TRANSPORT_PROBE"] == "1"))
    @MainActor func realSSHCommandChannelsRefreshAuthorization() async throws {
        let owner = try #require(NSRunningApplication.runningApplications(withBundleIdentifier: "pro.vhco.ssm-connect.about-preview").first)
        let defaults = try #require(UserDefaults(suiteName: "pro.vhco.ssm-connect"))
        let data = try #require(defaults.data(forKey: "ssmconnect.profiles.v1"))
        let profiles = try JSONDecoder().decode([ConnectionProfile].self, from: data)
        let profile = try #require(profiles.first { $0.webForwards?.enabled == true })
        let interactive = ProcessInfo.processInfo.environment["SSM_REMOTE_INTERACTIVE_SIGNIN"] == "1"
        let credentials = try await withStageTimeout("Probe AWS sign-in", interactive ? .seconds(600) : .seconds(20)) {
            if interactive { return try await AWSAuthProvider().authenticate(profile: profile) }
            return try await AWSAuthProvider().refreshIfNeeded(profile: profile)
        }
        let instance = try await EC2Service().resolveInstance(tagKey: profile.instanceTagKey,
            tagValue: profile.instanceTagValue, region: profile.resourceRegion, credentials: credentials)
        try #require(instance.state == .running)
        let configuredUser = profile.webForwards?.sshUser ?? ""
        let user = configuredUser.isEmpty
            ? try await STSIdentityResolver(presigner: STSPresigner(region: profile.resourceRegion)).resolve(credentials: credentials).username
            : configuredUser
        let key = try await SSHKeyGenerator().generate()
        defer { key.remove() }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.privateKeyPath + ".pub")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ssm-remote-probe-" + UUID().uuidString)
        try BrowserPrivateFiles.directory(root)
        defer { try? FileManager.default.removeItem(at: root) }
        let plugin = owner.bundleURL!.appendingPathComponent("Contents/Helpers/session-manager-plugin").path
        let helper = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(".build/debug/ssm-connect-proxy").path
        try #require(FileManager.default.isExecutableFile(atPath: helper))
        let leaseURL = root.appendingPathComponent("lease.json")
        let lease = RemoteSSHLease(profile: profile, instanceID: instance.id, user: user,
            keyPath: key.privateKeyPath, pluginPath: plugin, ownerPID: owner.processIdentifier,
            ownerLaunchDate: try #require(owner.launchDate), ownerBundleID: "pro.vhco.ssm-connect.about-preview",
            generation: UUID(), expiresAt: Date().addingTimeInterval(300))
        try BrowserPrivateFiles.write(try JSONEncoder().encode(lease), to: leaseURL)
        let config = root.appendingPathComponent("config")
        try BrowserPrivateFiles.write(Data(try RemoteSSHConfiguration.contents(lease: lease,
            leasePath: leaseURL.path, helperPath: helper, knownHostsPath: root.appendingPathComponent("known-hosts").path).utf8), to: config)
        try await withThrowingTaskGroup(of: String.self) { group in
            for channel in 0..<3 {
                group.addTask {
                    let outputURL = root.appendingPathComponent("concurrent-output-\(channel)")
                    let errorURL = root.appendingPathComponent("concurrent-error-\(channel)")
                    try BrowserPrivateFiles.write(Data(), to: outputURL)
                    try BrowserPrivateFiles.write(Data(), to: errorURL)
                    let output = try FileHandle(forWritingTo: outputURL)
                    let errors = try FileHandle(forWritingTo: errorURL)
                    defer { try? output.close(); try? errors.close() }
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                    process.arguments = ["-F", config.path, "-T", RemoteSSHConfiguration.alias(profile.id),
                        "printf 'SSM_CONCURRENT_\(channel)\\n'"]
                    process.standardInput = FileHandle.nullDevice
                    process.standardOutput = output
                    process.standardError = errors
                    try process.run()
                    let deadline = ContinuousClock.now.advanced(by: .seconds(100))
                    while process.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
                    if process.isRunning { process.terminate() }
                    if process.isRunning || process.terminationStatus != 0 {
                        let message = try String(contentsOf: errorURL, encoding: .utf8)
                        let reason = message.contains("Permission denied") ? "SSH permission denied"
                            : message.contains("Host key verification failed") ? "host key verification failed"
                            : message.contains(RemoteSSHProxyRuntime.failureMessage.trimmingCharacters(in: .whitespacesAndNewlines))
                                ? "bridge authorization refused" : "SSH child failed or timed out"
                        print("Owned concurrent channel \(channel): \(reason)")
                    }
                    try #require(!process.isRunning && process.terminationStatus == 0)
                    return try String(contentsOf: outputURL, encoding: .utf8)
                }
            }
            var responses: Set<String> = []
            for try await response in group { responses.insert(response) }
            #expect(responses == Set((0..<3).map { "SSM_CONCURRENT_\($0)\n" }))
        }
        for channel in 0..<2 {
            if channel == 1 { try await Task.sleep(for: .seconds(65)) }
            let output = root.appendingPathComponent("output-\(channel)")
            let errors = root.appendingPathComponent("errors-\(channel)")
            try BrowserPrivateFiles.write(Data(), to: output)
            try BrowserPrivateFiles.write(Data(), to: errors)
            let stdout = try FileHandle(forWritingTo: output)
            let stderr = try FileHandle(forWritingTo: errors)
            defer { try? stdout.close(); try? stderr.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            process.arguments = ["-F", config.path, "-T", RemoteSSHConfiguration.alias(profile.id),
                                 "printf 'SSM_CONNECT_REMOTE_OK\\n'"]
            process.standardOutput = stdout
            process.standardError = stderr
            process.standardInput = FileHandle.nullDevice
            try process.run()
            let deadline = ContinuousClock.now.advanced(by: .seconds(100))
            while process.isRunning && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
            if process.isRunning { process.terminate() }
            try #require(!process.isRunning && process.terminationStatus == 0)
            let response = try String(contentsOf: output, encoding: .utf8)
            #expect(response == "SSM_CONNECT_REMOTE_OK\n")
        }
        print("Concurrent SSH-over-SSM channels and fresh authorization after 65 seconds passed; normal SSH/editor configuration untouched.")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SSM_REMOTE_MENU_PROBE"] == "1"))
    @MainActor func previewNativeEditorMenu() async throws {
        try #require(AXIsProcessTrusted())
        let bundleID = "pro.vhco.ssm-connect.about-preview"
        try #require(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty)
        let defaults = try #require(UserDefaults(suiteName: bundleID))
        let store = ProfileStore(defaults: defaults)
        var profile = try #require(store.profiles.first)
        try #require(store.profiles.count == 1 && profile.name == "Browser Preview")
        profile.remoteDevelopment = .init(enabled: true)
        store.updateProfile(profile)
        defaults.synchronize()
        let applicationURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).deletingLastPathComponent()
            .appendingPathComponent(".build/AboutPreview/Build/Products/Debug/SSMConnect.app")
        let application = try await NSWorkspace.shared.openApplication(at: applicationURL, configuration: .init())
        try #require(application.bundleIdentifier == bundleID)
        let root = AXUIElementCreateApplication(application.processIdentifier)
        func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(element, name as CFString, &value)
            return value
        }
        func find(_ element: AXUIElement, name: String? = nil, role: String? = nil, depth: Int = 0) -> AXUIElement? {
            guard depth < 12 else { return nil }
            let title = attribute(element, kAXTitleAttribute) as? String
            let description = attribute(element, kAXDescriptionAttribute) as? String
            let elementRole = attribute(element, kAXRoleAttribute) as? String
            if (name == nil || title == name || description == name) && (role == nil || elementRole == role) { return element }
            for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                if let match = find(child, name: name, role: role, depth: depth + 1) { return match }
            }
            return nil
        }
        try await Task.sleep(for: .seconds(1))
        let menu = try #require(find(root, role: kAXMenuBarItemRole))
        try #require(AXUIElementPerformAction(menu, kAXPressAction as CFString) == .success)
        try await Task.sleep(for: .milliseconds(200))
        let open = try #require(find(root, name: "Open VS Code"))
        try #require(AXUIElementPerformAction(open, kAXPressAction as CFString) == .success)
        try await Task.sleep(for: .milliseconds(500))
        if let consent = find(root, name: "Continue", role: kAXButtonRole) {
            try #require(AXUIElementPerformAction(consent, kAXPressAction as CFString) == .success)
        }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(bundleID + "/RemoteAccess")
        let leaseURL = directory.appendingPathComponent(profile.id.uuidString + "/lease.json")
        let deadline = ContinuousClock.now.advanced(by: .seconds(90))
        while !FileManager.default.fileExists(atPath: leaseURL.path) && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        try #require(FileManager.default.fileExists(atPath: leaseURL.path))
        let lease = try JSONDecoder().decode(RemoteSSHLease.self, from: Data(contentsOf: leaseURL))
        #expect(lease.ownerPID == application.processIdentifier)
        try lease.validate(path: leaseURL.path, ownerActive: lease.ownerIsActive)
        #expect(RemoteSSHSetup(root: directory, configURL: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")).isInstalled)
        try await Task.sleep(for: .seconds(2))
        AXUIElementPerformAction(menu, kAXPressAction as CFString)
        try await Task.sleep(for: .milliseconds(200))
        #expect(find(root, name: "VS Code launched") != nil)
        print("Approved native preview menu setup and editor launch passed; remote folder selection remains in VS Code.")
    }
}