import Foundation

/// Portable classification of a terminal failure (contract §6.2, AC-04).
///
/// The two clients are allowed to word an error differently — they have different UI, and the
/// macOS messages name macOS things. What they are *not* allowed to disagree on is what kind of
/// failure it was, because that is what drives the menu's recovery affordance ("Retry Connect" vs
/// "Open Settings") and what a conformance fixture asserts. So this enum, never a message string,
/// is the cross-platform contract.
///
/// Mirrors `SSMConnect.Domain.ErrorCategory` on the .NET side; the raw values are the wire strings
/// used in `contracts/state-machine.schema.json`.
enum ErrorCategory: String, Equatable, Sendable {
    /// No failure. The state machine's resting value.
    case none
    /// The profile is wrong in a way detectable before any AWS call (e.g. a malformed region).
    case configuration
    /// Sign-in is required, expired, or the account/role pair is refused.
    case authentication
    /// The workstation is terminated or shutting down and cannot be connected to.
    case instanceTerminated
    /// A stage exceeded its timeout budget.
    case timeout
    /// The tunnel could not be opened, or dropped and could not be re-established.
    case tunnel
    /// The forwarded endpoint never became usable before the viewer would have been launched.
    case readiness
    /// The multi-user workstation agent rejected or could not satisfy the request.
    case agent
    /// An AWS service returned an error the flow does not handle specially.
    case aws
    /// Anything unmodelled. Deliberately distinct from `aws` so an unclassified error is visible
    /// as a gap rather than silently attributed to AWS.
    case unknown
}

extension ErrorCategory {
    /// Classify an error the connection flow models itself.
    ///
    /// Returns `nil` for anything unrecognised, which the caller resolves through an injected
    /// `ErrorInterpreting`. That split is MR-06: identifying an AWS SDK error needs the SDK, and
    /// this type must stay importable by the portable workflow.
    static func classify(_ error: Error) -> ErrorCategory? {
        switch error {
        case is ProfileConfigError:
            return .configuration

        case is AuthError:
            return .authentication

        case let ec2 as EC2Error:
            // A terminated workstation is its own category: it is the one failure the user cannot
            // fix by retrying, and the menu says so.
            switch ec2 {
            case .instanceTerminated:
                return .instanceTerminated
            case .startTimedOut, .pendingStuck:
                return .timeout
            case .noMatchingInstance, .multipleMatchingInstances:
                return .configuration
            case .malformedResponse:
                return .aws
            }

        case let ssm as SSMError:
            // The agent never registering is a timeout against the §5 budget, not an AWS fault.
            switch ssm {
            case .notOnlineInTime:      return .timeout
            case .malformedSessionResponse: return .aws
            }

        case is StageTimeoutError:
            return .timeout

        case is TunnelError:
            return .tunnel

        case is DCVReadinessError:
            return .readiness

        case is WorkstationAgentClient.AgentError:
            return .agent

        case let identity as STSIdentityResolver.IdentityResolveError:
            // STS refusing the presigned identity request means the session is no longer good.
            switch identity {
            case .stsRejected:      return .authentication
            case .badURL, .noArn:   return .unknown
            }

        case is SecretsError, is DCVError:
            // Both are non-fatal in the shipping flow (they surface as a warning and keep the
            // tunnel up), so they are classified for completeness rather than for a terminal state.
            return error is SecretsError ? .aws : .unknown

        case is CancellationError:
            return .none

        default:
            // Not modelled here. An AWS SDK error lands in this branch and is resolved by the
            // injected interpreter, which is the only thing that may import the SDK.
            return nil
        }
    }
}
