using System.Globalization;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

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
    /// <summary>New documents use v2; imported v1 documents migrate only on explicit editing.</summary>
    public const int CurrentSchemaVersion = 2;

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
    public JsonObject? WebForwards { get; init; }
    public JsonObject? RemoteDevelopment { get; init; }
    public IReadOnlyList<string> RequiredCapabilities { get; init; } = [];

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
        ConnectionProfile profile, IReadOnlyDictionary<string, JsonNode?>? unknownFields = null,
        Guid? documentId = null) => new()
        {
            Id = documentId ?? profile.Id,
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
            ConnectAction = profile.ConnectAction == Domain.ConnectAction.TunnelOnly ? "tunnelOnly" : DcvViewerAction,
            WebForwards = ProfilePortability.ConfigurationNode(profile.WebForwards),
            RemoteDevelopment = ProfilePortability.ConfigurationNode(profile.RemoteDevelopment),
            RequiredCapabilities = ProfilePortability.Capabilities(profile).Order(StringComparer.Ordinal).ToArray(),
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
        ConnectAction = ConnectAction == "tunnelOnly" ? Domain.ConnectAction.TunnelOnly : Domain.ConnectAction.DcvViewer,
        WebForwards = ProfilePortability.Configuration<WebForwardsConfiguration>(WebForwards, "webForwards"),
        RemoteDevelopment = ProfilePortability.Configuration<RemoteDevelopmentConfiguration>(RemoteDevelopment, "remoteDevelopment"),
    };

    public PortableProfileDocument WithProfile(ConnectionProfile profile)
    {
        PortableProfileDocument updated = FromProfile(profile, UnknownFields, Id);
        JsonObject? web = MergeConfiguration(WebForwards, updated.WebForwards,
            ["enabled", "sshUser", "socksPort", "proxySuffixes", "localForwards", "browser", "browserMode"]);
        if (web is not null && WebForwards?["localForwards"] is JsonArray oldForwards
            && updated.WebForwards?["localForwards"] is JsonArray newForwards)
        {
            web["localForwards"] = new JsonArray(newForwards.Select(value =>
            {
                var current = value as JsonObject;
                JsonObject? old = oldForwards.OfType<JsonObject>()
                    .FirstOrDefault(previous => JsonNode.DeepEquals(previous["localPort"], current?["localPort"]));
                return (JsonNode?)MergeConfiguration(old, current, ["name", "localPort", "remoteHost", "remotePort", "openPath"]);
            }).ToArray());
        }
        return updated with
        {
            WebForwards = web,
            RemoteDevelopment = MergeConfiguration(RemoteDevelopment, updated.RemoteDevelopment, ["enabled", "folder"]),
            RequiredCapabilities = RequiredCapabilities.Union(updated.RequiredCapabilities, StringComparer.Ordinal)
                .Order(StringComparer.Ordinal).ToArray(),
        };
    }

    public void EnsureSupported(IReadOnlySet<string> capabilities)
    {
        string[] unsupported = RequiredCapabilities.Where(required => !capabilities.Contains(required))
            .Order(StringComparer.Ordinal).ToArray();
        if (unsupported.Length > 0)
        {
            throw new ProfilePortabilityException(
                $"This client does not yet support required capabilities: {string.Join(", ", unsupported)}. " +
                "Use a compatible client or disable those capabilities explicitly in the source file. Nothing was attached or connected.");
        }
    }

    private static JsonObject? MergeConfiguration(JsonObject? old, JsonObject? current, string[] known)
    {
        if (current is null) { return null; }
        var merged = old?.DeepClone().AsObject() ?? new JsonObject();
        foreach (string key in known) { merged.Remove(key); }
        foreach ((string key, JsonNode? value) in current) { merged[key] = value?.DeepClone(); }
        return merged;
    }
}

/// <summary>
/// A portable document could not be read. Every case names the offending field and value, for the
/// same reason <see cref="ProfileConfigurationException"/> does: an import failure the user cannot
/// act on is barely better than a silent one.
/// </summary>
public class ProfilePortabilityException(string message) : ConnectionException(message)
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
        "clientSecret", "privateKey", "privateKeyPath", "keyPath", "browserProfilePath",
        "helperPath", "executablePath", "attachmentPath", "knownHosts", "cookies", "history",
        "generation", "lease", "ownerPid", "ownerLaunchDate", "consent", "restoreJournal",
    };

    private static readonly HashSet<string> KnownKeys = new(StringComparer.Ordinal)
    {
        "schemaVersion", "id", "name", "ssoStartUrl", "ssoRegion", "accountId", "roleName",
        "resourceRegion", "instanceTagKey", "instanceTagValue", "connectMode", "connectAction",
        "localPort", "remotePort", "agentRemotePort", "secretId",
        "webForwards", "remoteDevelopment", "requiredCapabilities",
    };

    private static readonly JsonSerializerOptions ConfigurationOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase, allowIntegerValues: false) },
    };
    private static readonly HashSet<string> NormalizedForbidden = ForbiddenKeys
        .Select(NormalizeKey).ToHashSet(StringComparer.Ordinal);

    /// <summary>
    /// Encodes a profile as a portable document. Keys are written in a stable order and the output
    /// is indented, because an exported profile is a file people diff and review.
    /// </summary>
    public static string Export(
        ConnectionProfile profile, IReadOnlyDictionary<string, JsonNode?>? unknownFields = null) =>
        Export(PortableProfileDocument.FromProfile(profile, unknownFields));

    public static string Export(PortableProfileDocument document, ProfileFileFormat format = ProfileFileFormat.Json)
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
        if (document.WebForwards is not null) { root["webForwards"] = document.WebForwards.DeepClone(); }
        if (document.RemoteDevelopment is not null) { root["remoteDevelopment"] = document.RemoteDevelopment.DeepClone(); }
        if (document.RequiredCapabilities.Count > 0)
        {
            root["requiredCapabilities"] = new JsonArray(document.RequiredCapabilities.Select(value => (JsonNode?)JsonValue.Create(value)).ToArray());
        }

        foreach ((string key, JsonNode? value) in document.UnknownFields)
        {
            if (KnownKeys.Contains(key)) { throw new ProfilePortabilityException("Unknown optional fields cannot replace modeled profile fields."); }
            root[key] = value?.DeepClone();
        }

        var ordered = new JsonObject();
        foreach (string key in root.Select(pair => pair.Key).OrderBy(key => key, StringComparer.Ordinal).ToList())
        {
            ordered[key] = root[key]?.DeepClone();
        }

        string result = ProfileDocumentSyntax.Write(ordered, format);
        _ = Import(result, format);
        return result;
    }

    /// <summary>Reads a portable document, validating it the way the schema does.</summary>
    public static PortableProfileDocument Import(string json, ProfileFileFormat format = ProfileFileFormat.Json)
    {
        JsonObject root = ProfileDocumentSyntax.Read(json, format);

        // Version first: a newer document must fail with an actionable message rather than be
        // partially understood.
        int version = RequiredInt(root, "schemaVersion");
        if (version is not (1 or PortableProfileDocument.CurrentSchemaVersion))
        {
            throw ProfilePortabilityException.UnsupportedSchemaVersion(version);
        }

        // Reject before reading anything else, so a document carrying a secret is never partially
        // materialised.
        CheckSecurity(root);

        string idText = RequiredString(root, "id");
        if (!Guid.TryParseExact(idText, "D", out Guid id))
        {
            throw ProfilePortabilityException.InvalidField("id", idText, "it is not a UUID.");
        }

        ConnectMode? mode = null;
        if (root["connectMode"] is JsonNode modeNode && modeNode.GetValueKind() != JsonValueKind.Null)
        {
            string modeText = RequiredString(root, "connectMode");
            mode = modeText switch
            {
                "singleUser" => Domain.ConnectMode.SingleUser,
                "multiUser" => Domain.ConnectMode.MultiUser,
                _ => throw ProfilePortabilityException.InvalidField(
                    "connectMode", modeText, "it must be singleUser or multiUser."),
            };
        }

        string action = PortableProfileDocument.DcvViewerAction;
        if (root.ContainsKey("connectAction") && root["connectAction"] is null)
        {
            throw new ProfilePortabilityException("connectAction must be a supported string, not null.");
        }
        if (root["connectAction"] is JsonNode actionNode && actionNode.GetValueKind() != JsonValueKind.Null)
        {
            action = RequiredString(root, "connectAction");
            if (action != PortableProfileDocument.DcvViewerAction && !(version == 2 && action == "tunnelOnly"))
            {
                throw ProfilePortabilityException.InvalidField(
                    "connectAction", action,
                    "it is not supported by this schema version.");
            }
        }

        string? secretId = null;
        if (root["secretId"] is JsonNode secretNode && secretNode.GetValueKind() != JsonValueKind.Null)
        {
            secretId = RequiredString(root, "secretId");
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

        JsonObject? web = OptionalObject(root, "webForwards");
        JsonObject? remote = OptionalObject(root, "remoteDevelopment");
        string[] capabilities = [];
        if (root.ContainsKey("requiredCapabilities"))
        {
            if (root["requiredCapabilities"] is not JsonArray values || values.Any(value => value?.GetValueKind() != JsonValueKind.String))
            {
                throw new ProfilePortabilityException("requiredCapabilities must be an array of strings.");
            }
            capabilities = values.Select(value => value!.GetValue<string>()).ToArray();
            if (capabilities.Any(value => value is not ("tunnelOnly" or "webForwards" or "browserBootstrap" or "remoteDevelopment")))
            {
                throw new ProfilePortabilityException("This profile requires a capability this version does not understand.");
            }
        }
        if (version == 1 && (root.ContainsKey("webForwards") || root.ContainsKey("remoteDevelopment") || root.ContainsKey("requiredCapabilities")))
        {
            throw new ProfilePortabilityException("Web, browser, editor and required-capability fields need schemaVersion 2.");
        }

        var document = new PortableProfileDocument
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
            WebForwards = web,
            RemoteDevelopment = remote,
            RequiredCapabilities = capabilities,
        };
        ValidateBlockShape(web, remote);
        ConnectionProfile profile = document.ToProfile();
        ValidateConfiguration(profile);
        if (!Capabilities(profile).IsSubsetOf(capabilities.ToHashSet(StringComparer.Ordinal)))
        {
            throw new ProfilePortabilityException("requiredCapabilities must declare every enabled tunnel, web/browser and editor capability.");
        }
        return document;
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
        if (value.GetValueKind() != JsonValueKind.Number
            || !decimal.TryParse(value.ToJsonString(), NumberStyles.Float, CultureInfo.InvariantCulture, out decimal number)
            || number != decimal.Truncate(number) || number < int.MinValue || number > int.MaxValue)
        {
            throw ProfilePortabilityException.InvalidField(key, value.ToJsonString(), "it must be a whole number.");
        }

        return (int)number;
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

    internal static JsonObject? ConfigurationNode<T>(T? value) where T : class =>
        value is null ? null : JsonSerializer.SerializeToNode(value, ConfigurationOptions)?.AsObject();

    internal static T? Configuration<T>(JsonObject? value, string field) where T : class
    {
        if (value is null) { return null; }
        try { return value.Deserialize<T>(ConfigurationOptions) ?? throw new ProfilePortabilityException($"{field} must be an object."); }
        catch (JsonException) { throw new ProfilePortabilityException($"{field} contains an invalid or unsupported value."); }
    }

    public static HashSet<string> Capabilities(ConnectionProfile profile)
    {
        var required = new HashSet<string>(StringComparer.Ordinal);
        if (profile.ConnectAction == ConnectAction.TunnelOnly) { required.Add("tunnelOnly"); }
        if (profile.WebForwards?.Enabled == true)
        {
            required.Add("webForwards");
            if (profile.WebForwards.BrowserMode is not null) { required.Add("browserBootstrap"); }
        }
        if (profile.RemoteDevelopment?.Enabled == true) { required.Add("remoteDevelopment"); }
        return required;
    }

    private static JsonObject? OptionalObject(JsonObject root, string key)
    {
        if (root[key] is null) { return null; }
        return root[key] as JsonObject ?? throw new ProfilePortabilityException($"{key} must be an object or null.");
    }

    private static void ValidateConfiguration(ConnectionProfile profile)
    {
        if (!Uri.TryCreate(profile.SsoStartUrl, UriKind.Absolute, out Uri? uri)
            || uri.Scheme != "https" || uri.Host.Length == 0 || uri.UserInfo.Length != 0
            || uri.Query.Length != 0 || uri.Fragment.Length != 0)
        {
            throw new ProfilePortabilityException("ssoStartUrl must be an HTTPS URL without credentials, a query or a fragment.");
        }

        if (profile.RemoteDevelopment?.Folder is { Length: > 0 } folder
            && (!folder.StartsWith('/') || folder.Any(char.IsControl)))
        {
            throw new ProfilePortabilityException("remoteDevelopment.folder must be an absolute remote path.");
        }
        if (profile.WebForwards is not { Enabled: true } web) { return; }
        if (web.ProxySuffixes is null || web.LocalForwards is null)
        {
            throw new ProfilePortabilityException("Web proxy suffixes and local forwards must be arrays.");
        }
        var ports = web.LocalForwards.Select(value => value.LocalPort).Concat(web.SocksPort is int socks ? [socks] : []).ToArray();
        if (ports.Length == 0 || ports.Any(value => value is < 1 or > 65535)
            || web.LocalForwards.Any(value => value.RemotePort is < 1 or > 65535)
            || ports.Distinct().Count() != ports.Length)
        {
            throw new ProfilePortabilityException("Web forwards require valid, unique local ports and remote ports between 1 and 65535.");
        }
        if (web.SshUser is { Length: > 0 } user && !SafeHost(user))
        {
            throw new ProfilePortabilityException("webForwards.sshUser contains unsupported characters.");
        }
        foreach (string suffix in web.ProxySuffixes)
        {
            if (suffix is null || !suffix.StartsWith('.') || suffix.Length < 2 || !SafeHost(suffix)
                || suffix.Contains("..", StringComparison.Ordinal) || suffix.EndsWith('.') || web.SocksPort is null)
            {
                throw new ProfilePortabilityException("Proxy suffixes require a SOCKS port and dot-prefixed domain names.");
            }
        }
        foreach (LocalForward forward in web.LocalForwards)
        {
            if (string.IsNullOrWhiteSpace(forward.Name) || !SafeHost(forward.RemoteHost)
                || (forward.OpenPath is { Length: > 0 } path && (!path.StartsWith('/') || path.Any(char.IsWhiteSpace))))
            {
                throw new ProfilePortabilityException("Each local forward needs a name, safe remote host and optional absolute open path.");
            }
        }
    }

    private static void ValidateBlockShape(JsonObject? web, JsonObject? remote)
    {
        static void Boolean(JsonObject block, string key)
        {
            if (block.ContainsKey(key) && block[key]?.GetValueKind() is not (JsonValueKind.True or JsonValueKind.False))
            {
                throw new ProfilePortabilityException($"{key} must be a boolean.");
            }
        }
        if (remote is not null) { Boolean(remote, "enabled"); }
        if (web is null) { return; }
        Boolean(web, "enabled");
        if (web.ContainsKey("socksPort") && web["socksPort"] is not null) { _ = RequiredPort(web, "socksPort"); }
        if (web.ContainsKey("proxySuffixes")
            && (web["proxySuffixes"] is not JsonArray suffixes || suffixes.Any(value => value?.GetValueKind() != JsonValueKind.String)))
        {
            throw new ProfilePortabilityException("proxySuffixes must be an array of strings.");
        }
        if (web.ContainsKey("localForwards"))
        {
            if (web["localForwards"] is not JsonArray forwards)
            {
                throw new ProfilePortabilityException("localForwards must be an array of objects.");
            }
            foreach (JsonNode? value in forwards)
            {
                if (value is not JsonObject forward) { throw new ProfilePortabilityException("Each local forward must be an object."); }
                _ = RequiredNonEmptyString(forward, "name");
                _ = RequiredNonEmptyString(forward, "remoteHost");
                _ = RequiredPort(forward, "localPort");
                _ = RequiredPort(forward, "remotePort");
            }
        }
    }

    private static bool SafeHost(string? value) => !string.IsNullOrEmpty(value) && !value.StartsWith('-')
        && value.All(character => char.IsAsciiLetterOrDigit(character) || character is '-' or '.' or '_');

    private static string NormalizeKey(string key) => new(key.ToLowerInvariant().Where(char.IsLetterOrDigit).ToArray());

    private static void CheckSecurity(JsonNode? node)
    {
        switch (node)
        {
            case JsonObject obj:
                foreach ((string key, JsonNode? value) in obj)
                {
                    if (NormalizedForbidden.Contains(NormalizeKey(key))) { throw ProfilePortabilityException.ForbiddenField(key); }
                    CheckSecurity(value);
                }
                break;
            case JsonArray array:
                foreach (JsonNode? value in array) { CheckSecurity(value); }
                break;
            case JsonValue value when value.GetValueKind() == JsonValueKind.String:
                string text = value.GetValue<string>();
                if (text.Contains("private key-----", StringComparison.OrdinalIgnoreCase)
                    || text.Contains("x-amz-signature=", StringComparison.OrdinalIgnoreCase)
                    || text.Contains("x-amz-credential=", StringComparison.OrdinalIgnoreCase))
                {
                    throw new ProfilePortabilityException("The profile contains private authentication material.");
                }
                break;
        }
    }
}
