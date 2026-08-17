namespace SSMConnect.Domain;

/// <summary>
/// The connection lifecycle. These eight states and their order are a shared contract: the macOS
/// client emits the same sequence, and the workflow conformance fixtures assert it.
/// </summary>
/// <remarks>
/// The names here are the portable contract values from <c>state-machine.schema.json</c>, spelled
/// in .NET casing. <see cref="ConnectionStateNames"/> maps between the two.
/// </remarks>
public enum ConnectionState
{
    Disconnected,
    Authenticating,
    Resolving,
    Starting,
    WaitingForSsm,
    Tunneling,
    Connected,
    Error,
}

/// <summary>Maps <see cref="ConnectionState"/> to and from the contract's wire names.</summary>
public static class ConnectionStateNames
{
    private static readonly Dictionary<ConnectionState, string> ToWire = new()
    {
        [ConnectionState.Disconnected] = "disconnected",
        [ConnectionState.Authenticating] = "authenticating",
        [ConnectionState.Resolving] = "resolving",
        [ConnectionState.Starting] = "starting",
        [ConnectionState.WaitingForSsm] = "waitingForSSM",
        [ConnectionState.Tunneling] = "tunneling",
        [ConnectionState.Connected] = "connected",
        [ConnectionState.Error] = "error",
    };

    private static readonly Dictionary<string, ConnectionState> FromWire =
        ToWire.ToDictionary(pair => pair.Value, pair => pair.Key, StringComparer.Ordinal);

    public static string Wire(this ConnectionState state) => ToWire[state];

    public static ConnectionState Parse(string wire) =>
        FromWire.TryGetValue(wire, out ConnectionState state)
            ? state
            : throw new ArgumentOutOfRangeException(nameof(wire), wire, "Unknown connection state.");

    /// <summary>Whether the state represents work in progress rather than a settled outcome.</summary>
    public static bool IsTransitioning(this ConnectionState state) => state is
        ConnectionState.Authenticating or
        ConnectionState.Resolving or
        ConnectionState.Starting or
        ConnectionState.WaitingForSsm or
        ConnectionState.Tunneling;
}
