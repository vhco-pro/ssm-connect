using System.IO;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace SSMConnect.App.Helper;

/// <summary>The limits the host enforces on its helper (Design, command delivery rules).</summary>
public sealed record HelperHostLimits(TimeSpan Handshake, TimeSpan Heartbeat, TimeSpan CancelConfirmation, TimeSpan HealthyRearm)
{
    public static HelperHostLimits Default { get; } = new(
        TimeSpan.FromSeconds(10), TimeSpan.FromSeconds(15), TimeSpan.FromSeconds(10), TimeSpan.FromMinutes(10));
}

/// <summary>A running helper: its stdin, its stdout, and when it exits.</summary>
public interface IHelperConnection : IAsyncDisposable
{
    Stream Input { get; }
    Stream Output { get; }
    Task Exited { get; }
}

/// <summary>Starts helpers, each in its own container, and ends a container completely.</summary>
public interface IHelperSpawner
{
    Task<IHelperConnection> StartAsync(CancellationToken cancellationToken);

    /// <summary>Ends every process in the helper's container and returns once none remain.</summary>
    Task TerminateAndWaitEmptyAsync(IHelperConnection connection, CancellationToken cancellationToken);
}

public enum HelperHostStatus { Starting, Ready, Unavailable, Updated, Stopped }

public enum HelperOutcome { Completed, Failed, Cancelled, Rejected, CoreStopped }

public sealed record HelperResult(HelperOutcome Outcome, string? Code, string? Message, IReadOnlyDictionary<string, string> Value)
{
    internal static IReadOnlyDictionary<string, string> Empty { get; } = new Dictionary<string, string>();
    internal static HelperResult CoreStopped { get; } = new(HelperOutcome.CoreStopped, "coreStopped", "core stopped", Empty);
}

/// <summary>
/// The shell side of the helper protocol. It starts one helper at a time in its own container,
/// completes the build handshake within the handshake limit, sends a heartbeat each interval and
/// counts an unanswered one as a stop, and replaces a helper that stopped once automatically: the
/// old container is terminated and empty before the replacement starts. The allowance returns
/// after the replacement has run healthy for the re-arm period, or when the user retries. Without
/// an allowance, or when the first helper never completes its handshake, the host shows "SSM
/// Connect core unavailable" until Retry. In-flight commands fail with "core stopped" when their
/// helper stops and are never sent again. A helper of another build is refused at handshake, and
/// the host then asks the user to restart.
/// </summary>
public sealed class HelperHost
{
    public const string UnavailableMessage = "SSM Connect core unavailable";
    public const string UpdatedMessage = "SSM Connect was updated; restart it.";

    sealed class Pending(TaskCompletionSource<HelperResult> completion, IHelperConnection connection)
    {
        public TaskCompletionSource<HelperResult> Completion { get; } = completion;
        public IHelperConnection Connection { get; } = connection;
        public CancellationTokenRegistration Registration { get; set; }
    }

    readonly IHelperSpawner spawner;
    readonly string build;
    readonly HelperHostLimits limits;
    readonly TimeProvider time;
    readonly object gate = new();
    readonly Dictionary<string, Pending> pending = [];
    readonly HashSet<IHelperConnection> stopped = [];
    readonly HashSet<IHelperConnection> handshaken = [];
    IHelperConnection? current;
    TaskCompletionSource<JsonObject?>? handshake;
    ITimer? heartbeatTimer;
    int heartbeatSent;
    int heartbeatAnswered;
    long nextCommand;
    bool shuttingDown;
    DateTimeOffset healthySince;

    public HelperHost(IHelperSpawner spawner, string build, HelperHostLimits limits, TimeProvider time)
    {
        this.spawner = spawner;
        this.build = build;
        this.limits = limits;
        this.time = time;
    }

    public HelperHostStatus Status { get; private set; } = HelperHostStatus.Starting;
    public string? StatusMessage { get; private set; }
    public int AutomaticRestartsAvailable { get; private set; } = 1;

    /// <summary>Heartbeats the current helper has answered (for tests).</summary>
    internal int HeartbeatsAnswered { get { lock (gate) return heartbeatAnswered; } }

    /// <summary>Raised for each event the helper sends, in order.</summary>
    public event Action<JsonObject>? EventReceived;

    /// <summary>Raised whenever <see cref="Status"/> changes.</summary>
    public event Action? StatusChanged;

    public Task StartAsync() => LaunchAsync();

    /// <summary>
    /// Ends the helper for good, as when the user quits or an installer closes the app: asks it to
    /// shut down, which cancels its running commands, waits up to <paramref name="grace"/> for it to
    /// exit, then ends its job. No replacement starts afterwards.
    /// </summary>
    public async Task ShutdownAsync(TimeSpan grace)
    {
        IHelperConnection? connection;
        lock (gate)
        {
            shuttingDown = true;
            connection = current;
            heartbeatTimer?.Dispose();
            heartbeatTimer = null;
        }
        if (connection is null) return;
        await WriteAsync(connection, new JsonObject { ["type"] = "shutdown" });
        await Task.WhenAny(connection.Exited, Task.Delay(grace, time));
        await StopAsync(connection);
    }

    /// <summary>Starts one new helper under the same rules, restoring the automatic restart.</summary>
    public Task RetryAsync()
    {
        lock (gate)
        {
            if (shuttingDown || Status is HelperHostStatus.Ready or HelperHostStatus.Updated) return Task.CompletedTask;
            AutomaticRestartsAvailable = 1;
        }
        return LaunchAsync();
    }

    /// <summary>
    /// Sends a command and waits for its one terminal result. Cancelling the token sends a cancel;
    /// a cancel the helper does not confirm within the limit replaces the helper.
    /// </summary>
    public async Task<HelperResult> SendAsync(string name, IReadOnlyDictionary<string, string> arguments, CancellationToken cancellationToken)
    {
        IHelperConnection connection;
        string id;
        Pending entry;
        lock (gate)
        {
            if (Status != HelperHostStatus.Ready || current is null)
                return new HelperResult(HelperOutcome.Rejected, "unavailable", StatusMessage ?? UnavailableMessage, HelperResult.Empty);
            connection = current;
            id = "c" + (++nextCommand).ToString(System.Globalization.CultureInfo.InvariantCulture);
            entry = new Pending(new TaskCompletionSource<HelperResult>(TaskCreationOptions.RunContinuationsAsynchronously), connection);
            pending[id] = entry;
        }
        var argumentObject = new JsonObject();
        foreach (var (key, value) in arguments) argumentObject[key] = value;
        if (!await WriteAsync(connection, new JsonObject { ["type"] = "command", ["id"] = id, ["name"] = name, ["arguments"] = argumentObject }))
        {
            _ = StopAsync(connection);
        }
        entry.Registration = cancellationToken.Register(() => _ = CancelAsync(id, connection));
        try { return await entry.Completion.Task.ConfigureAwait(false); }
        finally { entry.Registration.Dispose(); }
    }

    async Task CancelAsync(string id, IHelperConnection connection)
    {
        lock (gate) { if (!pending.ContainsKey(id)) return; }
        if (!await WriteAsync(connection, new JsonObject { ["type"] = "cancel", ["id"] = id }))
        {
            await StopAsync(connection);
            return;
        }
        try { await Task.Delay(limits.CancelConfirmation, time); } catch (TaskCanceledException) { return; }
        bool unconfirmed;
        lock (gate) unconfirmed = pending.ContainsKey(id);
        if (unconfirmed) await StopAsync(connection);
    }

    async Task LaunchAsync()
    {
        IHelperConnection connection;
        TaskCompletionSource<JsonObject?> answer;
        lock (gate)
        {
            SetStatus(HelperHostStatus.Starting, null);
            answer = new TaskCompletionSource<JsonObject?>(TaskCreationOptions.RunContinuationsAsynchronously);
            handshake = answer;
        }
        connection = await spawner.StartAsync(CancellationToken.None);
        lock (gate) { current = connection; heartbeatSent = 0; heartbeatAnswered = 0; }
        var reading = Task.Run(() => ReadAsync(connection, answer));
        // The reader ends at stdout EOF, after every frame the helper wrote. A descendant can keep
        // that pipe open after the helper exits, so an exit also counts once the reader has had a
        // moment to drain what was written.
        _ = connection.Exited.ContinueWith(async _ =>
        {
            await Task.WhenAny(reading, Task.Delay(TimeSpan.FromSeconds(1)));
            answer.TrySetResult(null);
            await StopAsync(connection);
        }, TaskScheduler.Default).Unwrap();

        // The handshake limit runs from before the hello is written.
        var timeout = Task.Delay(limits.Handshake, time);
        await WriteAsync(connection, new JsonObject { ["type"] = "hello", ["build"] = build, ["protocolVersion"] = 1 });
        var first = await Task.WhenAny(answer.Task, timeout);
        var reply = first == answer.Task ? answer.Task.Result : null;
        switch ((string?)reply?["type"])
        {
            case "welcome":
                lock (gate)
                {
                    if (current != connection || stopped.Contains(connection)) return;
                    handshaken.Add(connection);
                    healthySince = time.GetUtcNow();
                    SetStatus(HelperHostStatus.Ready, null);
                    heartbeatTimer?.Dispose();
                    heartbeatTimer = time.CreateTimer(_ => _ = HeartbeatAsync(connection), null, limits.Heartbeat, limits.Heartbeat);
                }
                break;
            case "refused" when (string?)reply["reason"] == "differentBuild":
                lock (gate) SetStatus(HelperHostStatus.Updated, UpdatedMessage);
                await StopAsync(connection);
                break;
            default:
                // No handshake in time, a different protocol, or an exit: the helper counts as stopped.
                await StopAsync(connection);
                break;
        }
    }

    async Task HeartbeatAsync(IHelperConnection connection)
    {
        int sequence;
        bool missed;
        lock (gate)
        {
            if (current != connection || Status != HelperHostStatus.Ready) return;
            missed = heartbeatSent != heartbeatAnswered;
            if (!missed && AutomaticRestartsAvailable == 0 && time.GetUtcNow() - healthySince >= limits.HealthyRearm)
                AutomaticRestartsAvailable = 1;
            sequence = ++heartbeatSent;
        }
        if (missed || !await WriteAsync(connection, new JsonObject { ["type"] = "heartbeat", ["sequence"] = sequence }))
            await StopAsync(connection);
    }

    async Task ReadAsync(IHelperConnection connection, TaskCompletionSource<JsonObject?> answer)
    {
        using var reader = new StreamReader(connection.Output, new UTF8Encoding(false), false, 4096, leaveOpen: true);
        try
        {
            string? line;
            while ((line = await reader.ReadLineAsync()) is not null)
            {
                JsonObject? frame;
                try { frame = JsonNode.Parse(line) as JsonObject; } catch (JsonException) { continue; }
                if (frame is null) continue;
                Handle(connection, frame, answer);
            }
        }
        catch (IOException) { }
        catch (ObjectDisposedException) { }
        answer.TrySetResult(null);
        await StopAsync(connection);
    }

    void Handle(IHelperConnection connection, JsonObject frame, TaskCompletionSource<JsonObject?> answer)
    {
        switch ((string?)frame["type"])
        {
            case "welcome" or "refused":
                answer.TrySetResult(frame);
                break;
            case "heartbeat":
                lock (gate) if (current == connection && (int?)frame["sequence"] == heartbeatSent) heartbeatAnswered = heartbeatSent;
                break;
            case "rejected":
                Complete((string?)frame["id"], new HelperResult(HelperOutcome.Rejected,
                    (string?)frame["error"]?["code"], (string?)frame["error"]?["message"], HelperResult.Empty));
                break;
            case "result":
                var value = new Dictionary<string, string>();
                if (frame["value"] is JsonObject values)
                    foreach (var (key, node) in values) value[key] = (string?)node ?? "";
                var result = (string?)frame["outcome"] switch
                {
                    "completed" => new HelperResult(HelperOutcome.Completed, null, null, value),
                    "cancelled" => new HelperResult(HelperOutcome.Cancelled, null, null, value),
                    _ => new HelperResult(HelperOutcome.Failed, (string?)frame["error"]?["code"], (string?)frame["error"]?["message"], value),
                };
                Complete((string?)frame["id"], result);
                break;
            case "event":
                EventReceived?.Invoke(frame);
                break;
        }
    }

    void Complete(string? id, HelperResult result)
    {
        if (id is null) return;
        Pending? entry;
        lock (gate) { if (pending.Remove(id, out entry)) { } }
        entry?.Completion.TrySetResult(result);
    }

    /// <summary>Handles a helper that stopped, once per helper.</summary>
    async Task StopAsync(IHelperConnection connection)
    {
        List<Pending> failed;
        bool restart;
        lock (gate)
        {
            if (!stopped.Add(connection)) return;
            failed = pending.Where(p => p.Value.Connection == connection).Select(p => p.Value).ToList();
            foreach (var key in pending.Where(p => p.Value.Connection == connection).Select(p => p.Key).ToList()) pending.Remove(key);
            if (current == connection) { heartbeatTimer?.Dispose(); heartbeatTimer = null; }
            // Only a helper that completed its handshake earns the automatic replacement: a first
            // helper, or a replacement, that never handshakes leads straight to "unavailable".
            restart = current == connection && !shuttingDown && Status != HelperHostStatus.Updated && AutomaticRestartsAvailable > 0
                && handshaken.Contains(connection);
            if (restart) AutomaticRestartsAvailable -= 1;
            if (current == connection && Status != HelperHostStatus.Updated)
                SetStatus(shuttingDown ? HelperHostStatus.Stopped : HelperHostStatus.Starting, null);
        }
        foreach (var entry in failed) entry.Completion.TrySetResult(HelperResult.CoreStopped);
        await spawner.TerminateAndWaitEmptyAsync(connection, CancellationToken.None);
        await connection.DisposeAsync();
        bool isCurrent;
        lock (gate) isCurrent = current == connection;
        if (!isCurrent) return;
        if (restart) await LaunchAsync();
        else lock (gate) if (Status != HelperHostStatus.Updated && !shuttingDown) SetStatus(HelperHostStatus.Unavailable, UnavailableMessage);
    }

    static readonly UTF8Encoding Utf8 = new(false);

    async Task<bool> WriteAsync(IHelperConnection connection, JsonObject frame)
    {
        var bytes = Utf8.GetBytes(frame.ToJsonString() + "\n");
        try
        {
            await connection.Input.WriteAsync(bytes);
            await connection.Input.FlushAsync();
            return true;
        }
        catch (IOException) { return false; }
        catch (ObjectDisposedException) { return false; }
    }

    void SetStatus(HelperHostStatus status, string? message)
    {
        Status = status;
        StatusMessage = message;
        StatusChanged?.Invoke();
    }
}
