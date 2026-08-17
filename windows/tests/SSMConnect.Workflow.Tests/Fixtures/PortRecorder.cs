using System.Text.Json;
using SSMConnect.Domain;

namespace SSMConnect.Workflow.Tests.Fixtures;

/// <summary>One recorded call to an injected port.</summary>
public sealed record RecordedCall(string Port, string Method, IReadOnlyDictionary<string, object?> Arguments)
{
    public override string ToString() => $"{Port}.{Method}";
}

/// <summary>
/// Records every port call and serves the outcome queue a fixture declared for it.
/// </summary>
/// <remarks>
/// Queue semantics are part of the contract: each entry is consumed by one call, and the last entry
/// repeats. That is what lets a fixture say "fails once, then succeeds" without any scripting.
/// </remarks>
public sealed class PortRecorder(Given given)
{
    private readonly Dictionary<string, int> _consumed = [];
    private readonly List<RecordedCall> _calls = [];
    private readonly Lock _gate = new();

    public IReadOnlyList<RecordedCall> Calls
    {
        get
        {
            lock (_gate)
            {
                return [.. _calls];
            }
        }
    }

    public int CountOf(string port, string method) =>
        Calls.Count(call => call.Port == port && call.Method == method);

    /// <summary>Records a call and returns the outcome the fixture declared, throwing if it is an error.</summary>
    public JsonElement? Invoke(string port, string method, params (string Name, object? Value)[] arguments)
    {
        lock (_gate)
        {
            _calls.Add(new RecordedCall(port, method, arguments.ToDictionary(a => a.Name, a => a.Value)));
        }

        Outcome? outcome = NextOutcome(port, method);
        if (outcome is null)
        {
            return null;
        }

        if (outcome.Error is OutcomeError error)
        {
            throw ToException(error);
        }

        return outcome.Result;
    }

    private Outcome? NextOutcome(string port, string method)
    {
        if (!given.Ports.TryGetValue(port, out Dictionary<string, Outcome[]>? methods) ||
            !methods.TryGetValue(method, out Outcome[]? queue) ||
            queue.Length == 0)
        {
            return null;
        }

        string key = $"{port}.{method}";
        lock (_gate)
        {
            _consumed.TryGetValue(key, out int index);
            _consumed[key] = index + 1;
            return queue[Math.Min(index, queue.Length - 1)];
        }
    }

    /// <summary>
    /// Maps a portable error kind onto this implementation's exception type. The fixture never names
    /// a platform type, so this mapping is the whole translation layer.
    /// </summary>
    private static Exception ToException(OutcomeError error) => error.Kind switch
    {
        "expiredCredentials" => new ExpiredCredentialsException(),
        "signInRequired" => new SignInRequiredException(),
        "invalidRegion" => new ProfileConfigurationException("resource region", error.Message ?? string.Empty),
        "instanceTerminated" => new InstanceTerminatedException(error.Message ?? "i-unknown"),
        "stageTimeout" => new StageTimeoutException(error.Message ?? "Stage"),
        "localPortInUse" => new TunnelException(error.Message ?? "The local port is already in use."),
        "tunnelNotEstablished" => DcvReadinessException.TunnelNotEstablished(0),
        "dcvServerNotReady" => DcvReadinessException.DcvServerNotReady(0),
        "agentUnauthorized" => new AgentException(error.Message ?? "The agent rejected the request.", responded: true),
        "agentUnreachable" => new AgentException(error.Message ?? "The agent is unreachable.", responded: false),
        "viewerNotInstalled" => new InvalidOperationException("Amazon DCV Viewer is not installed."),
        "awsServiceError" => new AwsServiceException(error.Message ?? "AWS returned an error."),
        _ => new InvalidOperationException(error.Message ?? "Unknown failure."),
    };
}
