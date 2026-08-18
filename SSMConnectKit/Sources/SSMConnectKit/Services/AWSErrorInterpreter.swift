import ClientRuntime
import Foundation
import Smithy
import SmithyHTTPAPI

/// Renders and classifies errors the connection flow does not model itself (MR-06).
///
/// The workflow owns this protocol; only an AWS adapter implements it. That is the whole point:
/// inspecting `Smithy.ClientError` or an `UnknownAWSHTTPServiceError` requires the AWS SDK, and the
/// portable workflow must not import one (spec §5.2). Anything the flow *does* model — a bad
/// region, a terminated instance, a readiness miss — is classified without ever reaching here.
protocol ErrorInterpreting: Sendable {
    /// A human-readable message for an error with no `LocalizedError` conformance.
    func describe(_ error: Error) -> String

    /// The portable category for an error that is not a modelled domain error.
    func classify(_ error: Error) -> ErrorCategory
}

/// `ErrorInterpreting` for `aws-sdk-swift`.
///
/// AWS SDK errors are `Error`-only — no `LocalizedError`, no `CustomNSError` — so
/// `localizedDescription` drops their informative payload and yields opaque bridge strings like
/// "The operation couldn't be completed. (Smithy.ClientError error 4.)". Unwrapping them here is
/// what turns "error 4" into "Invalid region: …" (#20).
struct AWSErrorInterpreter: ErrorInterpreting {
    func describe(_ error: Error) -> String {
        // `Smithy.ClientError` carries its message in an associated value.
        if let clientError = error as? ClientError {
            return Self.message(from: clientError)
        }
        // Errors *returned by an AWS service* have the same problem one layer up. Any response
        // whose error shape is absent from the operation's Smithy model becomes an
        // `UnknownAWSHTTPServiceError`, which is likewise `Error`-only and bridges to the useless
        // "(AWSClientRuntime.UnknownAWSHTTPServiceError error 1.)" (#20). It does carry
        // `typeName`/`message`, so match the `ServiceError` protocol: that covers unmodeled and
        // modeled service errors alike, for every AWS API this app calls.
        if let serviceError = error as? ServiceError {
            return Self.message(from: serviceError, httpStatus: (error as? HTTPError)?.httpResponse.statusCode)
        }
        return error.localizedDescription
    }

    func classify(_ error: Error) -> ErrorCategory {
        // Deliberately not `.unknown` for SDK errors: an AWS-originated failure is attributable,
        // and `.unknown` is reserved for genuinely unmodelled ones so gaps stay visible.
        if error is ClientError || error is ServiceError {
            return .aws
        }
        return .unknown
    }

    /// Extract the human-readable payload from a `Smithy.ClientError` (all cases carry a `String`).
    private static func message(from error: ClientError) -> String {
        switch error {
        case let .serializationFailed(message),
             let .dataNotFound(message),
             let .unknownError(message),
             let .authError(message),
             let .invalidValue(message):
            return message
        }
    }

    /// Render an AWS service error as "<message> (<TypeName>, HTTP <status>)", degrading gracefully
    /// as fields are missing. The type name and status are what make an otherwise generic message
    /// ("No access") actionable in a bug report.
    static func message(from error: ServiceError, httpStatus: HTTPStatusCode?) -> String {
        let detail = [error.typeName, httpStatus.map { "HTTP \($0.rawValue)" }]
            .compactMap { $0 }
            .joined(separator: ", ")
        let summary = error.message ?? error.typeName.map { "AWS returned a \($0)." }
            ?? "AWS returned an unrecognized error."
        guard !detail.isEmpty, error.message != nil else { return summary }
        return "\(summary) (\(detail))"
    }
}
