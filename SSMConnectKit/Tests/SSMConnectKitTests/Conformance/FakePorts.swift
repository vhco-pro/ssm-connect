import Foundation
@testable import SSMConnectKit

/// Fakes for every injected port, driven entirely by the fixture's declared outcomes.
///
/// They hold no behavior of their own beyond honouring cancellation, so whatever a fixture proves
/// is a property of `ConnectionStateMachine` rather than of this file.

// MARK: - AWS-facing ports

struct FixtureAuthProvider: AuthProviding {
    let recorder: PortRecorder

    private func credentials() -> AWSCredentials {
        AWSCredentials(
            accessKeyId: "ASIASYNTHETICEXAMPLE",
            secretAccessKey: "synthetic-secret",
            sessionToken: "synthetic-session-token",
            expiration: Date(timeIntervalSince1970: 4_102_444_800) // 2100-01-01, never "expired"
        )
    }

    func authenticate(profile: ConnectionProfile) async throws -> AWSCredentials {
        try Task.checkCancellation()
        try recorder.invoke("AuthProvider", "authenticate", ["profileId": .string(profile.id.uuidString)])
        return credentials()
    }

    func refreshIfNeeded(profile: ConnectionProfile) async throws -> AWSCredentials {
        try Task.checkCancellation()
        try recorder.invoke("AuthProvider", "refreshIfNeeded", ["profileId": .string(profile.id.uuidString)])
        return credentials()
    }
}

struct FixtureEC2Provider: EC2Providing {
    let recorder: PortRecorder

    private func instance(from result: JSONValue?, fallbackId: String) -> EC2Instance {
        EC2Instance(
            id: result?["id"]?.stringValue ?? fallbackId,
            state: EC2Instance.State(rawValue: result?["state"]?.stringValue ?? "running") ?? .unknown,
            privateIpAddress: result?["privateIpAddress"]?.stringValue
        )
    }

    func resolveInstance(
        tagKey: String, tagValue: String, region: String, credentials: AWSCredentials
    ) async throws -> EC2Instance {
        try Task.checkCancellation()
        let result = try recorder.invoke("EC2Provider", "resolveInstance", [
            "tagKey": .string(tagKey), "tagValue": .string(tagValue), "region": .string(region),
        ])
        return instance(from: result, fallbackId: "i-unknown")
    }

    func startInstance(instanceId: String, region: String, credentials: AWSCredentials) async throws {
        try Task.checkCancellation()
        try recorder.invoke("EC2Provider", "startInstance", [
            "instanceId": .string(instanceId), "region": .string(region),
        ])
    }

    func stopInstance(instanceId: String, region: String, credentials: AWSCredentials) async throws {
        try recorder.invoke("EC2Provider", "stopInstance", [
            "instanceId": .string(instanceId), "region": .string(region),
        ])
    }

    func pollUntilRunning(
        instanceId: String, region: String, credentials: AWSCredentials,
        timeout: Duration, interval: Duration
    ) async throws -> EC2Instance {
        try Task.checkCancellation()
        let result = try recorder.invoke("EC2Provider", "pollUntilRunning", ["instanceId": .string(instanceId)])
        return instance(from: result, fallbackId: instanceId)
    }
}

struct FixtureSSMProvider: SSMProviding {
    let recorder: PortRecorder

    func waitForSSMOnline(
        instanceId: String, region: String, credentials: AWSCredentials,
        timeout: Duration, interval: Duration
    ) async throws {
        try Task.checkCancellation()
        try recorder.invoke("SSMProvider", "waitForSSMOnline", [
            "instanceId": .string(instanceId), "region": .string(region),
        ])
    }

    func startSession(
        instanceId: String, region: String, credentials: AWSCredentials,
        localPort: Int, remotePort: Int
    ) async throws -> SSMSessionResponse {
        try Task.checkCancellation()
        let result = try recorder.invoke("SSMProvider", "startSession", [
            "instanceId": .string(instanceId), "region": .string(region),
            "localPort": .number(Double(localPort)), "remotePort": .number(Double(remotePort)),
        ])
        return SSMSessionResponse(
            sessionId: result?["sessionId"]?.stringValue ?? "synthetic-session",
            streamUrl: "wss://ssmmessages.example.invalid/v1/data-channel/synthetic",
            tokenValue: "synthetic-token"
        )
    }
}

struct FixtureSecretsProvider: SecretsProviding {
    let recorder: PortRecorder

    func fetchSecret(secretId: String, region: String, credentials: AWSCredentials) async throws -> String {
        try Task.checkCancellation()
        let result = try recorder.invoke("SecretsProvider", "fetchSecret", [
            "secretId": .string(secretId), "region": .string(region),
        ])
        return result?.stringValue ?? "synthetic-dcv-password"
    }
}

// MARK: - Multi-user ports

struct FixtureIdentityProvider: IdentityProviding {
    let recorder: PortRecorder

    func resolveIdentity(region: String, credentials: AWSCredentials) async throws -> String {
        try Task.checkCancellation()
        let result = try recorder.invoke("IdentityProvider", "resolveIdentity", ["region": .string(region)])
        return result?["username"]?.stringValue ?? "example.user"
    }

    func presignedIdentityToken(region: String, credentials: AWSCredentials) -> String {
        let result = try? recorder.invoke("IdentityProvider", "presignedIdentityToken", ["region": .string(region)])
        return result?.stringValue ?? "synthetic-presigned-token"
    }
}

struct FixtureAgentClient: AgentClienting {
    let recorder: PortRecorder

    func ensureSession(port: Int, authToken: String) async throws -> WorkstationAgentClient.EnsureSessionResult {
        try Task.checkCancellation()
        let result = try recorder.invoke("AgentClient", "ensureSession", ["port": .number(Double(port))])
        return WorkstationAgentClient.EnsureSessionResult(
            sessionId: result?["sessionId"]?.stringValue ?? "example-session",
            user: result?["user"]?.stringValue ?? "example.user"
        )
    }
}

// MARK: - Tunnel

/// A tunnel whose lifetime the harness owns, so a fixture can inject an unexpected process exit.
final class FixtureTunnelHandle: TunnelHandle, @unchecked Sendable {
    let processIdentifier: Int32?
    let localPort: Int

    private let recorder: PortRecorder
    private let lock = NSLock()
    private var active = true
    private var continuation: AsyncStream<TunnelDropReason>.Continuation?
    private let stream: AsyncStream<TunnelDropReason>

    init(recorder: PortRecorder, processIdentifier: Int32, localPort: Int) {
        self.recorder = recorder
        self.processIdentifier = processIdentifier
        self.localPort = localPort
        var escaped: AsyncStream<TunnelDropReason>.Continuation?
        self.stream = AsyncStream { escaped = $0 }
        self.continuation = escaped
    }

    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return active
    }

    var onDisconnect: AsyncStream<TunnelDropReason> { stream }

    func terminate() async {
        guard claimTermination() else { return }
        recordTeardown()
        continuation?.yield(.terminatedByUser)
        continuation?.finish()
    }

    /// Model the plugin process dying on its own, which is what an unexpected tunnel drop is.
    func injectProcessExit(code: Int32, stderr: String) {
        guard claimTermination() else { return }
        continuation?.yield(.processExited(code: code, stderr: stderr))
        continuation?.finish()
    }

    /// Model the app-quit path, where macOS tears the tunnel down by signalling the plugin process
    /// rather than by awaiting `terminate()`. Killing the process *is* terminating the tunnel, so
    /// this records `terminateTunnel` — that is the portable event the contract names. No drop is
    /// emitted: the quit path cancels the monitor first, and a real dead process cannot report.
    func terminateByProcessKill() {
        guard claimTermination() else { return }
        recordTeardown()
        continuation?.finish()
    }

    /// Returns true for the first caller only, so a handle is never torn down twice.
    private func claimTermination() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard active else { return false }
        active = false
        return true
    }

    private func recordTeardown() {
        try? recorder.invoke("TunnelProvider", "terminateTunnel", [
            "processIdentifier": .number(Double(processIdentifier ?? 0)),
        ])
    }
}

final class FixtureTunnelProvider: TunnelProvider, @unchecked Sendable {
    let recorder: PortRecorder
    private let lock = NSLock()
    private var issued: [FixtureTunnelHandle] = []

    init(recorder: PortRecorder) { self.recorder = recorder }

    var handles: [FixtureTunnelHandle] {
        lock.lock(); defer { lock.unlock() }
        return issued
    }

    func checkAvailability() -> TunnelProviderStatus { .available }

    func startTunnel(
        session: SSMSessionResponse, region: String, instanceId: String,
        localPort: Int, remotePort: Int
    ) async throws -> TunnelHandle {
        try Task.checkCancellation()
        let result = try recorder.invoke("TunnelProvider", "startTunnel", [
            "instanceId": .string(instanceId),
            "localPort": .number(Double(localPort)),
            "remotePort": .number(Double(remotePort)),
        ])
        let handle = FixtureTunnelHandle(
            recorder: recorder,
            processIdentifier: Int32(result?["processIdentifier"]?.intValue ?? 4000),
            localPort: localPort
        )
        lock.lock(); issued.append(handle); lock.unlock()
        return handle
    }
}

// MARK: - Readiness, viewer, persistence

struct FixtureReadinessProbe: WorkstationReadinessProbing {
    let recorder: PortRecorder

    func waitUntilReady(port: Int, timeout: Duration, interval: Duration) async -> Bool {
        let result = try? recorder.invoke("ReadinessProbe", "waitUntilReady", ["port": .number(Double(port))])
        return result?.boolValue ?? true
    }
}

struct FixtureTunnelListenerProbe: TunnelListenerProbing {
    let recorder: PortRecorder

    func isListening(host: String, port: Int, timeout: Duration) async -> Bool {
        let result = try? recorder.invoke("ReadinessProbe", "isListening", ["port": .number(Double(port))])
        return result?.boolValue ?? false
    }
}

struct FixtureDCVLauncher: DCVLaunching {
    let recorder: PortRecorder
    let viewerInstalled: Bool

    func isViewerInstalled() -> Bool { viewerInstalled }

    func launch(connectionFile: DCVConnectionFile) async throws {
        try Task.checkCancellation()
        var arguments: [String: JSONValue] = [
            "port": .number(Double(connectionFile.port)),
            "user": .string(connectionFile.user),
            "hasPassword": .bool(connectionFile.password != nil),
            "hasAuthToken": .bool(connectionFile.authToken != nil),
        ]
        if let sessionId = connectionFile.sessionId { arguments["sessionId"] = .string(sessionId) }
        try recorder.invoke("DCVLauncher", "launch", arguments)
    }

    func sweepOrphanedFiles() {
        try? recorder.invoke("DCVLauncher", "sweepOrphanedFiles")
    }
}

final class FixtureInstanceIdStore: InstanceIdPersisting, @unchecked Sendable {
    private let recorder: PortRecorder
    private let lock = NSLock()
    private var value: String?

    init(recorder: PortRecorder, seed: String?) {
        self.recorder = recorder
        self.value = seed
    }

    func lastInstanceId(forProfile id: UUID) -> String? {
        try? recorder.invoke("InstanceIdStore", "lastInstanceId", ["profileId": .string(id.uuidString)])
        lock.lock(); defer { lock.unlock() }
        return value
    }

    func setLastInstanceId(_ instanceId: String, forProfile id: UUID) {
        try? recorder.invoke("InstanceIdStore", "setLastInstanceId", [
            "profileId": .string(id.uuidString), "instanceId": .string(instanceId),
        ])
        lock.lock(); value = instanceId; lock.unlock()
    }
}
