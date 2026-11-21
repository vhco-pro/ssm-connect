import Foundation
import Testing
@testable import SSMConnectDomain
@testable import SSMConnectWorkflow

/// The editor's SSH proxy on the shared layer (T49, AC-17): it refuses an expired lease, a lease
/// of another build and a lease whose owner is gone before any AWS call, and otherwise authorizes
/// the channel and runs the plugin.
@Suite("Editor proxy")
struct EditorProxyTests {
    final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        func record(_ name: String) { lock.withLock { names.append(name) } }
        var all: [String] { lock.withLock { names } }
    }
    struct Auth: AuthProviding {
        let calls: Calls
        func authenticate(profile: ConnectionProfile) async throws -> AWSCredentials { calls.record("authenticate"); return .stub }
        func refreshIfNeeded(profile: ConnectionProfile) async throws -> AWSCredentials { calls.record("refresh"); return .stub }
    }
    struct EC2: EC2Providing {
        let calls: Calls
        func resolveInstance(tagKey: String, tagValue: String, region: String, credentials: AWSCredentials) async throws -> EC2Instance {
            calls.record("resolve"); return EC2Instance(id: "i-0123456789abcdef0", state: .running, privateIpAddress: nil)
        }
        func startInstance(instanceId: String, region: String, credentials: AWSCredentials) async throws {}
        func stopInstance(instanceId: String, region: String, credentials: AWSCredentials) async throws {}
        func pollUntilRunning(instanceId: String, region: String, credentials: AWSCredentials, timeout: Duration,
                              interval: Duration) async throws -> EC2Instance { fatalError() }
    }
    struct SSM: SSMProviding {
        let calls: Calls
        func startSSHSession(instanceId: String, region: String, credentials: AWSCredentials) async throws -> SSMSessionResponse {
            calls.record("startSSHSession"); return SSMSessionResponse(sessionId: "s", streamUrl: "wss://x", tokenValue: "t")
        }
        func waitForSSMOnline(instanceId: String, region: String, credentials: AWSCredentials, timeout: Duration, interval: Duration) async throws {}
        func startSession(instanceId: String, region: String, credentials: AWSCredentials, localPort: Int, remotePort: Int) async throws -> SSMSessionResponse { fatalError() }
    }
    struct Push: InstanceConnectProviding {
        let calls: Calls
        func sendPublicKey(instanceId: String, user: String, publicKey: String, region: String, credentials: AWSCredentials) async throws {
            calls.record("pushKey")
        }
    }
    struct Owner: LeaseOwnerProbing {
        let alive: Bool
        func current() -> LeaseOwnerIdentity? { nil }
        func isActive(_ owner: LeaseOwnerIdentity) -> Bool { alive }
    }

    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static var plugin: String {
        #if os(Windows)
        (ProcessInfo.processInfo.environment["SystemRoot"] ?? "C:\\Windows") + "\\System32\\where.exe"
        #else
        "/bin/sh"
        #endif
    }

    /// A lease file and its key files in a fresh directory.
    static func lease(build: String? = "b1", expiresIn: TimeInterval = 3600) throws -> (path: String, lease: RemoteSSHLease) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("proxy-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let key = directory.appendingPathComponent("key")
        try Data("private".utf8).write(to: key)
        try Data("ssh-ed25519 test".utf8).write(to: directory.appendingPathComponent("key.pub"))
        let profile = ConnectionProfile(name: "Workstation", ssoStartUrl: "https://d-0123456789.awsapps.com/start", ssoRegion: "eu-west-1",
                                        accountId: "111122223333", roleName: "Admin", resourceRegion: "eu-central-1",
                                        instanceTagKey: "Name", instanceTagValue: "ws", localPort: 8443, remotePort: 8443)
        let lease = RemoteSSHLease(profile: profile, instanceID: "i-0123456789abcdef0", user: "ec2-user", keyPath: key.path,
                                   pluginPath: plugin, ownerPID: 4242, ownerLaunchDate: now, ownerBundleID: "helper",
                                   generation: UUID(), expiresAt: now.addingTimeInterval(expiresIn), ownerBuild: build)
        let path = directory.appendingPathComponent("lease.json")
        try JSONEncoder().encode(lease).write(to: path)
        return (path.path, lease)
    }

    static func proxy(_ calls: Calls, ownerAlive: Bool = true) -> EditorProxy {
        EditorProxy(owner: Owner(alive: ownerAlive), files: OwnerOnlyFiles(isOwnerOnly: { _, _ in true }, withExclusiveLock: { _, body in try body() }),
                    auth: Auth(calls: calls), ec2: EC2(calls: calls), ssm: SSM(calls: calls), instanceConnect: Push(calls: calls),
                    isRejectedAuthorization: { _ in false }, forceTerminate: { $0.terminate() }, build: "b1", now: { now })
    }

    @Test("An expired lease is refused before any AWS call and asks for recovery")
    func expired() throws {
        let calls = Calls()
        let (path, _) = try Self.lease(expiresIn: -60)
        #expect(throws: RemoteSSHError.invalidLease) { _ = try Self.proxy(calls).admit(configurationPath: path) }
        #expect(calls.all.isEmpty)
        let request = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("recovery-request.json")
        #expect(FileManager.default.fileExists(atPath: request.path))
    }

    @Test("A lease of another build, or written before builds were recorded, is refused before any AWS call",
          arguments: ["b0", nil] as [String?])
    func otherBuild(_ build: String?) throws {
        let calls = Calls()
        let (path, _) = try Self.lease(build: build)
        #expect(throws: RemoteSSHError.updated) { _ = try Self.proxy(calls).admit(configurationPath: path) }
        #expect(calls.all.isEmpty)
    }

    @Test("A lease whose owner is gone is refused before any AWS call")
    func ownerGone() throws {
        let calls = Calls()
        let (path, _) = try Self.lease()
        #expect(throws: RemoteSSHError.invalidLease) { _ = try Self.proxy(calls, ownerAlive: false).admit(configurationPath: path) }
        #expect(calls.all.isEmpty)
    }

    @Test("A valid lease is authorized through the owner's session and the plugin runs")
    func authorized() async throws {
        let calls = Calls()
        let (path, _) = try Self.lease()
        let status = try await Self.proxy(calls).run(configurationPath: path)
        #expect(calls.all == ["refresh", "resolve", "pushKey", "startSSHSession"])
        #expect(status != Int32.min)
    }

    @Test("The update refusal tells VS Code to restart SSM Connect")
    func messages() {
        #expect(EditorProxy.failureMessage(for: RemoteSSHError.updated, isRejectedAuthorization: { _ in false })
                == "SSM Connect was updated; restart it.\n")
    }
}
