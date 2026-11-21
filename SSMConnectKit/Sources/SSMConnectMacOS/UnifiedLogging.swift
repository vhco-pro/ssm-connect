import Foundation
import os
import SSMConnectAWS
import SSMConnectDomain
import SSMConnectWorkflow

extension ConnectionLog {
    /// A connection log mirrored to Apple Unified Logging (NF-14): every line is also emitted
    /// via `os.Logger` under `subsystem` and its category, viewable in Console.app.
    @MainActor
    package static func unified(subsystem: String = "pro.vhco.ssm-connect", capacity: Int = 200) -> ConnectionLog {
        let loggers = Dictionary(uniqueKeysWithValues: LogCategory.allCases.map {
            ($0, Logger(subsystem: subsystem, category: $0.rawValue))
        })
        return ConnectionLog(capacity: capacity, mirror: { category, message in
            loggers[category]?.log("\(message, privacy: .public)")
        })
    }
}
