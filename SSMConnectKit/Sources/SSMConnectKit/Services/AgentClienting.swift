import Foundation

/// Calls the on-box multi-user workstation agent over its SSM-forwarded loopback port (R1/CL-02b).
///
/// Behind a protocol so the connection flow can be driven from a conformance fixture: the
/// `AgentClient` port of `contracts/state-machine.schema.json` maps onto this. The concrete
/// `WorkstationAgentClient` stays the production implementation and keeps owning the wire format.
protocol AgentClienting: Sendable {
    /// Ensure the caller's virtual session exists on the workstation, returning its id and owner.
    ///
    /// - Parameter port: the local end of the transient agent tunnel.
    func ensureSession(port: Int, authToken: String) async throws -> WorkstationAgentClient.EnsureSessionResult
}

/// Production `AgentClienting`: one `WorkstationAgentClient` per call, pointed at the loopback
/// port the transient agent tunnel is forwarding.
struct HTTPAgentClient: AgentClienting {
    func ensureSession(port: Int, authToken: String) async throws -> WorkstationAgentClient.EnsureSessionResult {
        // Force-unwrap is safe: the string is a fixed loopback URL with an integer port.
        let client = WorkstationAgentClient(baseURL: URL(string: "http://127.0.0.1:\(port)")!)
        return try await client.ensureSession(authToken: authToken)
    }
}
