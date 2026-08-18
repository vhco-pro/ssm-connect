import Foundation
import SSMConnectDomain

/// Renders and classifies errors the connection flow does not model itself (MR-06).
///
/// The workflow owns this protocol; only an adapter implements it. That is the whole point:
/// inspecting `Smithy.ClientError` or an `UnknownAWSHTTPServiceError` requires the AWS SDK, and the
/// portable workflow must not import one (spec §5.2). Anything the flow *does* model — a bad
/// region, a terminated instance, a readiness miss — is classified without ever reaching here.
public protocol ErrorInterpreting: Sendable {
    /// A human-readable message for an error with no `LocalizedError` conformance.
    func describe(_ error: Error) -> String

    /// The portable category for an error that is not a modelled domain error.
    func classify(_ error: Error) -> ErrorCategory
}

/// The portable fallback: no SDK knowledge, so it can only report what `Foundation` already knows.
///
/// This is the default so the workflow is usable — and testable — without an AWS adapter present.
/// Production wires `AWSErrorInterpreter` instead, which is what turns an opaque
/// "Smithy.ClientError error 4" into an actionable message.
public struct DefaultErrorInterpreter: ErrorInterpreting {
    public init() {}

    public func describe(_ error: Error) -> String { error.localizedDescription }

    /// Deliberately `.unknown` rather than `.aws`: this interpreter cannot tell whether an error
    /// came from AWS, and guessing would hide the gap that the real interpreter is there to close.
    public func classify(_ error: Error) -> ErrorCategory { .unknown }
}
