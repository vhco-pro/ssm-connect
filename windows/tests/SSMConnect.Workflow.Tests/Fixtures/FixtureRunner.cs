using System.Text.Json;
using SSMConnect.Domain;

namespace SSMConnect.Workflow.Tests.Fixtures;

/// <summary>The observable outcome of running one fixture, ready to assert against.</summary>
public sealed record FixtureRun(
    IReadOnlyList<string> States,
    IReadOnlyList<RecordedCall> Calls,
    PortRecorder Recorder,
    ConnectionWorkflow Workflow);

/// <summary>
/// Executes one conformance fixture against the real <see cref="ConnectionWorkflow"/>, with every
/// port faked from the fixture's declared outcomes.
/// </summary>
public sealed class FixtureRunner
{
    private readonly Fixture _fixture;
    private readonly List<string> _states = [];
    private readonly HashSet<string> _firedEvents = [];
    private readonly HashSet<int> _dispatchedSteps = [];
    private readonly Lock _gate = new();

    private FakeTunnelProvider _tunnels = null!;
    private ConnectionWorkflow _workflow = null!;

    public FixtureRunner(Fixture fixture) => _fixture = fixture;

    public async Task<FixtureRun> RunAsync()
    {
        ConnectionProfile profile = FixtureProfileLoader.Load(_fixture);
        AppSettings settings = BuildSettings();
        var recorder = new PortRecorder(_fixture.Given);
        _tunnels = new FakeTunnelProvider(recorder);

        var sink = new RecordingSink(this);
        _workflow = new ConnectionWorkflow(
            new FakeAuthProvider(recorder),
            new FakeEc2Provider(recorder),
            new FakeSsmProvider(recorder),
            new FakeSecretsProvider(recorder),
            new FakeIdentityProvider(recorder),
            new FakeAgentClient(recorder),
            _tunnels,
            new FakeReadinessProbe(recorder),
            new FakeDcvLauncher(recorder, _fixture.Given.ViewerInstalled),
            new FakeInstanceIdStore(recorder, _fixture.Given.LastInstanceId),
            new InstantDelay(),
            sink,
            profile,
            settings,
            BuildTimeouts());

        // Steps without an afterState run immediately, in order. Steps with one are dispatched from
        // the state callback, which fires synchronously inside the workflow, so a cancelling action
        // lands before the next port call rather than racing it.
        for (int index = 0; index < _fixture.When.Length; index++)
        {
            Step step = _fixture.When[index];
            if (step.AfterState is null)
            {
                MarkDispatched(index);
                Dispatch(step.Action);
                await SettleAsync().ConfigureAwait(false);
            }
        }

        await SettleAsync().ConfigureAwait(false);

        return new FixtureRun([.. _states], recorder.Calls, recorder, _workflow);
    }

    private AppSettings BuildSettings()
    {
        AppSettings settings = AppSettings.Default;
        if (_fixture.Settings is not SettingsOverride over)
        {
            return settings;
        }

        return settings with
        {
            AutoConnect = over.AutoConnect ?? settings.AutoConnect,
            AutoReconnect = over.AutoReconnect ?? settings.AutoReconnect,
            ClipboardAutoClearSeconds = over.ClipboardAutoClearSeconds ?? settings.ClipboardAutoClearSeconds,
        };
    }

    private ConnectionTimeouts BuildTimeouts()
    {
        ConnectionTimeouts timeouts = ConnectionTimeouts.Default with
        {
            // The agent retry loop exists to ride out a tunnel that is not listening yet. Under
            // instant delays a long budget would spin uselessly, so the fixture harness keeps it
            // short; the retry behavior itself is still exercised.
            EnsureSessionAttempts = 3,
        };

        if (_fixture.Harness is not HarnessOverride over)
        {
            return timeouts;
        }

        return timeouts with
        {
            MaxReconnectAttempts = over.MaxReconnectAttempts ?? timeouts.MaxReconnectAttempts,
            EstablishRetryAttempts = over.EstablishRetryAttempts ?? timeouts.EstablishRetryAttempts,
            ReconnectBackoff = over.ReconnectBackoffSeconds is double seconds
                ? TimeSpan.FromSeconds(seconds)
                : timeouts.ReconnectBackoff,
        };
    }

    private void Dispatch(string action)
    {
        switch (action)
        {
            case "onLaunch": _workflow.OnLaunch(); break;
            case "connect": _workflow.Connect(); break;
            case "disconnect": _workflow.Disconnect(); break;
            case "reconnect": _workflow.Reconnect(); break;
            case "stopWorkstation": _workflow.StopWorkstation(); break;
            case "handleSystemWake": _ = _workflow.HandleSystemWakeAsync(); break;
            case "applicationWillTerminate": _ = _workflow.ShutdownAsync(); break;
            default: throw new InvalidOperationException($"Unknown fixture action '{action}'.");
        }
    }

    private bool MarkDispatched(int index)
    {
        lock (_gate)
        {
            return _dispatchedSteps.Add(index);
        }
    }

    /// <summary>
    /// Fires anything a fixture pinned to this state: injected events first, so a tunnel drop is
    /// visible to the monitor the workflow is about to start, then pending actions.
    /// </summary>
    private void OnStateChanged(ConnectionState state)
    {
        string wire = state.Wire();
        lock (_gate)
        {
            _states.Add(wire);
        }

        for (int index = 0; index < _fixture.Given.Events.Length; index++)
        {
            FixtureEvent injected = _fixture.Given.Events[index];
            if (injected.AfterState != wire)
            {
                continue;
            }

            bool firstTime;
            lock (_gate)
            {
                firstTime = _firedEvents.Add($"event-{index}");
            }

            if (firstTime)
            {
                FireEvent(injected);
            }
        }

        for (int index = 0; index < _fixture.When.Length; index++)
        {
            Step step = _fixture.When[index];
            if (step.AfterState == wire && MarkDispatched(index))
            {
                Dispatch(step.Action);
            }
        }
    }

    private void FireEvent(FixtureEvent injected)
    {
        switch (injected.Kind)
        {
            case "tunnelDrop":
                // The main tunnel, not a transient agent tunnel: match on the forwarded local port.
                FakeTunnelHandle? handle = _tunnels.Handles
                    .LastOrDefault(h => !h.Terminated && h.LocalPort == _workflow.Profile.LocalPort);
                handle?.InjectProcessExit(injected.Reason?.ExitCode ?? 1, injected.Reason?.StandardError ?? string.Empty);
                break;

            case "systemWake":
                _ = _workflow.HandleSystemWakeAsync();
                break;

            case "applicationWillTerminate":
                _ = _workflow.ShutdownAsync();
                break;

            default:
                throw new InvalidOperationException($"Unknown fixture event '{injected.Kind}'.");
        }
    }

    /// <summary>
    /// Waits until no further work appears. Every fake completes instantly, so a few consecutive
    /// quiet rounds mean the run has genuinely settled — including any auto-reconnect a tunnel
    /// monitor started after the first check.
    /// </summary>
    private async Task SettleAsync()
    {
        for (int round = 0; round < 3; round++)
        {
            await _workflow.WaitForQuiescenceAsync().ConfigureAwait(false);
            await Task.Delay(15).ConfigureAwait(false);
        }

        await _workflow.WaitForQuiescenceAsync().ConfigureAwait(false);
    }

    private sealed class RecordingSink(FixtureRunner owner) : IEventSink
    {
        public void StateChanged(ConnectionState state) => owner.OnStateChanged(state);

        public void Log(string category, string message)
        {
        }

        public void Notify(ConnectionNotification notification)
        {
        }

        public void PasswordAvailable(string password)
        {
        }
    }
}

/// <summary>Loads the profile a fixture references, applying any declared field overrides.</summary>
public static class FixtureProfileLoader
{
    public static ConnectionProfile Load(Fixture fixture)
    {
        string reference = fixture.Profile.Ref
            ?? throw new InvalidOperationException($"Fixture '{fixture.Id}' has no profile reference.");

        string path = Path.GetFullPath(Path.Combine(FixturePaths.WorkflowsDirectory, reference));
        using JsonDocument document = JsonDocument.Parse(File.ReadAllText(path));
        JsonElement root = document.RootElement;

        Dictionary<string, JsonElement> fields = root.EnumerateObject()
            .ToDictionary(property => property.Name, property => property.Value.Clone());

        if (fixture.Profile.Overrides is JsonElement overrides && overrides.ValueKind == JsonValueKind.Object)
        {
            foreach (JsonProperty property in overrides.EnumerateObject())
            {
                fields[property.Name] = property.Value.Clone();
            }
        }

        return new ConnectionProfile
        {
            Id = Guid.Parse(Text(fields, "id")),
            Name = Text(fields, "name"),
            SsoStartUrl = Text(fields, "ssoStartUrl"),
            SsoRegion = Text(fields, "ssoRegion"),
            AccountId = Text(fields, "accountId"),
            RoleName = Text(fields, "roleName"),
            ResourceRegion = Text(fields, "resourceRegion"),
            InstanceTagKey = Text(fields, "instanceTagKey"),
            InstanceTagValue = Text(fields, "instanceTagValue"),
            LocalPort = Number(fields, "localPort", 8443),
            RemotePort = Number(fields, "remotePort", 8443),
            SecretId = OptionalText(fields, "secretId"),
            AgentRemotePort = OptionalNumber(fields, "agentRemotePort"),
            ConnectMode = OptionalText(fields, "connectMode") switch
            {
                "multiUser" => ConnectMode.MultiUser,
                "singleUser" => ConnectMode.SingleUser,
                _ => null,
            },
        };
    }

    private static string Text(Dictionary<string, JsonElement> fields, string name) =>
        fields.TryGetValue(name, out JsonElement value) && value.ValueKind == JsonValueKind.String
            ? value.GetString() ?? string.Empty
            : string.Empty;

    private static string? OptionalText(Dictionary<string, JsonElement> fields, string name) =>
        fields.TryGetValue(name, out JsonElement value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()
            : null;

    private static int Number(Dictionary<string, JsonElement> fields, string name, int fallback) =>
        fields.TryGetValue(name, out JsonElement value) && value.TryGetInt32(out int parsed) ? parsed : fallback;

    private static int? OptionalNumber(Dictionary<string, JsonElement> fields, string name) =>
        fields.TryGetValue(name, out JsonElement value) && value.TryGetInt32(out int parsed) ? parsed : null;
}

/// <summary>Locates the contract fixtures copied alongside the test assembly.</summary>
public static class FixturePaths
{
    public static string FixturesDirectory { get; } =
        Path.Combine(AppContext.BaseDirectory, "contracts", "fixtures");

    public static string WorkflowsDirectory { get; } = Path.Combine(FixturesDirectory, "workflows");

    public static IReadOnlyList<string> WorkflowFixtureFiles() =>
        Directory.Exists(WorkflowsDirectory)
            ? [.. Directory.GetFiles(WorkflowsDirectory, "*.json").OrderBy(path => path, StringComparer.Ordinal)]
            : [];
}
