import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import SSMConnectDomain

/// Talks to the on-box `workstation-agent` over the SSM-forwarded loopback port
/// (multi-user mode). Today it calls `/ensure-session` to provision the caller's
/// Linux user + virtual session **before** the DCV connection — required because
/// DCV external token auth bypasses PAM, so there is no login hook to create the
/// session lazily (spec R1 / §12.4).
///
/// The request is authenticated by the same presigned-identity token used for the
/// DCV connection, so the agent only ever provisions the caller's own session.
package struct WorkstationAgentClient {
    package typealias Post = @Sendable (_ url: URL, _ body: Data) async throws -> (Data, HTTPURLResponse)

    /// Base URL of the agent, e.g. `http://127.0.0.1:8444` (the local end of the agent tunnel).
    package let baseURL: URL
    package var post: Post

    package struct EnsureSessionResult: Decodable, Equatable {
        package let sessionId: String
        package let user: String

        package init(sessionId: String, user: String) {
            self.sessionId = sessionId
            self.user = user
        }
    }

    package enum AgentError: Error, Equatable, LocalizedError {
        case unauthorized
        case provisioningFailed(status: Int)
        case badResponse

        package var errorDescription: String? {
            switch self {
            case .unauthorized:
                "You're not authorized for this workstation."
            case .provisioningFailed(let status):
                "The workstation couldn't prepare your session (agent error \(status))."
            case .badResponse:
                "The workstation agent returned an unexpected response."
            }
        }
    }

    /// Ensures the caller's virtual session exists and returns its id + owner.
    package func ensureSession(authToken: String) async throws -> EnsureSessionResult {
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

    /// RFC3986 encoding per SigV4: only `A-Za-z0-9-_.~` are unreserved; everything
    /// else is percent-encoded with uppercase hex (note `/` becomes `%2F`).
    package static func rfc3986(_ s: String) -> String {
        let unreserved = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~"
        var allowed = CharacterSet()
        allowed.insert(charactersIn: unreserved)
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    package static let defaultPost: Post = { url, body in
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AgentError.badResponse }
        return (data, http)
    }

    package init(baseURL: URL, post: @escaping Post = Self.defaultPost) {
        self.baseURL = baseURL
        self.post = post
    }
}
