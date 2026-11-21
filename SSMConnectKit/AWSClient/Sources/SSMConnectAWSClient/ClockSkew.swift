import Foundation

/// Learned clock offsets per host, shared by every client in the process, as aws-sdk-swift
/// 1.7.62 keeps them (smithy-swift `ClockSkewStore`). A request to a host is signed at the
/// local time plus its offset. Each update compares, replaces and reports a change in one
/// actor step, so of several requests that fail with the same skew at once only the first
/// sees a change and retries.
public actor ClockSkewStore {
    public static let shared = ClockSkewStore()

    private var offsets: [String: TimeInterval] = [:]

    /// A separate store, for tests that must not share learned offsets.
    public init() {}

    public func offset(host: String) -> TimeInterval? { offsets[host] }

    /// Applies one failed response to the host's offset and returns whether it changed.
    func update(host: String, _ next: @Sendable (TimeInterval?) -> TimeInterval?) -> Bool {
        let previous = offsets[host]
        let value = next(previous)
        offsets[host] = value
        return value != previous
    }
}

/// The SDK's clock-skew transitions (aws-sdk-swift `AWSClockSkewProvider`).
enum ClockSkew {
    /// Differences of 300 seconds or less are not corrected.
    static let absoluteThreshold: TimeInterval = 300
    /// A new difference within 60 seconds of the stored one keeps the stored one.
    static let changeThreshold: TimeInterval = 60

    static let definiteCodes: Set<String> = ["RequestTimeTooSkewed", "RequestExpired", "RequestInTheFuture"]
    static let probableCodes: Set<String> = ["InvalidSignatureException", "AuthFailure", "SignatureDoesNotMatch"]

    static func isSkewError(_ error: AWSServiceError) -> Bool {
        guard let code = error.typeName else { return false }
        return definiteCodes.contains(code) || probableCodes.contains(code)
    }

    /// The host's next offset after `error`. `signedAt` is the unadjusted local time the request
    /// was signed at, nil for an unsigned request.
    static func next(previous: TimeInterval?, error: AWSServiceError, signedAt: Date?, response: HTTPResponse) -> TimeInterval? {
        guard isSkewError(error) else { return previous }
        let new = difference(signedAt: signedAt, response: response)
        if let new, let previous { return abs(new - previous) > changeThreshold ? new : previous }
        return new
    }

    /// The server's time minus the local signing time when it exceeds the threshold; nil when it
    /// does not, or when there is no signing time or no parseable Date header.
    static func difference(signedAt: Date?, response: HTTPResponse) -> TimeInterval? {
        guard let signedAt, let header = response.header("Date"), let server = httpDate(header) else { return nil }
        let skew = server.timeIntervalSince(signedAt)
        return abs(skew) > absoluteThreshold ? skew : nil
    }

    /// Parses an HTTP date in IMF-fixdate form ("Sun, 06 Nov 1994 08:49:37 GMT"), the form AWS sends.
    static func httpDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)
    }
}

/// The client's retry quotas, one per service, as each SDK client holds one per
/// `<ClientName> - <region>` (smithy-swift `RetryQuota` in its default mode).
final class RetryQuotas: @unchecked Sendable {
    static let capacity = 500
    static let retryCost = 5
    static let timeoutRetryCost = 10
    static let noRetryIncrement = 1

    private let lock = NSLock()
    private var available: [String: Int] = [:]

    /// Takes the cost of one retry; nil when the remaining capacity cannot cover it.
    func take(_ service: String, timeout: Bool) -> Int? {
        lock.withLock {
            let cost = timeout ? Self.timeoutRetryCost : Self.retryCost
            let remaining = available[service] ?? Self.capacity
            guard cost <= remaining else { return nil }
            available[service] = remaining - cost
            return cost
        }
    }

    /// After a successful call: returns the last retry's cost, or 1 when it made no retry.
    func release(_ service: String, lastRetryCost: Int?) {
        lock.withLock {
            available[service] = min((available[service] ?? Self.capacity) + (lastRetryCost ?? Self.noRetryIncrement), Self.capacity)
        }
    }
}
