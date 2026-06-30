import Foundation

/// Per-stage timeout budget for the connection flow (spec §5 timing table, F-06).
struct ConnectionTimeouts: Sendable {
    var authenticate: Duration = .seconds(300)   // 5 min browser login
    var resolve: Duration = .seconds(30)
    var start: Duration = .seconds(300)          // 5 min instance start
    var startPollInterval: Duration = .seconds(5)
    var ssm: Duration = .seconds(180)            // 3 min SSM registration
    var ssmPollInterval: Duration = .seconds(5)
    var tunnel: Duration = .seconds(30)
    /// Wait for the in-VM DCV server to start accepting connections after the tunnel is up
    /// (SSM-agent-Online ≠ DCV-server-ready).
    var dcvReady: Duration = .seconds(30)
    var dcvReadyPollInterval: Duration = .seconds(1)
    /// Budget for the tunnel-up TCP assertion before the readiness probe (#9, RVL-3).
    var tunnelListen: Duration = .seconds(3)
    /// How many times to tear down + re-establish the tunnel on a pre-launch readiness failure
    /// before surfacing a retryable error (#9, RVL-5). 2 retries → 3 attempts total.
    var establishRetryAttempts: Int = 2
    /// Base backoff between RVL-5 re-establish attempts; multiplied by the attempt number (2s, 4s).
    var establishRetryBackoff: Duration = .seconds(2)

    static let `default` = ConnectionTimeouts()
}

/// Thrown when a connection stage exceeds its timeout budget (F-06).
struct StageTimeoutError: LocalizedError, Equatable {
    let stage: String
    var errorDescription: String? { "\(stage) timed out." }
}

/// Run `operation`, throwing `StageTimeoutError` if it doesn't finish within `duration`.
/// The losing child task is cancelled.
func withStageTimeout<T: Sendable>(
    _ stage: String,
    _ duration: Duration,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await sleep(duration)
            throw StageTimeoutError(stage: stage)
        }
        defer { group.cancelAll() }
        guard let result = try await group.next() else {
            throw StageTimeoutError(stage: stage)
        }
        return result
    }
}
