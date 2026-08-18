import Foundation
import Observation
import SSMConnectDomain

/// Logging categories matching the spec's unified-logging taxonomy (NF-14).
public enum LogCategory: String, Sendable, CaseIterable {
    case auth, ec2, ssm, tunnel, ui
}

/// A single connection-log line (H2/F-19). Held in memory only; never persisted to disk.
public struct LogEntry: Identifiable, Equatable, Sendable {
    public let id = UUID()
    public let timestamp: Date
    public let category: LogCategory
    public let message: String
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
    public private(set) var entries: [LogEntry] = []

    private var buffer: RingBuffer<LogEntry>
    private let sink: any LogSink
    private let now: () -> Date

    public init(
        capacity: Int = 200,
        sink: any LogSink = NullLogSink(),
        now: @escaping () -> Date = Date.init
    ) {
        self.buffer = RingBuffer(capacity: capacity)
        self.now = now
        self.sink = sink
    }

    /// Append a log line to the in-memory buffer and emit it to Apple Unified Logging.
    public func log(_ category: LogCategory, _ message: String) {
        let entry = LogEntry(timestamp: now(), category: category, message: message)
        buffer.append(entry)
        entries = buffer.elements
        sink.write(category: category, message: message)
    }

    public func clear() {
        buffer.removeAll()
        entries = []
    }
}

/// Where a log line goes once it is in the ring buffer.
///
/// The buffer itself is portable; mirroring to the platform's structured logging is not. Apple
/// Unified Logging is `os.Logger`, which this target may not import (spec §5.2), so the platform
/// supplies the sink and the workflow stays unaware of which one it got.
public protocol LogSink: Sendable {
    func write(category: LogCategory, message: String)
}

/// Buffer-only sink: the in-memory log still works, nothing is mirrored. The default so the
/// workflow is usable without a platform adapter, and what the conformance fixtures run with.
public struct NullLogSink: LogSink {
    public init() {}
    public func write(category: LogCategory, message: String) {}
}
