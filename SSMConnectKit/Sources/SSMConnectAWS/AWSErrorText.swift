import Foundation
import SSMConnectAWSClient

/// The app's rendering of an error an AWS service returned, shared by the SDK path (macOS until
/// T36) and SSM Connect's own client: "<message> (<TypeName>, HTTP <status>)", degrading
/// gracefully as fields are missing. The type name and status are what make an otherwise
/// generic message ("No access") actionable in a bug report.
package enum AWSErrorText {
    package static func message(typeName: String?, message: String?, httpStatus: Int?) -> String {
        let detail = [typeName, httpStatus.map { "HTTP \($0)" }]
            .compactMap { $0 }
            .joined(separator: ", ")
        let summary = message ?? typeName.map { "AWS returned a \($0)." }
            ?? "AWS returned an unrecognized error."
        guard !detail.isEmpty, message != nil else { return summary }
        return "\(summary) (\(detail))"
    }

    /// The message for an error from SSM Connect's AWS client, or nil for any other error.
    package static func message(for error: Error) -> String? {
        guard let error = error as? AWSServiceError else { return nil }
        return message(typeName: error.typeName, message: error.message, httpStatus: error.httpStatus)
    }
}
