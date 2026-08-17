using System.Text.Json;
using System.Text.Json.Serialization;

namespace SSMConnect.Workflow.Tests.Fixtures;

/// <summary>
/// The on-disk shape of a workflow conformance fixture, matching
/// <c>contracts/state-machine.schema.json</c>.
/// </summary>
public sealed record Fixture
{
    public static readonly JsonSerializerOptions Options = new(JsonSerializerDefaults.Web)
    {
        PropertyNameCaseInsensitive = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
    };

    [JsonPropertyName("schemaVersion")] public int SchemaVersion { get; init; }

    [JsonPropertyName("id")] public string Id { get; init; } = string.Empty;

    [JsonPropertyName("title")] public string Title { get; init; } = string.Empty;

    [JsonPropertyName("covers")] public string[] Covers { get; init; } = [];

    [JsonPropertyName("profile")] public ProfileReference Profile { get; init; } = new();

    [JsonPropertyName("settings")] public SettingsOverride? Settings { get; init; }

    [JsonPropertyName("harness")] public HarnessOverride? Harness { get; init; }

    [JsonPropertyName("given")] public Given Given { get; init; } = new();

    [JsonPropertyName("when")] public Step[] When { get; init; } = [];

    [JsonPropertyName("expect")] public Expectation Expect { get; init; } = new();
}

public sealed record ProfileReference
{
    [JsonPropertyName("$ref")] public string? Ref { get; init; }

    [JsonPropertyName("overrides")] public JsonElement? Overrides { get; init; }
}

public sealed record SettingsOverride
{
    [JsonPropertyName("autoConnect")] public bool? AutoConnect { get; init; }

    [JsonPropertyName("autoReconnect")] public bool? AutoReconnect { get; init; }

    [JsonPropertyName("clipboardAutoClearSeconds")] public int? ClipboardAutoClearSeconds { get; init; }
}

public sealed record HarnessOverride
{
    [JsonPropertyName("maxReconnectAttempts")] public int? MaxReconnectAttempts { get; init; }

    [JsonPropertyName("reconnectBackoffSeconds")] public double? ReconnectBackoffSeconds { get; init; }

    [JsonPropertyName("establishRetryAttempts")] public int? EstablishRetryAttempts { get; init; }
}

public sealed record Given
{
    [JsonPropertyName("lastInstanceId")] public string? LastInstanceId { get; init; }

    [JsonPropertyName("viewerInstalled")] public bool ViewerInstalled { get; init; } = true;

    /// <summary>Port name, then method name, then the queue of outcomes for that method.</summary>
    [JsonPropertyName("ports")]
    public Dictionary<string, Dictionary<string, Outcome[]>> Ports { get; init; } = [];

    [JsonPropertyName("events")] public FixtureEvent[] Events { get; init; } = [];
}

public sealed record Outcome
{
    [JsonPropertyName("result")] public JsonElement? Result { get; init; }

    [JsonPropertyName("error")] public OutcomeError? Error { get; init; }
}

public sealed record OutcomeError
{
    [JsonPropertyName("kind")] public string Kind { get; init; } = string.Empty;

    [JsonPropertyName("message")] public string? Message { get; init; }
}

public sealed record FixtureEvent
{
    [JsonPropertyName("kind")] public string Kind { get; init; } = string.Empty;

    [JsonPropertyName("afterState")] public string AfterState { get; init; } = string.Empty;

    [JsonPropertyName("reason")] public DropReason? Reason { get; init; }
}

public sealed record DropReason
{
    [JsonPropertyName("kind")] public string Kind { get; init; } = "processExited";

    [JsonPropertyName("exitCode")] public int ExitCode { get; init; }

    [JsonPropertyName("stderr")] public string StandardError { get; init; } = string.Empty;
}

public sealed record Step
{
    [JsonPropertyName("action")] public string Action { get; init; } = string.Empty;

    [JsonPropertyName("afterState")] public string? AfterState { get; init; }
}

public sealed record Expectation
{
    [JsonPropertyName("states")] public string[] States { get; init; } = [];

    [JsonPropertyName("statesAreExact")] public bool StatesAreExact { get; init; } = true;

    [JsonPropertyName("calls")] public ExpectedCall[] Calls { get; init; } = [];

    [JsonPropertyName("forbiddenCalls")] public ExpectedCall[] ForbiddenCalls { get; init; } = [];

    [JsonPropertyName("terminal")] public Terminal Terminal { get; init; } = new();
}

public sealed record ExpectedCall
{
    [JsonPropertyName("port")] public string Port { get; init; } = string.Empty;

    [JsonPropertyName("method")] public string Method { get; init; } = string.Empty;

    [JsonPropertyName("times")] public int? Times { get; init; }

    [JsonPropertyName("with")] public Dictionary<string, JsonElement>? With { get; init; }

    public override string ToString() => $"{Port}.{Method}";
}

public sealed record Terminal
{
    [JsonPropertyName("state")] public string State { get; init; } = string.Empty;

    [JsonPropertyName("errorCategory")] public string? ErrorCategory { get; init; }

    [JsonPropertyName("errorMessageContains")] public string? ErrorMessageContains { get; init; }

    [JsonPropertyName("warningPresent")] public bool? WarningPresent { get; init; }

    [JsonPropertyName("instanceId")] public string? InstanceId { get; init; }

    [JsonPropertyName("localPort")] public int? LocalPort { get; init; }

    [JsonPropertyName("tunnelActive")] public bool? TunnelActive { get; init; }

    [JsonPropertyName("passwordInMemory")] public bool? PasswordInMemory { get; init; }
}
