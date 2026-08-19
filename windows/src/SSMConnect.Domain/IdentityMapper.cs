namespace SSMConnect.Domain;

/// <summary>The caller's identity could not be mapped to a workstation username.</summary>
public sealed class IdentityMappingException(string message) : ConnectionException(message)
{
    public override ErrorCategory Category => ErrorCategory.Authentication;

    public static IdentityMappingException NoRoleSessionName() =>
        new("Couldn't read your identity from AWS.");

    public static IdentityMappingException UnsafeUsername() =>
        new("Your identity doesn't map to a valid workstation username.");

    public static IdentityMappingException ReservedUsername() =>
        new("Your identity maps to a reserved system username.");
}

/// <summary>
/// Maps a verified AWS caller identity (an STS ARN) to a Linux username.
/// </summary>
/// <remarks>
/// This rule MUST stay byte-for-byte identical to the macOS client's <c>IdentityMapper</c> and to
/// the workstation agent's Go rule. The client targets the DCV session named after the user and the
/// agent authorizes by the same name, so any divergence denies a validated user their own session.
/// <para>
/// The mapping is <b>reject-based, not transform-based</b>. It refuses any role-session name that
/// does not already reduce — lowercase, drop the email domain — to a safe unambiguous username,
/// rather than deleting characters or truncating. Either of those could merge two distinct
/// identities onto one account. Reserved and system names are refused outright.
/// </para>
/// </remarks>
public static class IdentityMapper
{
    /// <summary>Usernames that must never be mapped to. Mirrors the agent's list exactly.</summary>
    public static IReadOnlySet<string> Reserved { get; } = new HashSet<string>(StringComparer.Ordinal)
    {
        "root", "daemon", "bin", "sys", "sync", "games", "man", "lp", "mail", "news",
        "proxy", "www-data", "backup", "list", "nobody", "systemd-network", "dbus",
        "sshd", "rpc", "dcv", "dcvsmagent", "ec2-user", "ssm-user", "admin", "ubuntu", "centos",
    };

    /// <summary>
    /// Extracts the role-session name — the segment after the last slash of an assumed-role ARN —
    /// and maps it to a Linux username.
    /// </summary>
    public static string UsernameFromArn(string arn)
    {
        int slash = arn.LastIndexOf('/');
        if (slash < 0 || slash == arn.Length - 1)
        {
            throw IdentityMappingException.NoRoleSessionName();
        }

        return Sanitize(arn[(slash + 1)..]);
    }

    /// <summary>
    /// Reduces a raw SSO username to a Linux username and validates it. Reduction is minimal and
    /// lossless-or-reject: take the local part before any <c>@</c> and lowercase it. The result must
    /// match <c>^[a-z][a-z0-9_-]{0,31}$</c> and must not be reserved, otherwise it is rejected.
    /// </summary>
    public static string Sanitize(string raw)
    {
        string value = raw;
        int at = value.IndexOf('@', StringComparison.Ordinal);
        if (at >= 0)
        {
            value = value[..at];
        }

        value = value.ToLowerInvariant();

        if (!IsSafeName(value))
        {
            throw IdentityMappingException.UnsafeUsername();
        }

        if (Reserved.Contains(value))
        {
            throw IdentityMappingException.ReservedUsername();
        }

        return value;
    }

    private static bool IsSafeName(string value)
    {
        if (value.Length is < 1 or > 32)
        {
            return false;
        }

        if (!char.IsAsciiLetterLower(value[0]))
        {
            return false;
        }

        foreach (char character in value)
        {
            if (!char.IsAsciiLetterLower(character) && !char.IsAsciiDigit(character)
                && character != '-' && character != '_')
            {
                return false;
            }
        }

        return true;
    }
}
