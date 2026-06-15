import Foundation

/// Probes whether the forwarded workstation server (e.g. the in-VM DCV server) is actually
/// accepting connections through the tunnel.
///
/// The SSM agent reporting `Online` does **not** mean the DCV server is listening on the remote
/// port yet — that gap is what surfaced as DCV Viewer's "cannot connect a new stream: endpoint is
/// unreachable". We probe `localhost:<localPort>` before launching the viewer so it doesn't connect
/// into a not-yet-ready server.
protocol WorkstationReadinessProbing: Sendable {
    /// Poll `localhost:port` until the server answers (any HTTP response), or `timeout` elapses.
    /// Returns `true` once reachable, `false` if it never became reachable in time.
    func waitUntilReady(port: Int, timeout: Duration, interval: Duration) async -> Bool
}

/// Default probe: an HTTPS request to `localhost:<port>` that tolerates the workstation's
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
        guard let url = URL(string: "https://localhost:\(port)/") else { return false }
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

    /// Accept the workstation's self-signed certificate — but only for `localhost` (the tunnel
    /// endpoint); the SSM tunnel itself is the security boundary. Everything else uses default trust.
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           challenge.protectionSpace.host == "localhost",
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
