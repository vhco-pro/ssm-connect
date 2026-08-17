namespace SSMConnect.Domain;

/// <summary>
/// Lifecycle state, mirroring EC2's <c>instance-state-name</c> values. SDK-free on purpose: AWS
/// types are mapped into this value in the adapter so the workflow never sees an SDK type.
/// </summary>
public enum Ec2InstanceState
{
    Pending,
    Running,
    ShuttingDown,
    Stopped,
    Stopping,
    Terminated,

    /// <summary>Any value the SDK reports that is not modelled explicitly.</summary>
    Unknown,
}

public static class Ec2InstanceStateNames
{
    private static readonly Dictionary<Ec2InstanceState, string> ToWire = new()
    {
        [Ec2InstanceState.Pending] = "pending",
        [Ec2InstanceState.Running] = "running",
        [Ec2InstanceState.ShuttingDown] = "shutting-down",
        [Ec2InstanceState.Stopped] = "stopped",
        [Ec2InstanceState.Stopping] = "stopping",
        [Ec2InstanceState.Terminated] = "terminated",
        [Ec2InstanceState.Unknown] = "unknown",
    };

    private static readonly Dictionary<string, Ec2InstanceState> FromWire =
        ToWire.ToDictionary(pair => pair.Value, pair => pair.Key, StringComparer.OrdinalIgnoreCase);

    public static string Wire(this Ec2InstanceState state) => ToWire[state];

    /// <summary>Unrecognised values map to <see cref="Ec2InstanceState.Unknown"/> rather than throwing.</summary>
    public static Ec2InstanceState Parse(string? wire) =>
        wire is not null && FromWire.TryGetValue(wire, out Ec2InstanceState state)
            ? state
            : Ec2InstanceState.Unknown;

    /// <summary>Whether the instance is gone or going away and cannot be connected to.</summary>
    public static bool IsTerminal(this Ec2InstanceState state) =>
        state is Ec2InstanceState.Terminated or Ec2InstanceState.ShuttingDown;
}

/// <summary>The workstation instance, as the workflow sees it.</summary>
public sealed record Ec2Instance(string Id, Ec2InstanceState State, string? PrivateIpAddress = null);
