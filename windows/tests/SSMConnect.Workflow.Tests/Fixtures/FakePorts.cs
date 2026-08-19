using System.Text.Json;
using SSMConnect.Domain;

namespace SSMConnect.Workflow.Tests.Fixtures;

/// <summary>
/// Fake implementations of every port, driven entirely by the fixture's declared outcomes. They
/// contain no behavior of their own beyond honouring cancellation, so a fixture's expectations
/// describe the workflow and nothing else.
/// </summary>
internal static class FakeJson
{
    public static string String(JsonElement? element, string fallback = "") =>
        element is { ValueKind: JsonValueKind.String } value ? value.GetString() ?? fallback : fallback;

    public static bool Bool(JsonElement? element, bool fallback = false) => element?.ValueKind switch
    {
        JsonValueKind.True => true,
        JsonValueKind.False => false,
        _ => fallback,
    };

    public static string Property(JsonElement? element, string name, string fallback = "") =>
        element is { ValueKind: JsonValueKind.Object } obj && obj.TryGetProperty(name, out JsonElement value)
            ? value.ValueKind == JsonValueKind.String ? value.GetString() ?? fallback : value.ToString()
            : fallback;

    public static int Int(JsonElement? element, string name, int fallback) =>
        element is { ValueKind: JsonValueKind.Object } obj &&
        obj.TryGetProperty(name, out JsonElement value) &&
        value.TryGetInt32(out int parsed)
            ? parsed
            : fallback;
}

internal sealed class FakeAuthProvider(PortRecorder recorder) : IAuthProvider
{
    public Task<AwsCredentials> AuthenticateAsync(ConnectionProfile profile, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        recorder.Invoke("AuthProvider", "authenticate", ("profileId", profile.Id));
        return Task.FromResult(new AwsCredentials(
            "ASIASYNTHETICEXAMPLE", "synthetic-secret", "synthetic-session-token",
            DateTimeOffset.UnixEpoch.AddYears(60)));
    }
}

internal sealed class FakeEc2Provider(PortRecorder recorder) : IEc2Provider
{
    public Task<Ec2Instance> ResolveInstanceAsync(
        string tagKey, string tagValue, string region, AwsCredentials credentials, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        JsonElement? result = recorder.Invoke(
            "EC2Provider", "resolveInstance",
            ("tagKey", tagKey), ("tagValue", tagValue), ("region", region));
        return Task.FromResult(new Ec2Instance(
            FakeJson.Property(result, "id", "i-unknown"),
            Ec2InstanceStateNames.Parse(FakeJson.Property(result, "state", "running"))));
    }

    public Task StartInstanceAsync(string instanceId, string region, AwsCredentials credentials, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        recorder.Invoke("EC2Provider", "startInstance", ("instanceId", instanceId), ("region", region));
        return Task.CompletedTask;
    }

    public Task<Ec2Instance> PollUntilRunningAsync(
        string instanceId, string region, AwsCredentials credentials,
        TimeSpan timeout, TimeSpan interval, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        JsonElement? result = recorder.Invoke("EC2Provider", "pollUntilRunning", ("instanceId", instanceId));
        return Task.FromResult(new Ec2Instance(
            FakeJson.Property(result, "id", instanceId),
            Ec2InstanceStateNames.Parse(FakeJson.Property(result, "state", "running"))));
    }

    public Task StopInstanceAsync(string instanceId, string region, AwsCredentials credentials, CancellationToken cancellationToken)
    {
        recorder.Invoke("EC2Provider", "stopInstance", ("instanceId", instanceId), ("region", region));
        return Task.CompletedTask;
    }
}

internal sealed class FakeSsmProvider(PortRecorder recorder) : ISsmProvider
{
    public Task WaitForSsmOnlineAsync(
        string instanceId, string region, AwsCredentials credentials,
        TimeSpan timeout, TimeSpan interval, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        recorder.Invoke("SSMProvider", "waitForSSMOnline", ("instanceId", instanceId), ("region", region));
        return Task.CompletedTask;
    }

    public Task<SsmSession> StartSessionAsync(
        string instanceId, string region, AwsCredentials credentials,
        int localPort, int remotePort, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        JsonElement? result = recorder.Invoke(
            "SSMProvider", "startSession",
            ("instanceId", instanceId), ("region", region), ("localPort", localPort), ("remotePort", remotePort));
        return Task.FromResult(new SsmSession(FakeJson.Property(result, "sessionId", "synthetic-session")));
    }

    public Task<int> ReapOrphanedSessionsAsync(
        string instanceId, string region, AwsCredentials credentials, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        JsonElement? result = recorder.Invoke("SSMProvider", "reapOrphanedSessions", ("instanceId", instanceId));
        return Task.FromResult(result is { ValueKind: JsonValueKind.Number } value ? value.GetInt32() : 0);
    }

    public Task TerminateSessionAsync(
        string sessionId, string region, AwsCredentials credentials, CancellationToken cancellationToken)
    {
        recorder.Invoke("SSMProvider", "terminateSession", ("sessionId", sessionId));
        return Task.CompletedTask;
    }
}

internal sealed class FakeSecretsProvider(PortRecorder recorder) : ISecretsProvider
{
    public Task<string> FetchSecretAsync(string secretId, string region, AwsCredentials credentials, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        JsonElement? result = recorder.Invoke("SecretsProvider", "fetchSecret", ("secretId", secretId), ("region", region));
        return Task.FromResult(FakeJson.String(result, "synthetic-dcv-password"));
    }
}

internal sealed class FakeIdentityProvider(PortRecorder recorder) : IIdentityProvider
{
    public Task<string> ResolveIdentityAsync(string region, AwsCredentials credentials, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        JsonElement? result = recorder.Invoke("IdentityProvider", "resolveIdentity", ("region", region));
        return Task.FromResult(FakeJson.Property(result, "username", "example.user"));
    }

    public string PresignedIdentityToken(string region, AwsCredentials credentials)
    {
        JsonElement? result = recorder.Invoke("IdentityProvider", "presignedIdentityToken", ("region", region));
        return FakeJson.String(result, "synthetic-presigned-token");
    }
}

internal sealed class FakeAgentClient(PortRecorder recorder) : IAgentClient
{
    public Task<EnsureSessionResult> EnsureSessionAsync(int port, string authToken, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        JsonElement? result = recorder.Invoke("AgentClient", "ensureSession", ("port", port));
        return Task.FromResult(new EnsureSessionResult(
            FakeJson.Property(result, "user", "example.user"),
            FakeJson.Property(result, "sessionId", "example-session")));
    }
}

/// <summary>A tunnel whose lifetime the harness controls, so a fixture can inject an unexpected exit.</summary>
internal sealed class FakeTunnelHandle(PortRecorder recorder, int processId, int localPort) : ITunnelHandle
{
    private readonly TaskCompletionSource<TunnelDropReason> _dropped =
        new(TaskCreationOptions.RunContinuationsAsynchronously);

    public int ProcessId { get; } = processId;

    public int LocalPort { get; } = localPort;

    public bool Terminated { get; private set; }

    public Task<TunnelDropReason> Dropped => _dropped.Task;

    public Task TerminateAsync()
    {
        if (!Terminated)
        {
            Terminated = true;
            recorder.Invoke("TunnelProvider", "terminateTunnel", ("processId", ProcessId));
            _dropped.TrySetResult(new TunnelDropReason.TerminatedByUser());
        }

        return Task.CompletedTask;
    }

    public void InjectProcessExit(int exitCode, string standardError) =>
        _dropped.TrySetResult(new TunnelDropReason.ProcessExited(exitCode, standardError));
}

internal sealed class FakeTunnelProvider(PortRecorder recorder) : ITunnelProvider
{
    private readonly List<FakeTunnelHandle> _handles = [];

    public IReadOnlyList<FakeTunnelHandle> Handles => _handles;

    public Task<ITunnelHandle> StartTunnelAsync(
        SsmSession session, string region, string instanceId,
        int localPort, int remotePort, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        JsonElement? result = recorder.Invoke(
            "TunnelProvider", "startTunnel",
            ("instanceId", instanceId), ("localPort", localPort), ("remotePort", remotePort));

        var handle = new FakeTunnelHandle(recorder, FakeJson.Int(result, "processIdentifier", 4000), localPort);
        _handles.Add(handle);
        return Task.FromResult<ITunnelHandle>(handle);
    }
}

internal sealed class FakeReadinessProbe(PortRecorder recorder) : IReadinessProbe
{
    public Task<bool> WaitUntilReadyAsync(int port, TimeSpan timeout, TimeSpan interval, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        JsonElement? result = recorder.Invoke("ReadinessProbe", "waitUntilReady", ("port", port));
        return Task.FromResult(FakeJson.Bool(result, fallback: true));
    }

    public Task<bool> IsListeningAsync(int port, TimeSpan timeout, CancellationToken cancellationToken)
    {
        JsonElement? result = recorder.Invoke("ReadinessProbe", "isListening", ("port", port));
        return Task.FromResult(FakeJson.Bool(result, fallback: false));
    }
}

internal sealed class FakeDcvLauncher(PortRecorder recorder, bool viewerInstalled) : IDcvLauncher
{
    public bool IsViewerInstalled() => viewerInstalled;

    public Task LaunchAsync(DcvConnectionFile file, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        recorder.Invoke(
            "DCVLauncher", "launch",
            ("port", file.Port), ("user", file.User), ("sessionId", file.SessionId),
            ("hasPassword", file.Password is not null), ("hasAuthToken", file.AuthToken is not null));
        return Task.CompletedTask;
    }

    public void SweepOrphanedFiles() => recorder.Invoke("DCVLauncher", "sweepOrphanedFiles");
}

internal sealed class FakeInstanceIdStore(PortRecorder recorder, string? seed) : IInstanceIdStore
{
    private string? _value = seed;

    public string? LastInstanceId(Guid profileId)
    {
        recorder.Invoke("InstanceIdStore", "lastInstanceId", ("profileId", profileId));
        return _value;
    }

    public void SetLastInstanceId(Guid profileId, string instanceId)
    {
        recorder.Invoke("InstanceIdStore", "setLastInstanceId", ("profileId", profileId), ("instanceId", instanceId));
        _value = instanceId;
    }
}

/// <summary>Collapses every wait to nothing, so fixtures assert ordering rather than wall-clock time.</summary>
internal sealed class InstantDelay : IDelay
{
    public Task WaitAsync(TimeSpan duration, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        return Task.CompletedTask;
    }
}
