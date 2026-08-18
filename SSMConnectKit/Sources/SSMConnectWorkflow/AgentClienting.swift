import Foundation
import SSMConnectDomain

/// The provisioned virtual session for the calling user (multi-user, R1/CL-02b).
public struct EnsureSessionResult: Decodable, Equatable, Sendable {
    public let sessionId: String
    public let user: String

    public init(sessionId: String, user: String) {
        self.sessionId = sessionId
        self.user = user
    }
}

/// Why the on-box workstation agent could not satisfy a request.
///
/// Declared with the port rather than with the HTTP adapter because the workflow branches on it:
/// `responded` is the retry decision. A transport failure while a freshly-opened tunnel settles is
/// worth retrying; a real answer from the agent is not, and retrying one would just repeat a
/// rejection the user needs to see.
public enum AgentError: Error, Equatable, LocalizedError {
    case unauthorized
    case provisioningFailed(status: Int)
    case badResponse

    /// Whether the agent itself answered. Only a transport failure is transient.
    public var responded: Bool {
        switch self {
        case .unauthorized, .provisioningFailed: true
        case .badResponse: false
        }
    }

    public var errorDescription: String? {
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

/// Calls the on-box multi-user workstation agent over its SSM-forwarded loopback port (R1/CL-02b).
///
/// Behind a protocol so the connection flow can be driven from a conformance fixture: the
/// `AgentClient` port of `contracts/state-machine.schema.json` maps onto this.
public protocol AgentClienting: Sendable {
    /// Ensure the caller's virtual session exists on the workstation, returning its id and owner.
    ///
    /// - Parameter port: the local end of the transient agent tunnel.
    func ensureSession(port: Int, authToken: String) async throws -> EnsureSessionResult
}
