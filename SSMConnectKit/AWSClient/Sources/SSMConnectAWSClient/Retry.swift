import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The client's one retry policy: what aws-sdk-swift 1.7.62 (smithy-swift 0.242.0
/// DefaultRetryStrategy and AWSRetryErrorInfoProvider) does with nothing configured.
/// At most 3 attempts; before retry n a delay of random() * 2^n seconds, capped at 20;
/// x-amz-retry-after ignored. Retry environment variables and shared-config retry
/// settings are never read.
public struct RetryPolicy: Sendable {
    public static let maxAttempts = 3
    public static let maxBackoff = 20.0

    public var random: @Sendable () -> Double
    public var sleep: @Sendable (Double) async throws -> Void

    public init(random: @escaping @Sendable () -> Double = { Double.random(in: 0.0...1.0) },
                sleep: @escaping @Sendable (Double) async throws -> Void = { seconds in
                    guard seconds > 0 else { return }
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                }) {
        self.random = random
        self.sleep = sleep
    }

    public static let standard = RetryPolicy()

    public static func delay(retry: Int, random: Double) -> Double {
        min(random * pow(2.0, Double(retry)), maxBackoff)
    }

    static let throttlingCodes: Set<String> = [
        "Throttling", "ThrottlingException", "ThrottledException", "RequestThrottledException",
        "TooManyRequestsException", "ProvisionedThroughputExceededException", "TransactionInProgressException",
        "RequestLimitExceeded", "BandwidthLimitExceeded", "LimitExceededException", "RequestThrottled",
        "SlowDown", "PriorRequestNotComplete", "EC2ThrottledException",
    ]
    static let transientCodes: Set<String> = ["RequestTimeout", "InternalError", "RequestTimeoutException"]
    static let transientStatuses: Set<Int> = [500, 502, 503, 504, 408]

    static func isRetryable(_ error: AWSServiceError) -> Bool {
        if let code = error.typeName, throttlingCodes.contains(code) || transientCodes.contains(code) { return true }
        if let status = error.httpStatus, transientStatuses.contains(status) { return true }
        return false
    }

    /// The URLSession failures the SDK retries: lost connection, timeout and failed TLS.
    static func isRetryable(_ error: URLError) -> Bool {
        [URLError.Code.networkConnectionLost, .timedOut, .secureConnectionFailed].contains(error.code)
    }
}
