import Foundation
import SSMConnectDomain

/// In-memory `SSMProviding` test double for higher-level (state-machine) tests (D8).
public final class MockSSMService: SSMProviding, @unchecked Sendable {
    public var waitError: Error?
    public var startSessionResult: Result<SSMSessionResponse, Error> = .success(.stub())

    private(set) var waitCount = 0
    private(set) var startSessionCount = 0
    private(set) var lastLocalPort: Int?
    private(set) var lastRemotePort: Int?

    public func waitForSSMOnline(
        instanceId: String,
        region: String,
        credentials: AWSCredentials,
        timeout: Duration,
        interval: Duration
    ) async throws {
        waitCount += 1
        if let waitError { throw waitError }
    }

    public func startSession(
        instanceId: String,
        region: String,
        credentials: AWSCredentials,
        localPort: Int,
        remotePort: Int
    ) async throws -> SSMSessionResponse {
        startSessionCount += 1
        lastLocalPort = localPort
        lastRemotePort = remotePort
        return try startSessionResult.get()
    }

    /// How many sessions a reap should claim to have found. Zero is the normal case: nothing was
    /// left behind by a previous run.
    public var reapResult: Result<Int, Error> = .success(0)

    private(set) var reapCount = 0
    private(set) var terminatedSessionIds: [String] = []

    public func reapOrphanedSessions(
        instanceId: String,
        region: String,
        credentials: AWSCredentials
    ) async throws -> Int {
        reapCount += 1
        return try reapResult.get()
    }

    public func terminateSession(
        sessionId: String,
        region: String,
        credentials: AWSCredentials
    ) async throws {
        terminatedSessionIds.append(sessionId)
    }
}

/// In-memory `TunnelProvider` / `TunnelHandle` test doubles (D8).
public final class MockTunnelProvider: TunnelProvider, @unchecked Sendable {
    public var availability: TunnelProviderStatus = .available
    public var startResult: Result<TunnelHandle, Error>?

    private(set) var startCount = 0

    public func checkAvailability() -> TunnelProviderStatus { availability }

    public func startTunnel(
        session: SSMSessionResponse,
        region: String,
        instanceId: String,
        localPort: Int,
        remotePort: Int
    ) async throws -> TunnelHandle {
        startCount += 1
        if let startResult { return try startResult.get() }
        return MockTunnelHandle()
    }
}

public final class MockTunnelHandle: TunnelHandle, @unchecked Sendable {
    public var isActive: Bool = true
    public var processIdentifier: Int32? = 4242
    private(set) var terminateCount = 0
    private let continuation: AsyncStream<TunnelDropReason>.Continuation
    public let onDisconnect: AsyncStream<TunnelDropReason>

    public init() {
        var captured: AsyncStream<TunnelDropReason>.Continuation!
        onDisconnect = AsyncStream { captured = $0 }
        continuation = captured
    }

    public func terminate() async {
        terminateCount += 1
        isActive = false
        continuation.yield(.terminatedByUser)
        continuation.finish()
    }

    /// Test helper: simulate the plugin process exiting unexpectedly.
    public func simulateDrop(code: Int32 = 1, stderr: String = "") {
        isActive = false
        continuation.yield(.processExited(code: code, stderr: stderr))
        continuation.finish()
    }
}

public extension SSMSessionResponse {
    public static func stub(
        sessionId: String = "example-session-0abc1234",
        streamUrl: String = "wss://ssmmessages.us-east-1.amazonaws.com/v1/data-channel/example-session-0abc1234?role=publish_subscribe",
        tokenValue: String = "AAEAAfEXAMPLE"
    ) -> SSMSessionResponse {
        SSMSessionResponse(sessionId: sessionId, streamUrl: streamUrl, tokenValue: tokenValue)
    }
}
