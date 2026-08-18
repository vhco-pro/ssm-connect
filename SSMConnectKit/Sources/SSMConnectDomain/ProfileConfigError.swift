import Foundation

/// Errors raised when a connection profile is misconfigured in a way we can catch before any
/// AWS SDK call. Keeping these as a typed `LocalizedError` means `ConnectionStateMachine.fail(_:)`
/// surfaces an actionable message (naming the field and the offending value) instead of the
/// opaque SDK bridge string `Smithy.ClientError error 4`.
public enum ProfileConfigError: LocalizedError, Equatable {
    /// A region field (`resource region` / `SSO region`) is empty or malformed. `field` is a
    /// human-readable label; `value` is the offending raw value (empty shown as `""`).
    case invalidRegion(field: String, value: String)

    public var errorDescription: String? {
        switch self {
        case let .invalidRegion(field, value):
            let shown = value.isEmpty ? "\"\"" : "\"\(value)\""
            return "The \(field) \(shown) is not a valid AWS region. "
                + "Set a valid region such as eu-central-1 in Settings."
        }
    }
}
