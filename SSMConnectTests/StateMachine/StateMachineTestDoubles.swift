import Foundation
@testable import SSMConnect

// MARK: - State-machine test doubles (Phase F)

/// A `TunnelProvider` that hands out a pre-seeded queue of handles and records each call,
/// so tunnel-drop / auto-reconnect tests can drop one handle and assert a second is opened.
final class RecordingTunnelProvider: TunnelProvider, @unchecked Sendable {
    var availability: TunnelProviderStatus = .available
    var fallbackError: Error?

    private var queued: [MockTunnelHandle]
    private(set) var startCount = 0
    private(set) var issuedHandles: [MockTunnelHandle] = []

    init(handles: [MockTunnelHandle]) { self.queued = handles }

    func checkAvailability() -> TunnelProviderStatus { availability }

    func startTunnel(
        session: SSMSessionResponse,
        region: String,
        instanceId: String,
        localPort: Int,
        remotePort: Int
    ) async throws -> TunnelHandle {
        startCount += 1
        if queued.isEmpty {
            if let fallbackError { throw fallbackError }
            let handle = MockTunnelHandle()
            issuedHandles.append(handle)
            return handle
        }
        let handle = queued.removeFirst()
        issuedHandles.append(handle)
        return handle
    }
}

/// In-memory `DCVLaunching` double recording launches/sweeps.
final class MockDCVLauncher: DCVLaunching, @unchecked Sendable {
    var installed = true
    var launchError: Error?

    private(set) var launchCount = 0
    private(set) var sweepCount = 0
    private(set) var lastConnectionFile: DCVConnectionFile?

    func isViewerInstalled() -> Bool { installed }

    func launch(connectionFile: DCVConnectionFile) async throws {
        launchCount += 1
        lastConnectionFile = connectionFile
        if let launchError { throw launchError }
    }

    func sweepOrphanedFiles() { sweepCount += 1 }
}

/// An `EC2Providing` double whose `resolveInstance` returns results from a queue (later results
/// reused once exhausted), so the SSO-expiry retry path can fail-then-succeed.
final class SequencedEC2Service: EC2Providing, @unchecked Sendable {
    private var resolveResults: [Result<EC2Instance, Error>]
    var pollResult: Result<EC2Instance, Error> = .success(.stub(state: .running))
    var startError: Error?

    private(set) var resolveCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0

    init(resolveResults: [Result<EC2Instance, Error>]) { self.resolveResults = resolveResults }

    func resolveInstance(
        tagKey: String,
        tagValue: String,
        region: String,
        credentials: AWSCredentials
    ) async throws -> EC2Instance {
        resolveCount += 1
        let result = resolveResults.count > 1 ? resolveResults.removeFirst() : (resolveResults.first ?? .success(.stub(state: .running)))
        return try result.get()
    }

    func startInstance(instanceId: String, region: String, credentials: AWSCredentials) async throws {
        startCount += 1
        if let startError { throw startError }
    }

    func stopInstance(instanceId: String, region: String, credentials: AWSCredentials) async throws {
        stopCount += 1
    }

    func pollUntilRunning(
        instanceId: String,
        region: String,
        credentials: AWSCredentials,
        timeout: Duration,
        interval: Duration
    ) async throws -> EC2Instance {
        try pollResult.get()
    }
}

/// Readiness probe double — returns a fixed result immediately (no network).
final class StubReadinessProbe: WorkstationReadinessProbing, @unchecked Sendable {
    var ready: Bool
    private(set) var calls = 0
    init(ready: Bool = true) { self.ready = ready }
    func waitUntilReady(port: Int, timeout: Duration, interval: Duration) async -> Bool {
        calls += 1
        return ready
    }
}

/// Sentinel error treated as "credentials expired" by an injected predicate.
struct StubExpiredError: Error {}

/// Records notification calls for assertions (H8, F-20).
final class MockNotifier: Notifying, @unchecked Sendable {
    private let lock = NSLock()
    private var _events: [NotificationEvent] = []
    private var _authRequests = 0

    var events: [NotificationEvent] { lock.lock(); defer { lock.unlock() }; return _events }
    var authorizationRequests: Int { lock.lock(); defer { lock.unlock() }; return _authRequests }

    func requestAuthorization() async {
        lock.lock(); _authRequests += 1; lock.unlock()
    }

    func post(_ event: NotificationEvent) async {
        lock.lock(); _events.append(event); lock.unlock()
    }
}

