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
