import Darwin
import Foundation
import Testing
@testable import SSMConnectKit

/// The documented macOS flows on SSM Connect's AWS client, against AWS (T36). Opt-in with
/// SSM_LIVE_FLOWS=1 on a Mac with SSM Connect's profiles configured, through
/// `scripts/live-macos-flows.sh`. It reuses or silently refreshes the SSO session (no device
/// code), refuses to start a stopped workstation, never opens DCV Viewer, a browser or VS Code,
/// and binds only free local ports, so a running SSM Connect is undisturbed. Secrets, tokens and
/// account values are never printed.
@MainActor
@Suite("Live client flows", .serialized, .enabled(if: ProcessInfo.processInfo.environment["SSM_LIVE_FLOWS"] == "1"))
struct LiveClientFlowsTests {
    /// The installed app's profiles; SSM_LIVE_PROFILE picks one by name.
    static func profiles() throws -> [ConnectionProfile] {
        let defaults = try #require(UserDefaults(suiteName: "pro.vhco.ssm-connect"))
        let data = try #require(defaults.data(forKey: "ssmconnect.profiles.v1"))
        let all = try JSONDecoder().decode([ConnectionProfile].self, from: data)
        guard let name = ProcessInfo.processInfo.environment["SSM_LIVE_PROFILE"] else { return all }
        return all.filter { $0.name == name }
    }

    /// The Session Manager plugin of the freshly built app (SSM_LIVE_PLUGIN).
    static var plugin: String {
        ProcessInfo.processInfo.environment["SSM_LIVE_PLUGIN"] ?? "/Applications/SSMConnect.app/Contents/Helpers/session-manager-plugin"
    }

    /// A free local TCP port.
    static func freePort() -> Int {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, length) } }
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) } }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    static func accepts(_ port: Int) -> Bool {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        } == 0
    }

    /// The first profile, among those `matching`, whose workstation is already running; silent
    /// sign-in only. A stopped workstation is never started.
    static func runningProfile(matching include: (ConnectionProfile) -> Bool = { _ in true }) async throws -> ConnectionProfile {
        var states: [String] = []
        for profile in try profiles() where include(profile) {
            let credentials = try await ClientAuthProvider.macOS().refreshIfNeeded(profile: profile)
            do {
                let instance = try await ClientEC2Service().resolveInstance(tagKey: profile.instanceTagKey, tagValue: profile.instanceTagValue,
                                                                            region: profile.resourceRegion, credentials: credentials)
                if instance.state == .running { return profile }
                states.append("\(profile.name): \(instance.state.rawValue)")
            } catch EC2Error.noMatchingInstance {
                states.append("\(profile.name): no workstation")
            }
        }
        throw LiveFlowsError.noRunningWorkstation(states.joined(separator: "; "))
    }

    enum LiveFlowsError: Error, CustomStringConvertible {
        case noRunningWorkstation(String)
        var description: String {
            switch self {
            case let .noRunningWorkstation(states): "No profile's workstation is running (\(states)); start one to run the live flows."
            }
        }
    }

    /// Reuses or silently refreshes the SSO session; with SSM_LIVE_INTERACTIVE=1 it signs in with
    /// a device code whose URL it writes to SSM_LIVE_URL_FILE for another device to approve,
    /// instead of opening a browser on this Mac. The token lands in the AWS CLI cache that the flows below reuse.
    @Test("Sign in through IAM Identity Center on the client")
    func signIn() async throws {
        let profile = try #require(try Self.profiles().first)
        // swift test holds a test's output until it ends, so the URL goes to a user-only file.
        let urlFile = ProcessInfo.processInfo.environment["SSM_LIVE_URL_FILE"] ?? NSTemporaryDirectory() + "ssm-live-signin-url"
        let provider = ClientAuthProvider(openURL: { url in
            try? BrowserPrivateFiles.write(Data(url.absoluteString.utf8), to: URL(fileURLWithPath: urlFile), createParent: false)
        })
        let interactive = ProcessInfo.processInfo.environment["SSM_LIVE_INTERACTIVE"] == "1"
        let credentials = interactive ? try await provider.authenticate(profile: profile)
                                      : try await provider.refreshIfNeeded(profile: profile)
        #expect(!credentials.accessKeyId.isEmpty && credentials.expiration > Date())
        print("Live sign-in: role credentials valid until \(credentials.expiration)")
    }

    @Test("Connect a desktop: sign-in, workstation, SSM, session, plugin tunnel, DCV credentials and readiness, then disconnect")
    func desktop() async throws {
        var profile = try await Self.runningProfile()
        profile.localPort = Self.freePort()
        let dcv = MockDCVLauncher()
        let plugin = Self.plugin
        let machine = ConnectionStateMachine(
            authProvider: ClientAuthProvider.macOS(), ec2: ClientEC2Service(), ssm: ClientSSMService(),
            tunnel: BundledPluginTunnel(pluginPath: { plugin }), secrets: ClientSecretsService(), dcv: dcv,
            readiness: HTTPSReadinessProbe(), tunnelListener: TCPListenerProbe(), instanceIds: MockInstanceIdStore(),
            clipboard: ClipboardManager(pasteboard: FakePasteboard(), autoClearAfter: nil), notifier: MockNotifier(),
            profile: profile)
        machine.connect()
        await machine.awaitInFlightTask()
        #expect(machine.state == .connected, "\(machine.errorMessage ?? "no error")")
        let file = try #require(dcv.lastConnectionFile)
        #expect(file.port == profile.localPort)
        #expect(file.password != nil || file.authToken != nil)
        #expect(Self.accepts(profile.localPort))
        print("Live desktop: connected through local port \(profile.localPort), DCV credentials \(file.password != nil ? "from Secrets Manager" : "from an identity token")")
        machine.disconnect()
        await machine.awaitInFlightTask()
        #expect(machine.state == .disconnected)
        try await Task.sleep(for: .seconds(2))
        #expect(!Self.accepts(profile.localPort))
    }

    @Test("Start web forwards: sign-in, key push, SSH over SSM with SOCKS and forwards, then stop")
    func webForwards() async throws {
        var profile = try await Self.runningProfile { $0.webForwards?.enabled == true }
        var forwards = try #require(profile.webForwards)
        forwards.socksPort = Self.freePort()
        forwards.localForwards = forwards.localForwards.map { var forward = $0; forward.localPort = Self.freePort(); return forward }
        profile.webForwards = forwards
        let plugin = Self.plugin
        let pacDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("ssm-live-pac-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: pacDirectory) }
        let web = WebForwardsStateMachine(profile: profile, auth: ClientAuthProvider.macOS(), ec2: ClientEC2Service(),
                                          ssm: ClientSSMService(), instanceConnect: ClientInstanceConnectService(),
                                          tunnel: SSHTunnel(pluginPath: { plugin }),
                                          writePAC: { configuration, id in
                                              let url = pacDirectory.appendingPathComponent("\(id.uuidString).pac")
                                              try BrowserPrivateFiles.write(Data(try WebForwardsPAC.contents(configuration: configuration).utf8), to: url)
                                              return url
                                          })
        web.connect()
        let deadline = ContinuousClock.now.advanced(by: .seconds(180))
        while web.state == .starting && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(250)) }
        #expect(web.state == .on, "\(web.errorMessage ?? "no error")")
        let socks = try #require(forwards.socksPort)
        #expect(Self.accepts(socks))
        for forward in forwards.localForwards { #expect(Self.accepts(forward.localPort)) }
        print("Live web forwards: SOCKS on \(socks) and \(forwards.localForwards.count) local forward(s) listening")
        web.stop()
        await web.awaitStopped()
        try await Task.sleep(for: .seconds(2))
        #expect(!Self.accepts(socks))
    }
}
