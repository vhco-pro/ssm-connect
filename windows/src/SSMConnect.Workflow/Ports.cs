using SSMConnect.Domain;

namespace SSMConnect.Workflow;

/// <summary>Temporary AWS credentials. Held in memory only, never persisted.</summary>
public sealed record AwsCredentials(
    string AccessKeyId,
    string SecretAccessKey,
    string SessionToken,
    DateTimeOffset? Expiration);

/// <summary>An SSM port-forward session, as returned by StartSession.</summary>
public sealed record SsmSession(string SessionId, string StreamUrl = "", string TokenValue = "");

/// <summary>Why a tunnel stopped.</summary>
public abstract record TunnelDropReason
{
    /// <summary>Normal teardown driven by the client. Not a failure.</summary>
    public sealed record TerminatedByUser : TunnelDropReason;

    /// <summary>The plugin process exited on its own.</summary>
    public sealed record ProcessExited(int ExitCode, string StandardError) : TunnelDropReason;
}

/// <summary>A running tunnel. Terminating it is the adapter's job; the workflow only signals when.</summary>
public interface ITunnelHandle
{
    int ProcessId { get; }

    /// <summary>Completes when the tunnel stops, with the reason.</summary>
    Task<TunnelDropReason> Dropped { get; }

    Task TerminateAsync();
}

/// <summary>Reuse, refresh, or obtain AWS IAM Identity Center credentials.</summary>
public interface IAuthProvider
{
    Task<AwsCredentials> AuthenticateAsync(ConnectionProfile profile, CancellationToken cancellationToken);
}

/// <summary>Resolve, start, stop, and poll the workstation instance.</summary>
public interface IEc2Provider
{
    Task<Ec2Instance> ResolveInstanceAsync(string tagKey, string tagValue, string region, AwsCredentials credentials, CancellationToken cancellationToken);

    Task StartInstanceAsync(string instanceId, string region, AwsCredentials credentials, CancellationToken cancellationToken);

    Task<Ec2Instance> PollUntilRunningAsync(string instanceId, string region, AwsCredentials credentials, TimeSpan timeout, TimeSpan interval, CancellationToken cancellationToken);

    Task StopInstanceAsync(string instanceId, string region, AwsCredentials credentials, CancellationToken cancellationToken);
}

/// <summary>Poll managed-instance readiness, and start SSM sessions.</summary>
public interface ISsmProvider
{
    Task WaitForSsmOnlineAsync(string instanceId, string region, AwsCredentials credentials, TimeSpan timeout, TimeSpan interval, CancellationToken cancellationToken);

    Task<SsmSession> StartSessionAsync(string instanceId, string region, AwsCredentials credentials, int localPort, int remotePort, CancellationToken cancellationToken);

    /// <summary>
    /// Terminates sessions this caller previously left open against the target, returning how many.
    /// </summary>
    /// <remarks>
    /// Measured against real AWS: a hard-killed client leaves its session reported as Connected.
    /// Local process containment reaps the plugin but tells AWS nothing, so without this a crash
    /// leaks a session until it times out. It MUST terminate only sessions this caller owns.
    /// </remarks>
    Task<int> ReapOrphanedSessionsAsync(string instanceId, string region, AwsCredentials credentials, CancellationToken cancellationToken);

    /// <summary>Closes a session server-side. Best effort: the reap is the backstop.</summary>
    Task TerminateSessionAsync(string sessionId, string region, AwsCredentials credentials, CancellationToken cancellationToken);
}

/// <summary>Retrieve the single-user DCV password.</summary>
public interface ISecretsProvider
{
    Task<string> FetchSecretAsync(string secretId, string region, AwsCredentials credentials, CancellationToken cancellationToken);
}

/// <summary>Resolve caller identity and mint fresh presigned identity tokens.</summary>
public interface IIdentityProvider
{
    /// <summary>Resolves the caller's AWS identity to the Linux username the workstation expects.</summary>
    Task<string> ResolveIdentityAsync(string region, AwsCredentials credentials, CancellationToken cancellationToken);

    /// <summary>
    /// Mints a presigned identity token. Called fresh per attempt rather than cached, because a
    /// presigned URL expires and a stale one fails the agent's verifier.
    /// </summary>
    string PresignedIdentityToken(string region, AwsCredentials credentials);
}

/// <summary>The provisioned virtual session for the calling user.</summary>
public sealed record EnsureSessionResult(string User, string SessionId);

/// <summary>Call the multi-user workstation agent through its transient tunnel.</summary>
public interface IAgentClient
{
    Task<EnsureSessionResult> EnsureSessionAsync(int port, string authToken, CancellationToken cancellationToken);
}

/// <summary>Validate plugin availability and manage a port-forward child process.</summary>
public interface ITunnelProvider
{
    Task<ITunnelHandle> StartTunnelAsync(SsmSession session, string region, string instanceId, int localPort, int remotePort, CancellationToken cancellationToken);
}

/// <summary>Test the forwarded DCV endpoint and classify failures.</summary>
public interface IReadinessProbe
{
    /// <summary>Polls the endpoint until it answers or the budget expires.</summary>
    Task<bool> WaitUntilReadyAsync(int port, TimeSpan timeout, TimeSpan interval, CancellationToken cancellationToken);

    /// <summary>
    /// One quick TCP check, used only to explain a readiness miss: nothing listening means the
    /// tunnel never came up, a listener means the DCV server is silent.
    /// </summary>
    Task<bool> IsListeningAsync(int port, TimeSpan timeout, CancellationToken cancellationToken);
}

/// <summary>Materialise, launch, and clean a secure DCV connection file.</summary>
public interface IDcvLauncher
{
    bool IsViewerInstalled();

    Task LaunchAsync(DcvConnectionFile file, CancellationToken cancellationToken);

    /// <summary>Removes connection files this application owns and left behind.</summary>
    void SweepOrphanedFiles();
}

/// <summary>Remember the non-secret last instance ID, for replacement detection.</summary>
public interface IInstanceIdStore
{
    string? LastInstanceId(Guid profileId);

    void SetLastInstanceId(Guid profileId, string instanceId);
}

/// <summary>Deterministic delays. Injected so conformance fixtures never wait on a real clock.</summary>
public interface IDelay
{
    Task WaitAsync(TimeSpan duration, CancellationToken cancellationToken);
}

/// <summary>Lifecycle events the shell reacts to. The workflow publishes; it never acts on the OS.</summary>
public enum ConnectionNotification
{
    Connected,
    Reconnecting,
    Stopped,
    SignInRequired,
}

/// <summary>
/// Wire names for the notification vocabulary. These are contract: both clients emit the same
/// sequence for the same run, so conformance fixtures assert them.
/// </summary>
public static class NotificationNames
{
    public static string Wire(ConnectionNotification notification) => notification switch
    {
        ConnectionNotification.Connected => "connected",
        ConnectionNotification.Reconnecting => "reconnecting",
        ConnectionNotification.Stopped => "stopped",
        ConnectionNotification.SignInRequired => "signInRequired",
        _ => throw new ArgumentOutOfRangeException(nameof(notification), notification, null),
    };
}

/// <summary>
/// Publishes state snapshots, log lines, and notification-worthy events. Clipboard, notifications,
/// browser launch, and shutdown are shell policy driven by these events, never done here.
/// </summary>
public interface IEventSink
{
    void StateChanged(ConnectionState state);

    void Log(string category, string message);

    void Notify(ConnectionNotification notification);

    /// <summary>
    /// Surfaces the retrieved DCV password to the shell, which decides clipboard policy. Called
    /// only for single-user connections.
    /// </summary>
    void PasswordAvailable(string password);
}
