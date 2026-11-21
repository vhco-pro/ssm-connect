// The aws-sdk-swift implementation, used on macOS until T36 switches it to SSM Connect's client.
#if os(macOS)
import ClientRuntime
import Foundation
import Smithy
import SmithyHTTPAPI

/// User-facing text for the AWS SDK's own error types.
package enum SDKErrorText {
    package static func message(for error: Error) -> String? {
        // AWS SDK errors like `Smithy.ClientError` are `Error`-only (no `LocalizedError` /
        // `CustomNSError`), so `localizedDescription` would drop their informative payload and
        // yield the opaque bridge string "The operation couldn't be completed. (Smithy.ClientError
        // error 4.)". Surface the associated message instead so, e.g., a region rejection reads
        // "Invalid region: ..." rather than "error 4".
        if let clientError = error as? ClientError {
            return message(from: clientError)
        }
        // Errors *returned by an AWS service* have the same problem one layer up. Any response
        // whose error shape is absent from the operation's Smithy model becomes an
        // `UnknownAWSHTTPServiceError`, which is likewise `Error`-only and bridges to the
        // useless "(AWSClientRuntime.UnknownAWSHTTPServiceError error 1.)" (#20). It does carry
        // `typeName`/`message`, so match the `ServiceError` protocol: that covers unmodeled and
        // modeled service errors alike, for every AWS API this app calls.
        if let serviceError = error as? ServiceError {
            return AWSErrorText.message(typeName: serviceError.typeName, message: serviceError.message,
                                        httpStatus: (error as? HTTPError)?.httpResponse.statusCode.rawValue)
        }
        return nil
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
}
#endif
