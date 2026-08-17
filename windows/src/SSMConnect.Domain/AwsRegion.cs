using System.Text.RegularExpressions;

namespace SSMConnect.Domain;

/// <summary>
/// Single source of truth for AWS region string rules, kept byte-for-byte aligned with the AWS
/// SDK's own validator so the client never drifts from what the SDK accepts.
/// </summary>
/// <remarks>
/// The SDK validates a region against this pattern and rejects a miss with an opaque client error.
/// Validating up front — in the profile editor and again as a pre-flight guard before any SDK call
/// — turns that into an actionable message naming the offending field.
/// <para>
/// <see cref="IsValid"/> evaluates the raw string, so <c>" eu-central-1 "</c> is invalid. Callers
/// that want to tolerate surrounding whitespace call <see cref="Normalize"/> first.
/// </para>
/// </remarks>
public static partial class AwsRegion
{
    [GeneratedRegex(@"^(?!.*-$)(?!-)[a-zA-Z0-9-]{1,63}$")]
    private static partial Regex Pattern { get; }

    /// <summary>Trims leading and trailing whitespace. Does not otherwise alter the value.</summary>
    public static string Normalize(string value) => value.Trim();

    /// <summary>Whether the value is a syntactically valid AWS region per the SDK's own rule.</summary>
    public static bool IsValid(string? value) => value is not null && Pattern.IsMatch(value);
}
