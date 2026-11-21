import AppKit
import CFNetwork
import CryptoKit
import Darwin
import Foundation


enum BrowserFamily { case chromium, firefox }

struct BrowserDescriptor: Equatable {
    let choice: ManagedBrowserChoice
    let bundleID: String
    let applicationURL: URL
    let executableURL: URL
    let version: String

    var family: BrowserFamily { choice == .chrome || choice == .edge ? .chromium : .firefox }
    func supports(_ mode: BrowserMode) -> Bool {
        switch choice {
        case .chrome: mode == .separate && version == "156.0.8078.12"
        case .zen: version == "1.23.1b"
        default: false
        }
    }

    @MainActor static func installed() -> [BrowserDescriptor] {
        let products: [(ManagedBrowserChoice, String)] = [(.chrome, "com.google.Chrome"),
            (.edge, "com.microsoft.edgemac"), (.firefox, "org.mozilla.firefox"), (.zen, "app.zen-browser.zen")]
        return products.compactMap { choice, bundleID in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
                  let bundle = Bundle(url: url), let executable = bundle.executableURL,
                  let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
                  FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
            return .init(choice: choice, bundleID: bundleID, applicationURL: url,
                         executableURL: executable, version: version)
        }
    }
}

struct BrowserRouting: Equatable, Codable {
    let workstationID: UUID
    let choice: ManagedBrowserChoice
    let mode: BrowserMode
    let profilePath: String
    let port: Int
    let suffixes: [String]

    init(profile: ConnectionProfile, descriptor: BrowserDescriptor, mode: BrowserMode, directory: URL) throws {
        guard let configuration = profile.webForwards, configuration.enabled,
              let port = configuration.socksPort else { throw BrowserBootstrapError.chooseMode }
        if let error = ProfileEditorValidation.webForwardsError(configuration) {
            throw WebForwardsError.invalidConfiguration(error)
        }
        workstationID = profile.id
        choice = descriptor.choice
        self.mode = mode
        profilePath = directory.standardizedFileURL.path
        self.port = port
        suffixes = Array(Set(configuration.proxySuffixes.map { $0.lowercased() })).sorted()
    }

    var pac: String {
        get throws { try WebForwardsPAC.contents(configuration: .init(socksPort: port, proxySuffixes: suffixes)) }
    }
    var pacDataURL: String {
        get throws { "data:application/x-ns-proxy-autoconfig;base64," + Data(try pac.utf8).base64EncodedString() }
    }
    var fingerprint: String {
        get throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            return SHA256.hash(data: try encoder.encode(self)).map { String(format: "%02x", $0) }.joined()
        }
    }
    func arguments(family: BrowserFamily) throws -> [String] {
        switch family {
        case .chromium:
            ["--user-data-dir=\(profilePath)", "--proxy-pac-url=\(try pacDataURL)",
             "--no-first-run", "--no-default-browser-check", "about:blank"]
        case .firefox:
            ["--new-instance", "--profile", profilePath, "--new-window", "about:blank"]
        }
    }
    var firefoxPreferences: [String: ProxyPreference] {
        get throws {
            ["network.proxy.type": .integer(2), "network.proxy.autoconfig_url": .string(try pacDataURL),
             "network.proxy.socks_remote_dns": .bool(true), "network.proxy.socks5_remote_dns": .bool(true),
             "network.proxy.failover_direct": .bool(false), "network.dns.disablePrefetch": .bool(true)]
        }
    }
}



@MainActor final class BrowserBootstrap: BrowserOpening {
    private struct Instance: Codable {
        let routing: BrowserRouting
        let pid: Int32
        let launchDate: Date
    }
    private let root: URL
    private let discover: @MainActor () -> [BrowserDescriptor]
    private let isRunning: @MainActor (BrowserDescriptor) -> Bool
    private let requireUnlockedProfile: @MainActor (BrowserDescriptor, URL) throws -> Void
    private let launch: (@MainActor (BrowserDescriptor, [String]) async throws -> Void)?

    init(root: URL = BrowserPrivateFiles.root,
         discover: @escaping @MainActor () -> [BrowserDescriptor] = { BrowserDescriptor.installed() },
         isRunning: @escaping @MainActor (BrowserDescriptor) -> Bool = {
             !NSRunningApplication.runningApplications(withBundleIdentifier: $0.bundleID).isEmpty
         },
         requireUnlockedProfile: @escaping @MainActor (BrowserDescriptor, URL) throws -> Void = BrowserProfileLock.requireUnlocked,
         launch: (@MainActor (BrowserDescriptor, [String]) async throws -> Void)? = nil) {
        self.root = root
        self.discover = discover
        self.isRunning = isRunning
        self.requireUnlockedProfile = requireUnlockedProfile
        self.launch = launch
    }

    func resolve(profile: ConnectionProfile, requireVerifiedSupport: Bool = true) throws -> (BrowserDescriptor, BrowserRouting) {
        guard let configuration = profile.webForwards, let mode = configuration.browserMode else {
            throw BrowserBootstrapError.chooseMode
        }
        let available = discover().filter { !requireVerifiedSupport || $0.supports(mode) }
        let preferred = configuration.browser ?? .automatic
        let defaultID = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)
            .flatMap { Bundle(url: $0)?.bundleIdentifier }
        guard let descriptor = preferred == .automatic
            ? available.first(where: { $0.bundleID == defaultID }) ?? available.first
            : available.first(where: { $0.choice == preferred }) else { throw BrowserBootstrapError.unavailable }
        let directory: URL
        if mode == .existing {
            guard let path = configuration.browserProfilePath, path.hasPrefix("/"),
                  FileManager.default.fileExists(atPath: path + "/prefs.js") else {
                throw BrowserBootstrapError.chooseProfile
            }
            directory = URL(fileURLWithPath: path, isDirectory: true).resolvingSymlinksInPath()
        } else {
            directory = root.appendingPathComponent(profile.id.uuidString, isDirectory: true)
                .appendingPathComponent(descriptor.choice.rawValue, isDirectory: true)
        }
        return (descriptor, try .init(profile: profile, descriptor: descriptor, mode: mode, directory: directory))
    }

    func preflight(profile: ConnectionProfile) throws {
        let (descriptor, routing) = try resolve(profile: profile)
        try checkPolicy(descriptor)
        if routing.mode == .existing {
            let setup = FirefoxProxySetup(root: root)
            if try setup.isInstalled(routing) {
                if launch == nil && isRunning(descriptor) && ownedApplication(descriptor, routing) == nil {
                    throw BrowserBootstrapError.closeBrowser
                }
                return
            }
            if isRunning(descriptor) { throw BrowserBootstrapError.closeBrowser }
            try setup.inspect(routing)
        } else {
            if ownedApplication(descriptor, routing) == nil {
                try requireUnlockedProfile(descriptor, URL(fileURLWithPath: routing.profilePath))
            }
            let record = URL(fileURLWithPath: routing.profilePath).appendingPathComponent("ssm-connect-routing.json")
            if FileManager.default.fileExists(atPath: record.path) {
                let previous = try JSONDecoder().decode(BrowserRouting.self, from: Data(contentsOf: record))
                let previousIsRunning = ownedApplication(descriptor, previous) != nil || isRunning(descriptor)
                if previous != routing && previousIsRunning { throw BrowserBootstrapError.pendingChanges }
            } else if FileManager.default.fileExists(atPath: routing.profilePath) {
                throw BrowserBootstrapError.conflict
            }
        }
    }

    func open(profile: ConnectionProfile) async throws {
        try preflight(profile: profile)
        let (descriptor, routing) = try resolve(profile: profile)
        let directory = URL(fileURLWithPath: routing.profilePath, isDirectory: true)
        if let application = ownedApplication(descriptor, routing) {
            application.activate()
            return
        }
        if routing.mode == .existing {
            try FirefoxProxySetup(root: root).verify(routing)
        } else {
            try BrowserPrivateFiles.directory(directory)
            if descriptor.family == .firefox {
                try BrowserPrivateFiles.write(Data(try ProxyPreference.render(routing.firefoxPreferences).utf8),
                                              to: directory.appendingPathComponent("user.js"))
            }
            try BrowserPrivateFiles.write(try JSONEncoder().encode(routing),
                                          to: directory.appendingPathComponent("ssm-connect-routing.json"))
        }
        do {
            let arguments = try routing.arguments(family: descriptor.family)
            if let launch { try await launch(descriptor, arguments) }
            else {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.createsNewApplicationInstance = true
                configuration.arguments = arguments
                let previousPIDs = Set(NSRunningApplication.runningApplications(withBundleIdentifier: descriptor.bundleID)
                    .map(\.processIdentifier))
                let requestedAt = Date()
                let application = try await NSWorkspace.shared.openApplication(at: descriptor.applicationURL, configuration: configuration)
                try await Task.sleep(for: .milliseconds(500))
                guard !application.isTerminated, application.bundleIdentifier == descriptor.bundleID,
                      !previousPIDs.contains(application.processIdentifier),
                      let launchDate = application.launchDate, launchDate >= requestedAt else {
                    throw BrowserBootstrapError.launchFailed
                }
                try BrowserPrivateFiles.write(try JSONEncoder().encode(Instance(routing: routing,
                    pid: application.processIdentifier, launchDate: launchDate)), to: instanceURL(routing))
            }
        }
        catch { throw BrowserBootstrapError.launchFailed }
    }

    func needsSetup(profile: ConnectionProfile) throws -> Bool {
        let (_, routing) = try resolve(profile: profile)
        guard routing.mode == .existing else { return false }
        return try !FirefoxProxySetup(root: root).isInstalled(routing)
    }

    private func instanceURL(_ routing: BrowserRouting) -> URL {
        root.appendingPathComponent("Instances", isDirectory: true)
            .appendingPathComponent(routing.workstationID.uuidString + "-" + routing.choice.rawValue + "-" + routing.mode.rawValue + ".json")
    }

    private func ownedApplication(_ descriptor: BrowserDescriptor, _ routing: BrowserRouting) -> NSRunningApplication? {
        guard let data = try? Data(contentsOf: instanceURL(routing)),
              let record = try? JSONDecoder().decode(Instance.self, from: data), record.routing == routing,
              let application = NSRunningApplication(processIdentifier: record.pid), !application.isTerminated,
              application.bundleIdentifier == descriptor.bundleID, application.launchDate == record.launchDate else { return nil }
        return application
    }

    func setupExisting(profile: ConnectionProfile, consent: Bool) throws {
        guard consent else { return }
        let (descriptor, routing) = try resolve(profile: profile)
        guard routing.mode == .existing else { throw BrowserBootstrapError.chooseMode }
        try checkPolicy(descriptor)
        guard !isRunning(descriptor) else { throw BrowserBootstrapError.closeBrowser }
        try FirefoxProxySetup(root: root).install(routing)
    }

    func preflightApply(profile: ConnectionProfile) throws {
        let (descriptor, routing) = try resolve(profile: profile)
        try checkPolicy(descriptor)
        if routing.mode == .existing {
            guard !isRunning(descriptor) else { throw BrowserBootstrapError.closeBrowser }
            try FirefoxProxySetup(root: root).inspectUpdate(routing)
        }
        else { try preflight(profile: profile) }
    }

    func applyExisting(profile: ConnectionProfile) throws {
        try preflightApply(profile: profile)
        let (_, routing) = try resolve(profile: profile)
        if routing.mode == .existing { try FirefoxProxySetup(root: root).update(routing) }
    }

    func restore(profile: ConnectionProfile) throws {
        let (descriptor, routing) = try resolve(profile: profile, requireVerifiedSupport: false)
        try checkPolicy(descriptor)
        guard !isRunning(descriptor) else { throw BrowserBootstrapError.closeBrowser }
        try FirefoxProxySetup(root: root).restore(routing)
    }

    private func checkPolicy(_ descriptor: BrowserDescriptor) throws {
        let keys = ["Proxy", "ProxyMode", "ProxySettings", "ProxyPacUrl", "ProxyServer", "ExtensionSettings"]
        if keys.contains(where: { CFPreferencesAppValueIsForced($0 as CFString, descriptor.bundleID as CFString) }) {
            throw BrowserBootstrapError.conflict
        }
        if FileManager.default.fileExists(atPath: "/Library/Managed Preferences/\(descriptor.bundleID).plist")
            || FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Library/Managed Preferences/\(descriptor.bundleID).plist")
            || FileManager.default.fileExists(atPath: descriptor.applicationURL.path + "/Contents/Resources/distribution/policies.json") {
            throw BrowserBootstrapError.conflict
        }
    }
}

enum BrowserProfileLock {
    static func requireUnlocked(_ descriptor: BrowserDescriptor, _ directory: URL) throws {
        if descriptor.family == .chromium {
            let socket = directory.appendingPathComponent("SingletonSocket").resolvingSymlinksInPath()
            if FileManager.default.fileExists(atPath: socket.path) { throw BrowserBootstrapError.closeBrowser }
            let lock = directory.appendingPathComponent("SingletonLock")
            if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: lock.path),
               let pid = Int32(target.split(separator: "-").last ?? ""), kill(pid, 0) == 0 {
                throw BrowserBootstrapError.closeBrowser
            }
            return
        }
        let descriptor = open(directory.appendingPathComponent(".parentlock").path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno != ENOENT { throw BrowserBootstrapError.closeBrowser }
            return
        }
        defer { close(descriptor) }
        var lock = flock(l_start: 0, l_len: 0, l_pid: 0, l_type: Int16(F_WRLCK), l_whence: Int16(SEEK_SET))
        guard fcntl(descriptor, F_GETLK, &lock) == 0, lock.l_type == Int16(F_UNLCK) else {
            throw BrowserBootstrapError.closeBrowser
        }
    }
}