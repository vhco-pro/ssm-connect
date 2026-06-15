import Foundation
import Observation
import os

/// Logging categories matching the spec's unified-logging taxonomy (NF-14).
enum LogCategory: String, Sendable, CaseIterable {
    case auth, ec2, ssm, tunnel, ui
}

/// A single connection-log line (H2/F-19). Held in memory only; never persisted to disk.
struct LogEntry: Identifiable, Equatable, Sendable {
    let id = UUID()
    let timestamp: Date
    let category: LogCategory
    let message: String
}

/// In-memory connection log (last 200 lines, F-19) mirrored to Apple Unified Logging (NF-14).
///
/// Every line is also emitted via `os.Logger` under subsystem `pro.vhco.ssm-connect` and the
/// relevant category, viewable in Console.app. Sensitive values must never be passed in as part
/// of the message — call sites redact them (the menu password is the only secret and is never
/// logged). The in-memory ring buffer powers the "Show Log" window (H3).
@MainActor
@Observable
public final class ConnectionLog {
    /// Newest-last list of buffered entries (drives `LogView`).
    private(set) var entries: [LogEntry] = []

    private var buffer: RingBuffer<LogEntry>
    private let loggers: [LogCategory: Logger]
    private let now: () -> Date

    init(
        capacity: Int = 200,
        subsystem: String = "pro.vhco.ssm-connect",
        now: @escaping () -> Date = Date.init
    ) {
        self.buffer = RingBuffer(capacity: capacity)
        self.now = now
        self.loggers = Dictionary(
            uniqueKeysWithValues: LogCategory.allCases.map {
                ($0, Logger(subsystem: subsystem, category: $0.rawValue))
            }
        )
    }

    /// Append a log line to the in-memory buffer and emit it to Apple Unified Logging.
    func log(_ category: LogCategory, _ message: String) {
        let entry = LogEntry(timestamp: now(), category: category, message: message)
        buffer.append(entry)
        entries = buffer.elements
        loggers[category]?.log("\(message, privacy: .public)")
    }

    func clear() {
        buffer.removeAll()
        entries = []
    }
}
