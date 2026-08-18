import Foundation
@testable import SSMConnectDomain
@testable import SSMConnectWorkflow
@testable import SSMConnectAWS
@testable import SSMConnectMacOS
@testable import SSMConnectUI

/// One recorded call to an injected port.
struct RecordedCall: CustomStringConvertible {
    let port: String
    let method: String
    let arguments: [String: JSONValue]

    var description: String { "\(port).\(method)" }
}

/// Records every port call and serves the outcome queue the fixture declared for it.
///
/// The queue semantics are part of the contract, not an implementation detail: each entry is
/// consumed by one call and the last entry repeats, which is how a fixture says "fails once, then
/// succeeds" with no scripting.
final class PortRecorder: @unchecked Sendable {
    private let ports: [String: [String: [Outcome]]]
    private let lock = NSLock()
    private var consumed: [String: Int] = [:]
    private var recorded: [RecordedCall] = []

    init(given: Given) { self.ports = given.ports }

    var calls: [RecordedCall] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func count(port: String, method: String) -> Int {
        calls.filter { $0.port == port && $0.method == method }.count
    }

    /// Record a call and return the declared result, throwing if the fixture declared an error.
    @discardableResult
    func invoke(_ port: String, _ method: String, _ arguments: [String: JSONValue] = [:]) throws -> JSONValue? {
        lock.lock()
        recorded.append(RecordedCall(port: port, method: method, arguments: arguments))
        let key = "\(port).\(method)"
        let index = consumed[key] ?? 0
        consumed[key] = index + 1
        lock.unlock()

        guard let queue = ports[port]?[method], !queue.isEmpty else { return nil }
        let outcome = queue[min(index, queue.count - 1)]
        if let error = outcome.error { throw Self.error(from: error) }
        return outcome.result
    }

    /// Maps a portable error kind onto the Swift error the flow actually catches. The fixture never
    /// names a platform type, so this mapping is the entire translation layer — and getting it
    /// wrong here silently changes which code path a case exercises.
    static func error(from declared: OutcomeError) -> Error {
        switch declared.kind {
        case "expiredCredentials":
            // Deliberately a real unmodeled AWS service error carrying `ExpiredTokenException`,
            // so the *shipping* `defaultExpiredCredentialsCheck` predicate is what recognises it.
            // A bespoke sentinel would have proved only that the harness agrees with itself.
            return unmodeledAWSServiceError(
                typeName: "ExpiredTokenException",
                message: declared.message ?? "The security token included in the request is expired",
                statusCode: .forbidden
            )
        case "signInRequired":
            return AuthError.signInRequired
        case "invalidRegion":
            return ProfileConfigError.invalidRegion(field: "resource region", value: declared.message ?? "")
        case "instanceTerminated":
            return EC2Error.instanceTerminated(instanceId: declared.message ?? "i-unknown")
        case "stageTimeout":
            return StageTimeoutError(stage: declared.message ?? "Stage")
        case "localPortInUse":
            return TunnelError.localPortInUse(port: 8443, pid: nil, processName: nil)
        case "tunnelNotEstablished":
            return DCVReadinessError.tunnelNotEstablished(port: 8443)
        case "dcvServerNotReady":
            return DCVReadinessError.dcvServerNotReady(port: 8443)
        case "agentUnauthorized":
            return AgentError.unauthorized
        case "agentUnreachable":
            // A transport failure, NOT an `AgentError`: the flow retries this while the freshly
            // opened agent tunnel settles, and treats a real agent response as final.
            return URLError(.cannotConnectToHost)
        case "viewerNotInstalled":
            return DCVError.viewerNotInstalled
        case "awsServiceError":
            return unmodeledAWSServiceError(
                typeName: "ServiceUnavailableException",
                message: declared.message ?? "AWS returned an error.",
                statusCode: .serviceUnavailable
            )
        default:
            return DCVError.launchFailed(reason: declared.message ?? "Unknown failure.")
        }
    }
}
