import Foundation
import SSMConnectWorkflow
import os
import SSMConnectDomain

/// Mirrors the connection log to Apple Unified Logging (NF-14), viewable in Console.app.
///
/// This is the macOS half of `ConnectionLog`: the ring buffer that powers the in-app log window is
/// portable and stays in the workflow, while `os.Logger` is Apple-only and lives here.
///
/// Messages are logged `.public` on purpose — the log is a support artifact and is useless if every
/// value is redacted to `<private>`. That places the redaction duty on call sites, which is where
/// it belongs: the DCV password is the only secret the flow holds and it is never passed in.
public struct OSLogSink: LogSink {
    private let loggers: [LogCategory: Logger]

    public init(subsystem: String = "pro.vhco.ssm-connect") {
        self.loggers = Dictionary(
            uniqueKeysWithValues: LogCategory.allCases.map {
                ($0, Logger(subsystem: subsystem, category: $0.rawValue))
            }
        )
    }

    public func write(category: LogCategory, message: String) {
        loggers[category]?.log("\(message, privacy: .public)")
    }
}
