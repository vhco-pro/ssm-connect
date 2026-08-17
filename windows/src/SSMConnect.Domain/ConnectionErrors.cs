namespace SSMConnect.Domain;

/// <summary>
/// Terminal failure classification. AC-04 requires both clients to agree on this, not on message
/// wording, so this — never a message string — is what the conformance fixtures assert.
/// </summary>
public enum ErrorCategory
{
    None,
    Configuration,
    Authentication,
    InstanceTerminated,
    Timeout,
    Tunnel,
    Readiness,
    Agent,
    Aws,
    Unknown,
}

/// <summary>Base type for failures the workflow raises or classifies itself.</summary>
public abstract class ConnectionException(string message, Exception? inner = null)
    : Exception(message, inner)
{
    public abstract ErrorCategory Category { get; }
}

/// <summary>
/// A profile is misconfigured in a way detectable before any AWS call. Naming the field and the
/// offending value is the whole point: without it the SDK surfaces an opaque client error instead.
/// </summary>
public sealed class ProfileConfigurationException(string field, string value)
    : ConnectionException(
        $"The {field} \"{value}\" is not a valid AWS region. " +
        "Set a valid region such as eu-central-1 in Settings.")
{
    public string Field { get; } = field;

    public string Value { get; } = value;

    public override ErrorCategory Category => ErrorCategory.Configuration;
}

/// <summary>No usable credentials are held and interactive sign-in has not run.</summary>
public sealed class SignInRequiredException()
    : ConnectionException("Sign-in is required before connecting.")
{
    public override ErrorCategory Category => ErrorCategory.Authentication;
}

/// <summary>
/// The credentials in hand have expired. The workflow catches this specifically, re-authenticates,
/// and retries the failed step without tearing down an active tunnel.
/// </summary>
public sealed class ExpiredCredentialsException(Exception? inner = null)
    : ConnectionException("The AWS session has expired.", inner)
{
    public override ErrorCategory Category => ErrorCategory.Authentication;
}

/// <summary>The workstation is terminated or shutting down and cannot be connected to.</summary>
public sealed class InstanceTerminatedException(string instanceId)
    : ConnectionException($"Workstation {instanceId} is terminated and cannot be started.")
{
    public string InstanceId { get; } = instanceId;

    public override ErrorCategory Category => ErrorCategory.InstanceTerminated;
}

/// <summary>A connection stage exceeded its timeout budget.</summary>
public sealed class StageTimeoutException(string stage)
    : ConnectionException($"{stage} timed out.")
{
    public string Stage { get; } = stage;

    public override ErrorCategory Category => ErrorCategory.Timeout;
}

/// <summary>The tunnel could not be established or dropped and could not be re-established.</summary>
public sealed class TunnelException(string message, Exception? inner = null)
    : ConnectionException(message, inner)
{
    public override ErrorCategory Category => ErrorCategory.Tunnel;
}

/// <summary>
/// The forwarded endpoint was not usable. The two cases are kept distinct because they point the
/// user at different problems: nothing listening locally, versus a listener whose server is silent.
/// </summary>
public sealed class DcvReadinessException : ConnectionException
{
    private DcvReadinessException(string message, bool tunnelEstablished)
        : base(message) => TunnelEstablished = tunnelEstablished;

    public bool TunnelEstablished { get; }

    public override ErrorCategory Category => ErrorCategory.Readiness;

    /// <summary>Nothing is listening on the local port: the port-forward never came up.</summary>
    public static DcvReadinessException TunnelNotEstablished(int port) =>
        new($"The tunnel on port {port} is not accepting connections.", tunnelEstablished: false);

    /// <summary>The port is listening but the in-instance DCV server never answered.</summary>
    public static DcvReadinessException DcvServerNotReady(int port) =>
        new($"The workstation's DCV server did not respond on port {port}.", tunnelEstablished: true);
}

/// <summary>
/// The workstation agent rejected or could not satisfy the request. A multi-user host is
/// identity-only, so this never falls back to a shared user.
/// </summary>
public sealed class AgentException(string message, bool responded, Exception? inner = null)
    : ConnectionException(message, inner)
{
    /// <summary>
    /// Whether the agent itself answered. A real response is not transient and must not be retried;
    /// a transport failure while the freshly opened tunnel settles is.
    /// </summary>
    public bool Responded { get; } = responded;

    public override ErrorCategory Category => ErrorCategory.Agent;
}

/// <summary>An AWS service returned an error the workflow does not handle specially.</summary>
public sealed class AwsServiceException(string message, Exception? inner = null)
    : ConnectionException(message, inner)
{
    public override ErrorCategory Category => ErrorCategory.Aws;
}

public static class ErrorCategories
{
    private static readonly Dictionary<ErrorCategory, string> ToWire = new()
    {
        [ErrorCategory.None] = "none",
        [ErrorCategory.Configuration] = "configuration",
        [ErrorCategory.Authentication] = "authentication",
        [ErrorCategory.InstanceTerminated] = "instanceTerminated",
        [ErrorCategory.Timeout] = "timeout",
        [ErrorCategory.Tunnel] = "tunnel",
        [ErrorCategory.Readiness] = "readiness",
        [ErrorCategory.Agent] = "agent",
        [ErrorCategory.Aws] = "aws",
        [ErrorCategory.Unknown] = "unknown",
    };

    public static string Wire(this ErrorCategory category) => ToWire[category];

    /// <summary>
    /// Classifies any exception. Anything not modelled as a <see cref="ConnectionException"/>
    /// is <see cref="ErrorCategory.Unknown"/> rather than silently becoming an AWS error.
    /// </summary>
    public static ErrorCategory Classify(Exception error) =>
        error is ConnectionException connection ? connection.Category : ErrorCategory.Unknown;
}
