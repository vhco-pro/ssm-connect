import Foundation

/// Single source of truth for AWS region string rules, kept byte-for-byte aligned with the
/// AWS SDK's own region validator so the app never drifts from what the SDK will accept.
///
/// The SDK (`AWSClientRuntime` `EndpointResolverMiddleware`) validates the region against
/// `^(?!.*-$)(?!-)[a-zA-Z0-9-]{1,63}$` and throws `Smithy.ClientError.invalidValue` on a miss,
/// which surfaces to users as the opaque `Smithy.ClientError error 4`. We validate against the
/// same rule up-front (parser, editor, pre-flight connect guard) so a bad region is caught with
/// an actionable message before any SDK call.
///
/// `isValid(_:)` evaluates the raw string (so `" eu-central-1 "` is invalid); callers that want
/// to accept surrounding whitespace `normalize(_:)` first.
enum AWSRegion {
    /// The exact regex the AWS SDK uses to validate a region. Compiled once.
    private static let pattern = "^(?!.*-$)(?!-)[a-zA-Z0-9-]{1,63}$"
    private static let regex = try! NSRegularExpression(pattern: pattern)

    /// Trim leading/trailing whitespace and newlines. Does not otherwise alter the value.
    static func normalize(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whether `s` is a syntactically valid AWS region per the SDK's own rule. The raw string is
    /// evaluated as-is; leading/trailing whitespace makes it invalid.
    static func isValid(_ s: String) -> Bool {
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        return regex.firstMatch(in: s, range: range) != nil
    }
}
