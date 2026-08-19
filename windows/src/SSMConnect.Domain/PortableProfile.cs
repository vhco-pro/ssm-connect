using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace SSMConnect.Domain;

/// <summary>
/// The portable connection-profile document (specification §6.1,
/// <c>contracts/connection-profile.schema.json</c>).
/// </summary>
/// <remarks>
/// Deliberately a separate type from <see cref="ConnectionProfile"/> rather than serialization
/// attributes on it. The native model is this client's private storage shape and is free to change;
/// this document is a cross-client contract and is not. They already disagree in ways that would
/// have shipped a schema-violating export: System.Text.Json writes enums as <b>numbers</b> by
/// default, so a naive export emits a numeric connectAction where the schema demands the string
/// <c>dcvViewer</c>, and the document carries a schemaVersion the native model has no reason to hold.
/// </remarks>
public sealed record PortableProfileDocument
{
    /// <summary>The only version this client writes, and the only one it accepts.</summary>
    public const int CurrentSchemaVersion = 1;

    /// <summary>The one connect action v1 defines.</summary>
    public const string DcvViewerAction = "dcvViewer";

    public int SchemaVersion { get; init; } = CurrentSchemaVersion;

    public required Guid Id { get; init; }
    public required string Name { get; init; }
    public required string SsoStartUrl { get; init; }
    public required string SsoRegion { get; init; }
    public required string AccountId { get; init; }
    public required string RoleName { get; init; }
    public required string ResourceRegion { get; init; }
    public required string InstanceTagKey { get; init; }
    public required string InstanceTagValue { get; init; }
    public required int LocalPort { get; init; }
    public required int RemotePort { get; init; }

    /// <summary>
    /// Null means the key was absent, and it must stay absent on re-export. The profile the
    /// shipping macOS app has stored predates this field, so writing a resolved singleUser would
    /// silently rewrite the user's document.
    /// </summary>
    public ConnectMode? ConnectMode { get; init; }

    /// <summary>Null means absent, for the same reason as <see cref="ConnectMode"/>.</summary>
    public int? AgentRemotePort { get; init; }

    public string? SecretId { get; init; }

    public string ConnectAction { get; init; } = DcvViewerAction;

    /// <summary>
    /// Optional properties this client does not model, preserved verbatim so a document written by
    /// a newer client survives a round-trip through this one.
    /// </summary>
    /// <remarks>
    /// Preservation is not unconditional. A document carrying any key on the schema's credential
    /// deny-list is rejected before it reaches here, so this can never become a smuggling channel.
    /// </remarks>
    public IReadOnlyDictionary<string, JsonNode?> UnknownFields { get; init; } =
        new Dictionary<string, JsonNode?>(StringComparer.Ordinal);

    public static PortableProfileDocument FromProfile(
        ConnectionProfile profile, IReadOnlyDictionary<string, JsonNode?>? unknownFields = null) => new()
        {
            Id = profile.Id,
            Name = profile.Name,
            SsoStartUrl = profile.SsoStartUrl,
            SsoRegion = profile.SsoRegion,
            AccountId = profile.AccountId,
            RoleName = profile.RoleName,
            ResourceRegion = profile.ResourceRegion,
            InstanceTagKey = profile.InstanceTagKey,
            InstanceTagValue = profile.InstanceTagValue,
            LocalPort = profile.LocalPort,
            RemotePort = profile.RemotePort,
            ConnectMode = profile.ConnectMode,
            AgentRemotePort = profile.AgentRemotePort,
            SecretId = profile.SecretId,
            UnknownFields = unknownFields ?? new Dictionary<string, JsonNode?>(StringComparer.Ordinal),
        };

    public ConnectionProfile ToProfile() => new()
    {
        Id = Id,
        Name = Name,
        SsoStartUrl = SsoStartUrl,
        SsoRegion = SsoRegion,
        AccountId = AccountId,
        RoleName = RoleName,
        ResourceRegion = ResourceRegion,
        InstanceTagKey = InstanceTagKey,
        InstanceTagValue = InstanceTagValue,
        LocalPort = LocalPort,
        RemotePort = RemotePort,
        ConnectMode = ConnectMode,
        AgentRemotePort = AgentRemotePort,
        SecretId = SecretId,
    };
}

/// <summary>
/// A portable document could not be read. Every case names the offending field and value, for the
/// same reason <see cref="ProfileConfigurationException"/> does: an import failure the user cannot
/// act on is barely better than a silent one.
/// </summary>
public sealed class ProfilePortabilityException(string message) : ConnectionException(message)
{
    public override ErrorCategory Category => ErrorCategory.Configuration;

    public static ProfilePortabilityException MalformedJson() =>
        new("The file is not valid JSON.");

    public static ProfilePortabilityException NotAnObject() =>
        new("The file does not contain a profile object.");

    public static ProfilePortabilityException UnsupportedSchemaVersion(int found) =>
        new($"This profile uses schema version {found}, which this version of SSM Connect does not " +
            "understand. Update SSM Connect and try again.");

    public static ProfilePortabilityException ForbiddenField(string key) =>
        new($"The profile contains \"{key}\", which may carry credentials. A profile document must " +
            "never contain authentication material, so it was rejected rather than imported.");

    public static ProfilePortabilityException MissingField(string key) =>
        new($"The profile is missing the required field \"{key}\".");

    public static ProfilePortabilityException InvalidField(string field, string value, string reason) =>
        new($"The profile field \"{field}\" has the value \"{value}\", but {reason}");
}

/// <summary>Reads and writes the portable profile document.</summary>
public static class ProfilePortability
{
    /// <summary>
    /// Keys the schema's security clause forbids outright: live authentication material and
    /// machine-local paths. Rejected even though they would otherwise be unknown optional
    /// properties, because preserving them is precisely the failure mode to avoid.
    /// </summary>
    public static IReadOnlySet<string> ForbiddenKeys { get; } = new HashSet<string>(StringComparer.Ordinal)
    {
        "accessKeyId", "secretAccessKey", "sessionToken", "credentials",
        "accessToken", "refreshToken", "ssoAccessToken",
        "password", "dcvPassword", "secretValue", "authToken", "presignedUrl",
        "sessionResponse", "ssmSession", "connectionFilePath", "tempFilePath",
    };

    private static readonly HashSet<string> KnownKeys = new(StringComparer.Ordinal)
    {
        "schemaVersion", "id", "name", "ssoStartUrl", "ssoRegion", "accountId", "roleName",
        "resourceRegion", "instanceTagKey", "instanceTagValue", "connectMode", "connectAction",
        "localPort", "remotePort", "agentRemotePort", "secretId",
    };

    private static readonly JsonSerializerOptions WriteOptions = new() { WriteIndented = true };

    /// <summary>
    /// Encodes a profile as a portable document. Keys are written in a stable order and the output
    /// is indented, because an exported profile is a file people diff and review.
    /// </summary>
    public static string Export(
        ConnectionProfile profile, IReadOnlyDictionary<string, JsonNode?>? unknownFields = null) =>
        Export(PortableProfileDocument.FromProfile(profile, unknownFields));

    public static string Export(PortableProfileDocument document)
    {
        var root = new JsonObject
        {
            ["schemaVersion"] = document.SchemaVersion,
            ["id"] = document.Id.ToString("D"),
            ["name"] = document.Name,
            ["ssoStartUrl"] = document.SsoStartUrl,
            ["ssoRegion"] = document.SsoRegion,
            ["accountId"] = document.AccountId,
            ["roleName"] = document.RoleName,
            ["resourceRegion"] = document.ResourceRegion,
            ["instanceTagKey"] = document.InstanceTagKey,
            ["instanceTagValue"] = document.InstanceTagValue,
            ["connectAction"] = document.ConnectAction,
            ["localPort"] = document.LocalPort,
            ["remotePort"] = document.RemotePort,
        };

        // Absent stays absent. Resolving a default while writing would rewrite the user's document
        // and would make a round-trip test pass against synthetic data only.
        if (document.ConnectMode is ConnectMode mode)
        {
            root["connectMode"] = mode == Domain.ConnectMode.MultiUser ? "multiUser" : "singleUser";
        }

        if (document.AgentRemotePort is int agentPort)
        {
            root["agentRemotePort"] = agentPort;
        }

        if (document.SecretId is not null)
        {
            root["secretId"] = document.SecretId;
        }

        foreach ((string key, JsonNode? value) in document.UnknownFields)
        {
            root[key] = value?.DeepClone();
        }

        var ordered = new JsonObject();
        foreach (string key in root.Select(pair => pair.Key).OrderBy(key => key, StringComparer.Ordinal).ToList())
        {
            ordered[key] = root[key]?.DeepClone();
        }

        return ordered.ToJsonString(WriteOptions);
    }

    /// <summary>Reads a portable document, validating it the way the schema does.</summary>
    public static PortableProfileDocument Import(string json)
    {
        JsonNode? node;
        try
        {
            node = JsonNode.Parse(json);
        }
        catch (JsonException)
        {
            throw ProfilePortabilityException.MalformedJson();
        }

        if (node is not JsonObject root)
        {
            throw ProfilePortabilityException.NotAnObject();
        }

        // Version first: a newer document must fail with an actionable message rather than be
        // partially understood.
        int version = RequiredInt(root, "schemaVersion");
        if (version != PortableProfileDocument.CurrentSchemaVersion)
        {
            throw ProfilePortabilityException.UnsupportedSchemaVersion(version);
        }

        // Reject before reading anything else, so a document carrying a secret is never partially
        // materialised.
        foreach (string key in root.Select(pair => pair.Key).ToList())
        {
            if (ForbiddenKeys.Contains(key))
            {
                throw ProfilePortabilityException.ForbiddenField(key);
            }
        }

        string idText = RequiredString(root, "id");
        if (!Guid.TryParse(idText, out Guid id))
        {
            throw ProfilePortabilityException.InvalidField("id", idText, "it is not a UUID.");
        }

        ConnectMode? mode = null;
        if (root["connectMode"] is JsonNode modeNode && modeNode.GetValueKind() != JsonValueKind.Null)
        {
            string modeText = modeNode.GetValue<string>();
            mode = modeText switch
            {
                "singleUser" => Domain.ConnectMode.SingleUser,
                "multiUser" => Domain.ConnectMode.MultiUser,
                _ => throw ProfilePortabilityException.InvalidField(
                    "connectMode", modeText, "it must be singleUser or multiUser."),
            };
        }

        string action = PortableProfileDocument.DcvViewerAction;
        if (root["connectAction"] is JsonNode actionNode && actionNode.GetValueKind() != JsonValueKind.Null)
        {
            action = actionNode.GetValue<string>();
            if (action != PortableProfileDocument.DcvViewerAction)
            {
                throw ProfilePortabilityException.InvalidField(
                    "connectAction", action,
                    $"this version only supports {PortableProfileDocument.DcvViewerAction}.");
            }
        }

        string? secretId = null;
        if (root["secretId"] is JsonNode secretNode && secretNode.GetValueKind() != JsonValueKind.Null)
        {
            secretId = secretNode.GetValue<string>();
        }

        if (mode == Domain.ConnectMode.MultiUser && secretId is not null)
        {
            throw ProfilePortabilityException.InvalidField(
                "secretId", secretId,
                "a multi-user workstation authenticates by identity and has no shared password.");
        }

        var unknown = new Dictionary<string, JsonNode?>(StringComparer.Ordinal);
        foreach ((string key, JsonNode? value) in root.ToList())
        {
            if (!KnownKeys.Contains(key))
            {
                unknown[key] = value?.DeepClone();
            }
        }

        return new PortableProfileDocument
        {
            SchemaVersion = version,
            Id = id,
            Name = RequiredNonEmptyString(root, "name"),
            SsoStartUrl = RequiredNonEmptyString(root, "ssoStartUrl"),
            SsoRegion = RequiredRegion(root, "ssoRegion"),
            AccountId = RequiredAccountId(root),
            RoleName = RequiredNonEmptyString(root, "roleName"),
            ResourceRegion = RequiredRegion(root, "resourceRegion"),
            InstanceTagKey = RequiredNonEmptyString(root, "instanceTagKey"),
            InstanceTagValue = RequiredString(root, "instanceTagValue"),
            LocalPort = RequiredPort(root, "localPort"),
            RemotePort = RequiredPort(root, "remotePort"),
            ConnectMode = mode,
            AgentRemotePort = OptionalPort(root, "agentRemotePort"),
            SecretId = secretId,
            ConnectAction = action,
            UnknownFields = unknown,
        };
    }

    public static ConnectionProfile ImportProfile(string json) => Import(json).ToProfile();

    private static JsonNode RequiredValue(JsonObject root, string key) =>
        root[key] ?? throw ProfilePortabilityException.MissingField(key);

    private static string RequiredString(JsonObject root, string key)
    {
        JsonNode value = RequiredValue(root, key);
        if (value.GetValueKind() != JsonValueKind.String)
        {
            throw ProfilePortabilityException.InvalidField(key, value.ToJsonString(), "it must be a string.");
        }

        return value.GetValue<string>();
    }

    private static string RequiredNonEmptyString(JsonObject root, string key)
    {
        string value = RequiredString(root, key);
        if (value.Length == 0)
        {
            throw ProfilePortabilityException.InvalidField(key, value, "it must not be empty.");
        }

        return value;
    }

    private static int RequiredInt(JsonObject root, string key)
    {
        JsonNode value = RequiredValue(root, key);
        if (value.GetValueKind() != JsonValueKind.Number || !value.AsValue().TryGetValue(out int parsed))
        {
            throw ProfilePortabilityException.InvalidField(key, value.ToJsonString(), "it must be a whole number.");
        }

        return parsed;
    }

    private static string RequiredRegion(JsonObject root, string key)
    {
        string value = RequiredString(root, key);
        if (!AwsRegion.IsValid(value))
        {
            throw ProfilePortabilityException.InvalidField(key, value, "it is not a valid AWS region.");
        }

        return value;
    }

    private static string RequiredAccountId(JsonObject root)
    {
        string value = RequiredString(root, "accountId");
        if (value.Length != 12 || !value.All(char.IsAsciiDigit))
        {
            throw ProfilePortabilityException.InvalidField(
                "accountId", value, "an AWS account ID is exactly 12 digits.");
        }

        return value;
    }

    private static int RequiredPort(JsonObject root, string key)
    {
        int value = RequiredInt(root, key);
        if (value is < 1 or > 65535)
        {
            throw ProfilePortabilityException.InvalidField(
                key, value.ToString(CultureInfo.InvariantCulture), "a port must be between 1 and 65535.");
        }

        return value;
    }

    private static int? OptionalPort(JsonObject root, string key)
    {
        if (root[key] is not JsonNode node || node.GetValueKind() == JsonValueKind.Null)
        {
            return null;
        }

        return RequiredPort(root, key);
    }
}
