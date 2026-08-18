import Foundation
import SSMConnectWorkflow
import SSMConnectDomain

/// Talks to the on-box `workstation-agent` over the SSM-forwarded loopback port
/// (multi-user mode). Today it calls `/ensure-session` to provision the caller's
/// Linux user + virtual session **before** the DCV connection — required because
/// DCV external token auth bypasses PAM, so there is no login hook to create the
/// session lazily (spec R1 / §12.4).
///
/// The request is authenticated by the same presigned-identity token used for the
/// DCV connection, so the agent only ever provisions the caller's own session.
public struct WorkstationAgentClient {
    /// RFC 3986 percent-encoding. Duplicated from the AWS presigner rather than imported: this
    /// adapter posts a form body and has no other reason to depend on the AWS target.
    public static func rfc3986(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    public typealias Post = @Sendable (_ url: URL, _ body: Data) async throws -> (Data, HTTPURLResponse)

    /// Base URL of the agent, e.g. `http://127.0.0.1:8444` (the local end of the agent tunnel).
    public let baseURL: URL
    public var post: Post = { url, body in
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AgentError.badResponse }
        return (data, http)
    }

    /// Ensures the caller's virtual session exists and returns its id + owner.
    public func ensureSession(authToken: String) async throws -> EnsureSessionResult {
        let url = baseURL.appendingPathComponent("ensure-session")
        let encoded = Self.rfc3986(authToken)
        let body = Data("authenticationToken=\(encoded)".utf8)
        let (data, response) = try await post(url, body)
        switch response.statusCode {
        case 200:
            guard let result = try? JSONDecoder().decode(EnsureSessionResult.self, from: data) else {
                throw AgentError.badResponse
            }
            return result
        case 401:
            throw AgentError.unauthorized
        default:
            throw AgentError.provisioningFailed(status: response.statusCode)
        }
    }
}

/// Production `AgentClienting`: one client per call, pointed at the loopback port the transient
/// agent tunnel is forwarding.
public struct HTTPAgentClient: AgentClienting {
    public init() {}

    public func ensureSession(port: Int, authToken: String) async throws -> EnsureSessionResult {
        // Force-unwrap is safe: a fixed loopback URL with an integer port.
        let client = WorkstationAgentClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!)
        return try await client.ensureSession(authToken: authToken)
    }
}
