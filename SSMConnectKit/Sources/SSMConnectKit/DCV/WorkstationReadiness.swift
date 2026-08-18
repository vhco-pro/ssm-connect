import Foundation

/// A pre-launch failure that must NOT be masked by launching the viewer anyway (#9, RVL-1/3/6).
/// Both cases are fatal-but-retryable: they route to the `.error` state, where the menu offers
/// "Retry Connect". They are deliberately distinct so the user sees *what* failed:
/// - `tunnelNotEstablished`: the SSM port-forward isn't listening locally at all.
/// - `dcvServerNotReady`: the tunnel is up, but the in-VM DCV server never answered in time.
enum DCVReadinessError: LocalizedError, Equatable {
    case tunnelNotEstablished(port: Int)
    case dcvServerNotReady(port: Int)

    var errorDescription: String? {
        switch self {
        case let .tunnelNotEstablished(port):
            "The secure tunnel isn't listening on 127.0.0.1:\(port), so the connection couldn't be "
                + "established. This is usually transient — Retry to try again."
        case let .dcvServerNotReady(port):
            "The workstation's DCV server didn't become ready in time (127.0.0.1:\(port)). "
                + "It may still be starting up — Retry in a moment."
        }
    }
}

/// Asserts that something is actually listening on the forwarded *local* port — i.e. the
/// `session-manager-plugin` tunnel is up — independently of whether the in-VM DCV server is ready.
/// The plugin binds the local port as soon as it starts, so a raw TCP refusal here cleanly
/// distinguishes a dead tunnel (`tunnelNotEstablished`) from a not-yet-ready server (the HTTPS
/// readiness probe → `dcvServerNotReady`). See #9 RVL-3.
protocol TunnelListenerProbing: Sendable {
    /// True if a TCP connection to `host:port` succeeds within `timeout`.
    func isListening(host: String, port: Int, timeout: Duration) async -> Bool
}

/// Probes whether the forwarded workstation server (e.g. the in-VM DCV server) is actually
/// accepting connections through the tunnel.
///
/// The SSM agent reporting `Online` does **not** mean the DCV server is listening on the remote
/// port yet — that gap is what surfaced as DCV Viewer's "cannot connect a new stream: endpoint is
/// unreachable". We probe `127.0.0.1:<localPort>` before launching the viewer so it doesn't connect
/// into a not-yet-ready server.
protocol WorkstationReadinessProbing: Sendable {
    /// Poll `127.0.0.1:port` until the server answers (any HTTP response), or `timeout` elapses.
    /// Returns `true` once reachable, `false` if it never became reachable in time.
    func waitUntilReady(port: Int, timeout: Duration, interval: Duration) async -> Bool
}

// The concrete probes live in `ReadinessProbes.swift`: they need `Network` and `URLSession`, while
// these two protocols are workflow ports that must stay free of platform networking (spec §5.2).
