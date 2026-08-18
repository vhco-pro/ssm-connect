import Darwin
import Foundation

/// Synchronous, best-effort teardown of the `session-manager-plugin` child by PID (F-13, MR-04).
///
/// This lives in the macOS tunnel adapter rather than in the connection flow because sending a
/// POSIX signal is an operating-system action, and the portable workflow is not allowed to take
/// one (spec §5.2). The flow decides *when* the tunnel must die on quit; this decides *how* on
/// this platform. The Windows client answers the same question with a Job Object.
///
/// Synchronous on purpose: `applicationWillTerminate` cannot await, so there is no opportunity to
/// go through `TunnelHandle.terminate()`.
enum PluginProcessTerminator {
    /// SIGTERM, a short grace period, then SIGKILL. The grace period lets the plugin close its
    /// data channel cleanly; the SIGKILL guarantees the local port is released either way.
    static let signalSequence: @Sendable (Int32) -> Void = { pid in
        kill(pid, SIGTERM)
        usleep(300_000) // 0.3s grace
        kill(pid, SIGKILL)
    }
}
