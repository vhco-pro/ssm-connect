namespace SSMConnect.Domain;

/// <summary>How a profile connects to its DCV workstation.</summary>
public enum ConnectMode
{
    /// <summary>Shared <c>ec2-user</c> plus a Secrets Manager password. The default.</summary>
    SingleUser,

    /// <summary>
    /// Per-user virtual sessions authenticated by a presigned identity token. A multi-user host is
    /// identity-only: there is deliberately no shared-user fallback.
    /// </summary>
    MultiUser,
}

/// <summary>What the client launches once the tunnel is up.</summary>
public enum ConnectAction
{
    DcvViewer,
}

/// <summary>
/// A named connection profile. Nothing about an environment is hardcoded in the client: account,
/// SSO endpoints, regions, instance tag, secret ID, and ports all live here.
/// </summary>
/// <remarks>
/// This type never carries credentials, tokens, secret values, or local file paths. That boundary
/// is also enforced structurally by <c>contracts/connection-profile.schema.json</c>.
/// </remarks>
public sealed record ConnectionProfile
{
    public required Guid Id { get; init; }
    public required string Name { get; init; }

    public required string SsoStartUrl { get; init; }
    public required string SsoRegion { get; init; }
    public required string AccountId { get; init; }
    public required string RoleName { get; init; }

    public required string ResourceRegion { get; init; }
    public required string InstanceTagKey { get; init; }
    public required string InstanceTagValue { get; init; }

    public required int LocalPort { get; init; }
    public required int RemotePort { get; init; }

    public ConnectAction ConnectAction { get; init; } = ConnectAction.DcvViewer;

    /// <summary>
    /// Null means single-user. Kept nullable rather than defaulted so a profile written before this
    /// field existed round-trips unchanged; <see cref="ResolvedConnectMode"/> is what callers use.
    /// </summary>
    public ConnectMode? ConnectMode { get; init; }

    /// <summary>Null means the default agent port. See <see cref="ResolvedAgentRemotePort"/>.</summary>
    public int? AgentRemotePort { get; init; }

    /// <summary>Secrets Manager secret ID for the DCV password. An identifier, never the value.</summary>
    public string? SecretId { get; init; }

    public const int DefaultAgentRemotePort = 8444;

    public ConnectMode ResolvedConnectMode => ConnectMode ?? Domain.ConnectMode.SingleUser;

    public int ResolvedAgentRemotePort => AgentRemotePort ?? DefaultAgentRemotePort;

    /// <summary>
    /// Whether the profile has the minimum fields needed to attempt a connection. Auto-connect is
    /// gated on this, because a fresh install ships with no usable profile.
    /// </summary>
    public bool IsConfigured =>
        !string.IsNullOrEmpty(SsoStartUrl)
        && AwsRegion.IsValid(SsoRegion)
        && !string.IsNullOrEmpty(AccountId)
        && !string.IsNullOrEmpty(RoleName)
        && AwsRegion.IsValid(ResourceRegion)
        && !string.IsNullOrEmpty(InstanceTagKey)
        && !string.IsNullOrEmpty(InstanceTagValue);
}

/// <summary>Global settings that influence the connection lifecycle.</summary>
public sealed record AppSettings
{
    /// <summary>Connect automatically at launch, for a fully configured profile only.</summary>
    public bool AutoConnect { get; init; }

    /// <summary>Re-establish the tunnel automatically if it drops unexpectedly.</summary>
    public bool AutoReconnect { get; init; } = true;

    /// <summary>Seconds before the clipboard clears after copying the DCV password. 0 disables.</summary>
    public int ClipboardAutoClearSeconds { get; init; } = 30;

    public static AppSettings Default { get; } = new();
}
