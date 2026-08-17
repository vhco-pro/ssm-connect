namespace SSMConnect.Workflow;

/// <summary>
/// Per-stage timeout and retry budget. Every value is injected rather than constant so conformance
/// fixtures can collapse them and run without waiting on a real clock.
/// </summary>
public sealed record ConnectionTimeouts
{
    public TimeSpan Authenticate { get; init; } = TimeSpan.FromMinutes(5);

    public TimeSpan Resolve { get; init; } = TimeSpan.FromSeconds(30);

    public TimeSpan Start { get; init; } = TimeSpan.FromMinutes(5);

    public TimeSpan StartPollInterval { get; init; } = TimeSpan.FromSeconds(5);

    public TimeSpan Ssm { get; init; } = TimeSpan.FromMinutes(3);

    public TimeSpan SsmPollInterval { get; init; } = TimeSpan.FromSeconds(5);

    public TimeSpan Tunnel { get; init; } = TimeSpan.FromSeconds(30);

    /// <summary>
    /// How long to wait for the in-instance DCV server after the tunnel is up. An online SSM agent
    /// does not imply a ready DCV server.
    /// </summary>
    public TimeSpan DcvReady { get; init; } = TimeSpan.FromSeconds(30);

    public TimeSpan DcvReadyPollInterval { get; init; } = TimeSpan.FromSeconds(1);

    /// <summary>Budget for the TCP listen check used to classify a readiness miss.</summary>
    public TimeSpan TunnelListen { get; init; } = TimeSpan.FromSeconds(3);

    /// <summary>
    /// How many times to tear down and re-establish the tunnel on a readiness miss before
    /// surfacing the error. 2 means 3 tunnel attempts in total.
    /// </summary>
    public int EstablishRetryAttempts { get; init; } = 2;

    /// <summary>Base backoff between re-establish attempts, multiplied by the attempt number.</summary>
    public TimeSpan EstablishRetryBackoff { get; init; } = TimeSpan.FromSeconds(2);

    public int MaxReconnectAttempts { get; init; } = 3;

    public TimeSpan ReconnectBackoff { get; init; } = TimeSpan.FromSeconds(5);

    /// <summary>
    /// Attempts at the agent's ensure-session call while a freshly opened tunnel settles. The call
    /// is idempotent, so retrying a transport failure is safe.
    /// </summary>
    public int EnsureSessionAttempts { get; init; } = 15;

    public TimeSpan EnsureSessionRetryDelay { get; init; } = TimeSpan.FromSeconds(1);

    public static ConnectionTimeouts Default { get; } = new();
}
