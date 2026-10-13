import AppKit
import ApplicationServices
import Foundation
import Testing
@testable import SSMConnectKit

@Suite("BrowserBootstrap") @MainActor struct BrowserBootstrapTests {
    func descriptor(_ choice: ManagedBrowserChoice = .zen) -> BrowserDescriptor {
        .init(choice: choice, bundleID: choice == .zen ? "app.zen-browser.zen" : "com.google.Chrome",
              applicationURL: URL(fileURLWithPath: "/tmp/TestBrowser.app"),
              executableURL: URL(fileURLWithPath: "/tmp/TestBrowser.app/Contents/MacOS/browser"),
              version: choice == .zen ? "1.23.1b" : "156.0.8078.12")
    }
    func profile(mode: BrowserMode = .separate) -> ConnectionProfile {
        var profile = ConnectionProfile.example
        profile.webForwards = .init(enabled: true, socksPort: 1080, proxySuffixes: [".internal.example.com"],
                                   browser: .zen, browserMode: mode)
        return profile
    }
    func temporary() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try BrowserPrivateFiles.directory(url)
        return url
    }
    @Test func familyArgumentsAndInlinePAC() throws {
        let routing = try BrowserRouting(profile: profile(), descriptor: descriptor(), mode: .separate,
                                         directory: URL(fileURLWithPath: "/tmp/profile with spaces"))
        #expect(try routing.arguments(family: .firefox) == ["--new-instance", "--profile", "/tmp/profile with spaces", "--new-window", "about:blank"])
        let chrome = try routing.arguments(family: .chromium)
        #expect(chrome.contains("--user-data-dir=/tmp/profile with spaces"))
        #expect(chrome.contains("--proxy-pac-url=" + (try routing.pacDataURL)))
        #expect(try routing.pac.contains("SOCKS5 127.0.0.1:1080"))
        #expect(try routing.firefoxPreferences["network.proxy.socks5_remote_dns"] == .bool(true))
        #expect(try routing.firefoxPreferences["network.proxy.failover_direct"] == .bool(false))
        #expect(try ProxyPreference.render(routing.firefoxPreferences).contains("data:application/x-ns-proxy-autoconfig"))
        #expect(try !ProxyPreference.render(routing.firefoxPreferences).contains("\\/"))
        #expect(!chrome.joined().contains("remote-debugging"))
        #expect(!chrome.joined().contains("ignore-certificate"))
    }
    @Test func fingerprintAndSupport() throws {
        let directory = URL(fileURLWithPath: "/tmp/test")
        let original = profile()
        var changed = original
        changed.webForwards?.proxySuffixes.append(".another.example.com")
        let first = try BrowserRouting(profile: original, descriptor: descriptor(), mode: .separate, directory: directory)
        let second = try BrowserRouting(profile: changed, descriptor: descriptor(), mode: .separate, directory: directory)
        #expect(try first.fingerprint != second.fingerprint)
        #expect(descriptor(.chrome).supports(.existing) == false)
        #expect(descriptor(.zen).supports(.existing))
    }
    @Test func persistentSeparateDirectoryAndPendingChange() async throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        var launches: [[String]] = []
        let service = BrowserBootstrap(root: root, discover: { [descriptor()] }, isRunning: { _ in true },
                                       launch: { _, arguments in launches.append(arguments) })
        var profile = profile()
        try await service.open(profile: profile)
        try await service.open(profile: profile)
        #expect(launches[0] == launches[1])
        profile.webForwards?.socksPort = 1081
        #expect(throws: BrowserBootstrapError.self) { try service.preflight(profile: profile) }
        #expect(launches.count == 2)
        let record = root.appendingPathComponent(profile.id.uuidString + "/zen/ssm-connect-routing.json")
        let attributes = try FileManager.default.attributesOfItem(atPath: record.path)
        #expect(attributes[.posixPermissions] as? Int == 0o600)
    }
    @Test func scopedConsentRestoreAndLaterChange() throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("ordinary")
        try BrowserPrivateFiles.directory(target)
        let prefsURL = target.appendingPathComponent("prefs.js")
        let original = "user_pref(\"browser.example.unrelated\", true);\nuser_pref(\"network.proxy.type\", 0);\n"
        try BrowserPrivateFiles.write(Data(original.utf8), to: prefsURL)
        var profile = profile(mode: .existing)
        profile.webForwards?.browserProfilePath = target.path
        let service = BrowserBootstrap(root: root, discover: { [descriptor()] }, isRunning: { _ in false })
        try service.setupExisting(profile: profile, consent: false)
        #expect(try String(contentsOf: prefsURL, encoding: .utf8) == original)
        try service.setupExisting(profile: profile, consent: true)
        #expect(try String(contentsOf: prefsURL, encoding: .utf8).contains("browser.example.unrelated"))
        try service.restore(profile: profile)
        #expect(try ProxyPreference.parse(String(contentsOf: prefsURL, encoding: .utf8)) == ["network.proxy.type": .integer(0)])
        try service.setupExisting(profile: profile, consent: true)
        let current = try String(contentsOf: prefsURL, encoding: .utf8)
        let changed = try ProxyPreference.replacing(["network.proxy.type"], with: ["network.proxy.type": .integer(1)], in: current)
        try BrowserPrivateFiles.write(Data(changed.utf8), to: prefsURL)
        #expect(throws: BrowserBootstrapError.self) { try service.restore(profile: profile) }
        #expect(try String(contentsOf: prefsURL, encoding: .utf8) == changed)
    }
    @Test func refusesProxyConflictRunningBrowserAndOtherOwner() throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("ordinary")
        try BrowserPrivateFiles.directory(target)
        try BrowserPrivateFiles.write(Data("user_pref(\"network.proxy.type\", 1);\n".utf8), to: target.appendingPathComponent("prefs.js"))
        var profile = profile(mode: .existing)
        profile.webForwards?.browserProfilePath = target.path
        let service = BrowserBootstrap(root: root, discover: { [descriptor()] }, isRunning: { _ in false })
        #expect(throws: BrowserBootstrapError.self) { try service.setupExisting(profile: profile, consent: true) }
        try BrowserPrivateFiles.write(Data("".utf8), to: target.appendingPathComponent("prefs.js"))
        let running = BrowserBootstrap(root: root, discover: { [descriptor()] }, isRunning: { _ in true })
        #expect(throws: BrowserBootstrapError.self) { try running.setupExisting(profile: profile, consent: true) }
        try service.setupExisting(profile: profile, consent: true)
        profile.id = UUID()
        #expect(throws: BrowserBootstrapError.self) { try service.setupExisting(profile: profile, consent: true) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BROWSER_E2E_PORT"] != nil))
    func realBrowserRouting() async throws {
        let environment = ProcessInfo.processInfo.environment
        let socksPort = try #require(Int(environment["BROWSER_E2E_PORT"] ?? ""))
        let httpPort = try #require(Int(environment["BROWSER_E2E_HTTP_PORT"] ?? ""))
        let root = try #require(environment["BROWSER_E2E_ROOT"])
        let installed = BrowserDescriptor.installed()
        for choice in [ManagedBrowserChoice.chrome, .zen] {
            let descriptor = try #require(installed.first { $0.choice == choice })
            for mode in (choice == .chrome ? [BrowserMode.separate] : [.separate, .existing]) {
                let directory = URL(fileURLWithPath: root).appendingPathComponent("\(choice.rawValue)-\(mode.rawValue)")
                try BrowserPrivateFiles.directory(directory)
                var profile = profile(mode: mode)
                profile.webForwards?.browser = choice
                profile.webForwards?.socksPort = socksPort
                profile.webForwards?.proxySuffixes = [".fixture.invalid", ".localtest.me"]
                profile.webForwards?.browserProfilePath = directory.path
                let routing = try BrowserRouting(profile: profile, descriptor: descriptor, mode: mode, directory: directory)
                if mode == .existing {
                    try BrowserPrivateFiles.write(Data("user_pref(\"browser.example.keep\", true);\n".utf8), to: directory.appendingPathComponent("prefs.js"))
                    try FirefoxProxySetup(root: URL(fileURLWithPath: root)).install(routing)
                } else if descriptor.family == .firefox {
                    try BrowserPrivateFiles.write(Data(try ProxyPreference.render(routing.firefoxPreferences).utf8), to: directory.appendingPathComponent("user.js"))
                }
                let urls = ["http://private.fixture.invalid:\(httpPort)/\(choice.rawValue)-\(mode.rawValue)-internal",
                            "http://127.0.0.1:\(httpPort)/\(choice.rawValue)-\(mode.rawValue)-direct"]
                for (index, url) in urls.enumerated() {
                    let process = Process()
                    process.executableURL = descriptor.executableURL
                    let base = try routing.arguments(family: descriptor.family).filter { $0 != "about:blank" && $0 != "--new-window" }
                    let screenshot = directory.appendingPathComponent("result-\(index).png").path
                    process.arguments = base + (descriptor.family == .chromium
                        ? ["--headless", "--screenshot=\(screenshot)", "--timeout=10000", url]
                        : ["--headless", "--screenshot", screenshot, url])
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    try process.run()
                    let deadline = ContinuousClock.now.advanced(by: .seconds(25))
                    while process.isRunning && ContinuousClock.now < deadline {
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    if process.isRunning { process.terminate() }
                    #expect(FileManager.default.fileExists(atPath: screenshot))
                }
                if mode == .existing {
                    try FirefoxProxySetup(root: URL(fileURLWithPath: root)).restore(routing)
                    #expect(try String(contentsOf: directory.appendingPathComponent("prefs.js"), encoding: .utf8).contains("browser.example.keep"))
                }
            }
        }
        _ = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(httpPort)/stop-socks")!)
        for choice in [ManagedBrowserChoice.chrome, .zen] {
            let descriptor = try #require(installed.first { $0.choice == choice })
            for mode in (choice == .chrome ? [BrowserMode.separate] : [.separate, .existing]) {
                let directory = URL(fileURLWithPath: root).appendingPathComponent("\(choice.rawValue)-\(mode.rawValue)")
                var profile = profile(mode: mode)
                profile.webForwards?.socksPort = socksPort
                profile.webForwards?.proxySuffixes = [".fixture.invalid", ".localtest.me"]
                let routing = try BrowserRouting(profile: profile, descriptor: descriptor, mode: mode, directory: directory)
                if descriptor.family == .firefox {
                    try BrowserPrivateFiles.write(Data(try ProxyPreference.render(routing.firefoxPreferences).utf8), to: directory.appendingPathComponent("user.js"))
                }
                for (index, hostname) in ["outage.localtest.me", "127.0.0.1"].enumerated() {
                    let suffix = index == 0 ? "internal" : "direct"
                    let process = Process()
                    process.executableURL = descriptor.executableURL
                    let base = try routing.arguments(family: descriptor.family).filter { $0 != "about:blank" && $0 != "--new-window" }
                    let screenshot = directory.appendingPathComponent("outage-\(index).png").path
                    let url = "http://\(hostname):\(httpPort)/\(choice.rawValue)-\(mode.rawValue)-outage-\(suffix)"
                    process.arguments = base + (descriptor.family == .chromium
                        ? ["--headless", "--screenshot=\(screenshot)", "--timeout=10000", url]
                        : ["--headless", "--screenshot", screenshot, url])
                    process.standardOutput = FileHandle.nullDevice
                    process.standardError = FileHandle.nullDevice
                    try process.run()
                    let deadline = ContinuousClock.now.advanced(by: .seconds(25))
                    while process.isRunning && ContinuousClock.now < deadline {
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    if process.isRunning { process.terminate() }
                    if index == 1 { #expect(FileManager.default.fileExists(atPath: screenshot)) }
                }
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BROWSER_NATIVE_E2E"] == "1"))
    func realNativeOpenAndReuse() async throws {
        let root = try temporary()
        let service = BrowserBootstrap(root: root)
        for choice in [ManagedBrowserChoice.chrome, .zen] {
            let descriptor = try #require(BrowserDescriptor.installed().first { $0.choice == choice })
            let originalIDs = Set(NSRunningApplication.runningApplications(withBundleIdentifier: descriptor.bundleID).map(\.processIdentifier))
            var profile = profile()
            profile.webForwards?.browser = choice
            try await service.open(profile: profile)
            let recordURL = root.appendingPathComponent("Instances/\(profile.id.uuidString)-\(choice.rawValue)-separate.json")
            let record = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any])
            let pid = try #require((record["pid"] as? NSNumber)?.int32Value)
            try #require(!originalIDs.contains(pid))
            let application = try #require(NSRunningApplication(processIdentifier: pid))
            try await service.open(profile: profile)
            let repeated = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any])
            #expect((repeated["pid"] as? NSNumber)?.int32Value == pid)
            let currentIDs = Set(NSRunningApplication.runningApplications(withBundleIdentifier: descriptor.bundleID).map(\.processIdentifier))
            #expect(originalIDs.isSubset(of: currentIDs))
            try #require(application.terminate())
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !application.isTerminated && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(100)) }
            #expect(application.isTerminated)
        }
    }

    @Test func explicitUpdateKeepsOriginalRestoreBaseline() throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("ordinary")
        try BrowserPrivateFiles.directory(target)
        let prefsURL = target.appendingPathComponent("prefs.js")
        try BrowserPrivateFiles.write(Data("user_pref(\"network.proxy.type\", 0);\n".utf8), to: prefsURL)
        let setup = FirefoxProxySetup(root: root)
        var profile = profile(mode: .existing)
        let original = try BrowserRouting(profile: profile, descriptor: descriptor(), mode: .existing, directory: target)
        try setup.install(original)
        profile.webForwards?.socksPort = 1081
        let next = try BrowserRouting(profile: profile, descriptor: descriptor(), mode: .existing, directory: target)
        try setup.inspectUpdate(next)
        try setup.verify(original)
        try setup.update(next)
        try setup.verify(next)
        #expect(throws: BrowserBootstrapError.self) { try setup.verify(original) }
        try setup.restore(next)
        #expect(try ProxyPreference.parse(String(contentsOf: prefsURL, encoding: .utf8)) == ["network.proxy.type": .integer(0)])
    }

    @Test func refusesPreferenceSymlinksAndExtensionChanges() throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("ordinary")
        try BrowserPrivateFiles.directory(target)
        let prefsURL = target.appendingPathComponent("prefs.js")
        let outside = root.appendingPathComponent("outside.js")
        try BrowserPrivateFiles.write(Data("".utf8), to: outside)
        try FileManager.default.createSymbolicLink(at: prefsURL, withDestinationURL: outside)
        let setup = FirefoxProxySetup(root: root)
        let routing = try BrowserRouting(profile: profile(mode: .existing), descriptor: descriptor(), mode: .existing, directory: target)
        #expect(throws: BrowserBootstrapError.self) { try setup.install(routing) }
        try FileManager.default.removeItem(at: prefsURL)
        try BrowserPrivateFiles.write(Data("".utf8), to: prefsURL)
        try setup.install(routing)
        let extensionMetadata = Data("{\"addons\":[{\"userPermissions\":{\"permissions\":[\"proxy\"]}}]}".utf8)
        try BrowserPrivateFiles.write(extensionMetadata, to: target.appendingPathComponent("extensions.json"))
        #expect(throws: BrowserBootstrapError.self) { try setup.restore(routing) }
        #expect(try ProxyPreference.parse(String(contentsOf: prefsURL, encoding: .utf8))["network.proxy.type"] == .integer(2))
    }

    @Test func unrecordedRunningInstanceBlocksChangedRouting() throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        var profile = profile()
        let directory = root.appendingPathComponent(profile.id.uuidString + "/zen")
        let original = try BrowserRouting(profile: profile, descriptor: descriptor(), mode: .separate, directory: directory)
        try BrowserPrivateFiles.write(try JSONEncoder().encode(original), to: directory.appendingPathComponent("ssm-connect-routing.json"))
        let service = BrowserBootstrap(root: root, discover: { [descriptor()] }, isRunning: { _ in true })
        profile.webForwards?.socksPort = 1081
        #expect(throws: BrowserBootstrapError.self) { try service.preflight(profile: profile) }
        #expect(try JSONDecoder().decode(BrowserRouting.self,
            from: Data(contentsOf: directory.appendingPathComponent("ssm-connect-routing.json"))) == original)
    }

    @Test func restoreUsesInstalledRoutingAfterSaveAndBrowserUpgrade() throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("ordinary")
        try BrowserPrivateFiles.directory(directory)
        let prefs = directory.appendingPathComponent("prefs.js")
        try BrowserPrivateFiles.write(Data("user_pref(\"network.proxy.type\", 0);\n".utf8), to: prefs)
        var profile = profile(mode: .existing)
        profile.webForwards?.browserProfilePath = directory.path
        var product = descriptor()
        let service = BrowserBootstrap(root: root, discover: { [product] }, isRunning: { _ in false })
        try service.setupExisting(profile: profile, consent: true)
        profile.webForwards?.socksPort = 1081
        profile.webForwards?.proxySuffixes.append(".another.example.com")
        product = .init(choice: product.choice, bundleID: product.bundleID,
            applicationURL: product.applicationURL, executableURL: product.executableURL, version: "999.0")
        #expect(!product.supports(.existing))
        #expect(throws: BrowserBootstrapError.self) { try service.preflight(profile: profile) }
        try service.restore(profile: profile)
        #expect(try ProxyPreference.parse(String(contentsOf: prefs, encoding: .utf8)) == ["network.proxy.type": .integer(0)])
    }

    @Test func unownedLockedProfileRefusesWrites() async throws {
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let profile = profile()
        var launchCount = 0
        let service = BrowserBootstrap(root: root, discover: { [descriptor()] }, isRunning: { _ in false },
            requireUnlockedProfile: { _, _ in throw BrowserBootstrapError.closeBrowser },
            launch: { _, _ in launchCount += 1 })
        await #expect(throws: BrowserBootstrapError.self) { try await service.open(profile: profile) }
        #expect(launchCount == 0)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(profile.id.uuidString).path))
    }

    @Test func interruptedProxyWritesRecoverWithoutOverwritingUserChanges() throws {
        for operation in ["install", "update", "restore"] {
            for stage in FirefoxProxySetup.WriteStage.allCases {
                let root = try temporary()
                defer { try? FileManager.default.removeItem(at: root) }
                let directory = root.appendingPathComponent("ordinary")
                try BrowserPrivateFiles.directory(directory)
                let prefs = directory.appendingPathComponent("prefs.js")
                try BrowserPrivateFiles.write(Data("user_pref(\"network.proxy.type\", 0);\nuser_pref(\"browser.keep\", true);\n".utf8), to: prefs)
                var profile = profile(mode: .existing)
                let original = try BrowserRouting(profile: profile, descriptor: descriptor(), mode: .existing, directory: directory)
                let setup = FirefoxProxySetup(root: root)
                if operation != "install" { try setup.install(original) }
                profile.webForwards?.socksPort = 1081
                let next = try BrowserRouting(profile: profile, descriptor: descriptor(), mode: .existing, directory: directory)
                let faulty = FirefoxProxySetup(root: root, beforeWrite: { current in
                    if current == stage { throw CocoaError(.fileWriteUnknown) }
                })
                #expect(throws: (any Error).self) {
                    if operation == "install" { try faulty.install(original) }
                    else if operation == "update" { try faulty.update(next) }
                    else { try faulty.restore(original) }
                }
                if stage == .transaction && operation == "install" { continue }
                try setup.restore(original)
                #expect(try ProxyPreference.parse(String(contentsOf: prefs, encoding: .utf8)) == ["network.proxy.type": .integer(0)])
                #expect(try String(contentsOf: prefs, encoding: .utf8).contains("browser.keep"))
            }
        }
        let root = try temporary()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("ordinary")
        try BrowserPrivateFiles.directory(directory)
        let prefs = directory.appendingPathComponent("prefs.js")
        try BrowserPrivateFiles.write(Data("user_pref(\"network.proxy.type\", 0);\n".utf8), to: prefs)
        let routing = try BrowserRouting(profile: profile(mode: .existing), descriptor: descriptor(), mode: .existing, directory: directory)
        let faulty = FirefoxProxySetup(root: root, beforeWrite: { if $0 == .preferences { throw CocoaError(.fileWriteUnknown) } })
        #expect(throws: (any Error).self) { try faulty.install(routing) }
        try BrowserPrivateFiles.write(Data("user_pref(\"network.proxy.type\", 1);\n".utf8), to: prefs)
        #expect(throws: BrowserBootstrapError.self) { try FirefoxProxySetup(root: root).restore(routing) }
        #expect(try ProxyPreference.parse(String(contentsOf: prefs, encoding: .utf8))["network.proxy.type"] == .integer(1))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BROWSER_PREVIEW_E2E"] == "1"))
    func previewMenuOpenFromOff() async throws {
        try #require(AXIsProcessTrusted())
        let previewID = "pro.vhco.ssm-connect.about-preview"
        try #require(NSRunningApplication.runningApplications(withBundleIdentifier: previewID).isEmpty)
        let live = try #require(UserDefaults(suiteName: "pro.vhco.ssm-connect"))
        let saved = try #require(live.data(forKey: "ssmconnect.profiles.v1"))
        let profiles = try JSONDecoder().decode([ConnectionProfile].self, from: saved)
        var profile = try #require(profiles.first { $0.webForwards?.enabled == true })
        profile.id = UUID()
        profile.name = "Browser Preview"
        profile.localPort = 10443
        profile.webForwards?.socksPort = 11180
        profile.webForwards?.localForwards = []
        profile.webForwards?.browser = .chrome
        profile.webForwards?.browserMode = .separate
        profile.webForwards?.browserProfilePath = nil
        try #require(SystemPortProbe().occupant(of: 11180) == nil)
        let defaults = try #require(UserDefaults(suiteName: previewID))
        let store = ProfileStore(defaults: defaults)
        if let existing = store.profiles.first {
            try #require(store.profiles.count == 1 && existing.name == "Browser Preview"
                && existing.webForwards?.socksPort == 11180 && existing.webForwards?.browserMode == .separate)
            profile.id = existing.id
        }
        var settings = AppSettings.default
        settings.autoConnect = false
        store.settings = settings
        if store.profiles.isEmpty { store.addProfile(profile) }
        else { store.updateProfile(profile) }
        defaults.synchronize()
        let applicationURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .deletingLastPathComponent()
            .appendingPathComponent(".build/AboutPreview/Build/Products/Debug/SSMConnect.app")
        let application = try await NSWorkspace.shared.openApplication(at: applicationURL, configuration: .init())
        try #require(application.bundleIdentifier == previewID)
        let element = AXUIElementCreateApplication(application.processIdentifier)
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
            if (name == nil || title == name || description == name) && (role == nil || role == elementRole) { return element }
            for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                if let match = find(child, name: name, role: role, depth: depth + 1) { return match }
            }
            return nil
        }
        try await Task.sleep(for: .seconds(1))
        let item = try #require(find(element, role: kAXMenuBarItemRole))
        try #require(AXUIElementPerformAction(item, kAXPressAction as CFString) == .success)
        try await Task.sleep(for: .milliseconds(200))
        try #require(find(element, name: "Web Forwards: Off") != nil)
        let button = try #require(find(element, name: "Open Browser"))
        try #require(AXUIElementPerformAction(button, kAXPressAction as CFString) == .success)
        let record = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(previewID + "/Browsers/Instances/\(profile.id.uuidString)-chrome-separate.json")
        let deadline = ContinuousClock.now.advanced(by: .seconds(90))
        while (!FileManager.default.fileExists(atPath: record.path) || SystemPortProbe().occupant(of: 11180) == nil)
            && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        try #require(FileManager.default.fileExists(atPath: record.path))
        let occupant = try #require(SystemPortProbe().occupant(of: 11180))
        #expect(occupant.processName?.contains("ssh") == true)
        #expect(SystemPortProbe().occupant(of: 10443) == nil)
        print("Preview Open Browser passed: native menu -> SSH SOCKS readiness -> recorded Chrome launch; no DCV listener.")
    }
}