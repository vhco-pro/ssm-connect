import Foundation
import SSMConnectDomain
import Observation

/// Logging categories matching the spec's unified-logging taxonomy (NF-14).
package enum LogCategory: String, Sendable, CaseIterable {
    case auth, ec2, ssm, tunnel, ui
}

/// A single connection-log line (H2/F-19). Held in memory only; never persisted to disk.
package struct LogEntry: Identifiable, Equatable, Sendable {
    package let id = UUID()
    package let timestamp: Date
    package let category: LogCategory
    package let message: String

    package init(timestamp: Date, category: LogCategory, message: String) {
        self.timestamp = timestamp
        self.category = category
        self.message = message
    }
}

/// In-memory connection log (last 200 lines, F-19), optionally mirrored to the platform's
/// system log (on macOS, Apple Unified Logging, NF-14: `ConnectionLog.unified()`).
///
/// Sensitive values must never be passed in as part of the message — call sites redact them
/// (the menu password is the only secret and is never logged). The in-memory ring buffer powers
/// the "Show Log" window (H3).
@MainActor
@Observable
public final class ConnectionLog {
    /// Newest-last list of buffered entries (drives `LogView`).
    package private(set) var entries: [LogEntry] = []

    private var buffer: RingBuffer<LogEntry>
    private let mirror: (@Sendable (LogCategory, String) -> Void)?
    private let now: () -> Date

    /// `mirror` receives every line as well, for the platform's system log.
    package init(
        capacity: Int = 200,
        now: @escaping () -> Date = Date.init,
        mirror: (@Sendable (LogCategory, String) -> Void)? = nil
    ) {
        self.buffer = RingBuffer(capacity: capacity)
        self.now = now
        self.mirror = mirror
    }

    /// Append a log line to the in-memory buffer and pass it to the mirror.
    package func log(_ category: LogCategory, _ message: String) {
        let entry = LogEntry(timestamp: now(), category: category, message: message)
        buffer.append(entry)
        entries = buffer.elements
        mirror?(category, message)
    }

    package func clear() {
        buffer.removeAll()
        entries = []
    }
}
