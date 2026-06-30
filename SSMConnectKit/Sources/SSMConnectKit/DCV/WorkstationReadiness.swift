import Foundation
import Network

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

/// Default tunnel-liveness probe: a single raw TCP connect via `NWConnection`. `.ready` means the
/// local listener accepted the connection; `.failed`/`.waiting`/`.cancelled` (e.g. connection
/// refused) or a timeout means nothing is listening.
final class TCPListenerProbe: TunnelListenerProbing, @unchecked Sendable {
    func isListening(host: String, port: Int, timeout: Duration) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(exactly: port) ?? 0) else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let resumed = ResumeOnce()
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            @Sendable func finish(_ value: Bool) {
                guard resumed.claim() else { return }
                connection.cancel()
                continuation.resume(returning: value)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .waiting, .cancelled: finish(false)
                default: break
                }
            }
            connection.start(queue: .global())
            Task {
                try? await Task.sleep(for: timeout)
                finish(false)
            }
        }
    }
}

/// One-shot guard so the `NWConnection` callback and the timeout task can't double-resume the
/// continuation.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    /// Returns true exactly once (for the first caller), false thereafter.
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
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

/// Default probe: an HTTPS request to `127.0.0.1:<port>` that tolerates the workstation's
/// self-signed certificate. Any HTTP response means the server is up.
final class HTTPSReadinessProbe: NSObject, WorkstationReadinessProbing, URLSessionDelegate, @unchecked Sendable {
    func waitUntilReady(port: Int, timeout: Duration, interval: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await responds(port: port) { return true }
            try? await Task.sleep(for: interval)
        }
        return await responds(port: port)
    }

    private func responds(port: Int) async -> Bool {
        // IPv4 loopback, not `localhost`: the SSM port-forward binds IPv4 `127.0.0.1` only; probing
        // `localhost` can resolve to IPv6 `::1` and miss the listener (see DCVConnectionFile.host).
        guard let url = URL(string: "https://127.0.0.1:\(port)/") else { return false }
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 3
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (_, response) = try await session.data(from: url)
            return response is HTTPURLResponse
        } catch {
            return false
        }
    }

    /// Accept the workstation's self-signed certificate — but only for the IPv4 loopback
    /// `127.0.0.1` (the tunnel endpoint); the SSM tunnel itself is the security boundary.
    /// Everything else uses default trust.
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           challenge.protectionSpace.host == "127.0.0.1",
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
