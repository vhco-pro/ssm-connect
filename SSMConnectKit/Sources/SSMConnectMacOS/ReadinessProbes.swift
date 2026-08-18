import Foundation
import Network
import SSMConnectDomain
import SSMConnectWorkflow

/// Concrete readiness probes for macOS: the adapters behind `TunnelListenerProbing` and
/// `WorkstationReadinessProbing` (spec §5.2). Split out from the protocols so the ports stay
/// importable by the portable workflow, which must not pull in `Network` or `URLSession`.

/// Default tunnel-liveness probe: a single raw TCP connect via `NWConnection`. `.ready` means the
/// local listener accepted the connection; `.failed`/`.waiting`/`.cancelled` (e.g. connection
/// refused) or a timeout means nothing is listening.
public final class TCPListenerProbe: TunnelListenerProbing, @unchecked Sendable {
    public init() {}

    public func isListening(host: String, port: Int, timeout: Duration) async -> Bool {
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
    public func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// Default probe: an HTTPS request to `127.0.0.1:<port>` that tolerates the workstation's
/// self-signed certificate. Any HTTP response means the server is up.
public final class HTTPSReadinessProbe: NSObject, WorkstationReadinessProbing, URLSessionDelegate, @unchecked Sendable {
    public override init() { super.init() }

    public func waitUntilReady(port: Int, timeout: Duration, interval: Duration) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if await responds(port: port) { return true }
            try? await Task.sleep(for: interval)
        }
        return await responds(port: port)
    }

    private func responds(port: Int) async -> Bool {
        // IPv4 loopback, not `localhost`: the SSM port-forward binds IPv4 `127.0.0.1` only, while
        // probing `localhost` can resolve to IPv6 `::1` and miss the listener (see DCVConnectionFile.host).
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
    public func urlSession(
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
