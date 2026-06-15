import Foundation

/// Abstracts the SSM port-forwarding tunnel mechanism (spec §6.2, D3).
///
/// v1: `BundledPluginTunnel` (shells out to the bundled `session-manager-plugin`).
/// Future: a native Swift WebSocket tunnel reimplementing the SSM data channel.
protocol TunnelProvider: Sendable {
    /// Establish a port-forwarding tunnel.
    /// - Returns: a `TunnelHandle` for monitoring and teardown.
    func startTunnel(
        session: SSMSessionResponse,
        region: String,
        instanceId: String,
        localPort: Int,
        remotePort: Int
    ) async throws -> TunnelHandle

    /// Whether the provider's dependencies (e.g. the bundled plugin binary) are available.
    func checkAvailability() -> TunnelProviderStatus
}

/// A live tunnel: monitor `isActive`, observe drops via `onDisconnect`, and `terminate()` to tear down.
protocol TunnelHandle: Sendable {
    var isActive: Bool { get }
    var processIdentifier: Int32? { get }
    func terminate() async
    /// Emits exactly once when the tunnel drops, then finishes.
    var onDisconnect: AsyncStream<TunnelDropReason> { get }
}

/// Availability of a `TunnelProvider`'s dependencies (spec §8 plugin-missing edge cases).
enum TunnelProviderStatus: Equatable, Sendable {
    case available
    case pluginMissing(path: String)
    case pluginNotExecutable(path: String)
}

/// Why a tunnel dropped (F-13).
enum TunnelDropReason: Equatable, Sendable {
    /// Plugin process exited; carries the exit code and any captured stderr tail.
    case processExited(code: Int32, stderr: String)
    /// We asked it to stop (normal teardown).
    case terminatedByUser
}

/// Errors thrown while establishing a tunnel (spec §8).
enum TunnelError: LocalizedError, Equatable {
    case pluginMissing(path: String)
    case pluginNotExecutable(path: String)
    case localPortInUse(port: Int, pid: Int32?, processName: String?)
    case launchFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case let .pluginMissing(path):
            "The session-manager-plugin binary is missing from the app bundle (expected at \(path)). Reinstall SSM Connect."
        case let .pluginNotExecutable(path):
            "The session-manager-plugin at \(path) cannot be executed. It may need to be re-signed or approved in System Settings → Privacy & Security."
        case let .localPortInUse(port, pid, name):
            if let pid {
                "Local port \(port) is in use by PID \(pid)\(name.map { " (\($0))" } ?? ""). Free the port or change the local port in Settings."
            } else {
                "Local port \(port) is already in use. Free the port or change the local port in Settings."
            }
        case let .launchFailed(reason):
            "Failed to launch the SSM tunnel: \(reason)"
        }
    }
}
