using System.Text.Json;
using System.Text.Json.Nodes;
using SSMConnect.Domain;

namespace SSMConnect.Domain.Tests;

/// <summary>
/// Covers the portable profile document (specification §6.1). The round-trip cases run against the
/// real contract fixtures rather than hand-written JSON, and every exported document is written to
/// <c>artifacts/exported-profiles</c> so <c>contracts/validate.py</c> can check it against the
/// schema — a .NET assertion cannot catch a schema violation such as an enum written as a number.
/// </summary>
public sealed class PortableProfileTests
{
    private static string FixturesDirectory =>
        Path.Combine(AppContext.BaseDirectory, "contracts", "fixtures", "profiles");

    private static string ArtifactsDirectory
    {
        get
        {
            string path = Path.Combine(AppContext.BaseDirectory, "artifacts", "exported-profiles");
            Directory.CreateDirectory(path);
            return path;
        }
    }

    public static TheoryData<string> ProfileFixtures()
    {
        var data = new TheoryData<string>();
        foreach (string path in Directory.GetFiles(FixturesDirectory, "*.json").OrderBy(p => p, StringComparer.Ordinal))
        {
            data.Add(Path.GetFileName(path));
        }

        return data;
    }

    [Fact]
    public void TheContractProfileFixturesAreAvailable() =>
        Assert.True(Directory.GetFiles(FixturesDirectory, "*.json").Length >= 3,
            $"Expected the contract profile fixtures next to the tests, in '{FixturesDirectory}'.");

    /// <summary>
    /// Import then export then import must reach the same document. This is the property that makes
    /// a profile safe to move between clients repeatedly rather than only once.
    /// </summary>
    [Theory]
    [MemberData(nameof(ProfileFixtures))]
    public void RoundTripsAContractFixture(string fileName)
    {
        string original = File.ReadAllText(Path.Combine(FixturesDirectory, fileName));

        PortableProfileDocument first = ProfilePortability.Import(original);
        string exported = ProfilePortability.Export(first);
        PortableProfileDocument second = ProfilePortability.Import(exported);

        Assert.Equal(first.Id, second.Id);
        Assert.Equal(first.Name, second.Name);
        Assert.Equal(first.SsoStartUrl, second.SsoStartUrl);
        Assert.Equal(first.SsoRegion, second.SsoRegion);
        Assert.Equal(first.AccountId, second.AccountId);
        Assert.Equal(first.RoleName, second.RoleName);
        Assert.Equal(first.ResourceRegion, second.ResourceRegion);
        Assert.Equal(first.InstanceTagKey, second.InstanceTagKey);
        Assert.Equal(first.InstanceTagValue, second.InstanceTagValue);
        Assert.Equal(first.LocalPort, second.LocalPort);
        Assert.Equal(first.RemotePort, second.RemotePort);
        Assert.Equal(first.ConnectMode, second.ConnectMode);
        Assert.Equal(first.AgentRemotePort, second.AgentRemotePort);
        Assert.Equal(first.SecretId, second.SecretId);
        Assert.Equal(first.ConnectAction, second.ConnectAction);

        // Hand the exported document to validate.py, which owns the schema.
        File.WriteAllText(Path.Combine(ArtifactsDirectory, fileName), exported);
    }

    /// <summary>
    /// The whole reason this is a separate type: the enum must reach the file as a string. Left to
    /// System.Text.Json's defaults on the native model it would be written as a number.
    /// </summary>
    [Fact]
    public void WritesEnumsAsSchemaStringsNotNumbers()
    {
        string json = ProfilePortability.Export(Example() with { ConnectMode = ConnectMode.MultiUser, SecretId = null });
        JsonNode root = JsonNode.Parse(json)!;

        Assert.Equal(JsonValueKind.String, root["connectAction"]!.GetValueKind());
        Assert.Equal("dcvViewer", root["connectAction"]!.GetValue<string>());
        Assert.Equal(JsonValueKind.String, root["connectMode"]!.GetValueKind());
        Assert.Equal("multiUser", root["connectMode"]!.GetValue<string>());
    }

    /// <summary>
    /// A profile stored before the connect-mode field existed has no such key. Writing a resolved
    /// value would rewrite the user's document, so absent must stay absent.
    /// </summary>
    [Fact]
    public void AnAbsentConnectModeStaysAbsentOnReExport()
    {
        string json = ProfilePortability.Export(Example());
        JsonObject root = (JsonObject)JsonNode.Parse(json)!;

        Assert.False(root.ContainsKey("connectMode"));
        Assert.False(root.ContainsKey("agentRemotePort"));
        Assert.Null(ProfilePortability.Import(json).ConnectMode);

        // Resolution is still available to callers; it just is not baked into the document.
        Assert.Equal(ConnectMode.SingleUser, ProfilePortability.ImportProfile(json).ResolvedConnectMode);
        Assert.Equal(8444, ProfilePortability.ImportProfile(json).ResolvedAgentRemotePort);
    }

    [Fact]
    public void PreservesUnknownOptionalProperties()
    {
        string source = ProfilePortability.Export(Example());
        JsonObject root = (JsonObject)JsonNode.Parse(source)!;
        root["futureFeature"] = "some-value";
        root["futureCount"] = 7;

        PortableProfileDocument imported = ProfilePortability.Import(root.ToJsonString());
        Assert.Equal(2, imported.UnknownFields.Count);

        JsonObject reExported = (JsonObject)JsonNode.Parse(ProfilePortability.Export(imported))!;
        Assert.Equal("some-value", reExported["futureFeature"]!.GetValue<string>());
        Assert.Equal(7, reExported["futureCount"]!.GetValue<int>());
    }

    /// <summary>
    /// Preservation stops at the schema's security clause. A document carrying credential material
    /// must be rejected, not carried through as an unknown optional property.
    /// </summary>
    [Theory]
    [InlineData("accessKeyId")]
    [InlineData("secretAccessKey")]
    [InlineData("sessionToken")]
    [InlineData("password")]
    [InlineData("authToken")]
    [InlineData("presignedUrl")]
    [InlineData("connectionFilePath")]
    public void RejectsADocumentCarryingCredentialMaterial(string forbiddenKey)
    {
        JsonObject root = (JsonObject)JsonNode.Parse(ProfilePortability.Export(Example()))!;
        root[forbiddenKey] = "should-never-be-imported";

        var error = Assert.Throws<ProfilePortabilityException>(
            () => ProfilePortability.Import(root.ToJsonString()));
        Assert.Contains(forbiddenKey, error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void EveryForbiddenKeyInTheSchemaIsEnforced()
    {
        // Kept in step with the schema's deny-list; a key added there must be added here.
        string[] expected =
        [
            "accessKeyId", "secretAccessKey", "sessionToken", "credentials",
            "accessToken", "refreshToken", "ssoAccessToken",
            "password", "dcvPassword", "secretValue", "authToken", "presignedUrl",
            "sessionResponse", "ssmSession", "connectionFilePath", "tempFilePath",
        ];

        Assert.Equal(expected.Order(StringComparer.Ordinal), ProfilePortability.ForbiddenKeys.Order(StringComparer.Ordinal));
    }

    [Fact]
    public void RejectsAnUnsupportedSchemaVersionWithAnActionableMessage()
    {
        JsonObject root = (JsonObject)JsonNode.Parse(ProfilePortability.Export(Example()))!;
        root["schemaVersion"] = 2;

        var error = Assert.Throws<ProfilePortabilityException>(
            () => ProfilePortability.Import(root.ToJsonString()));
        Assert.Contains("version 2", error.Message, StringComparison.Ordinal);
        Assert.Contains("Update SSM Connect", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void RejectsAMultiUserProfileCarryingASecretId()
    {
        JsonObject root = (JsonObject)JsonNode.Parse(
            ProfilePortability.Export(Example() with { ConnectMode = ConnectMode.MultiUser }))!;
        root["secretId"] = "example/dcv/password";

        var error = Assert.Throws<ProfilePortabilityException>(
            () => ProfilePortability.Import(root.ToJsonString()));
        Assert.Contains("no shared password", error.Message, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("accountId", "\"12345\"", "12 digits")]
    [InlineData("resourceRegion", "\"eu-central-1-\"", "valid AWS region")]
    [InlineData("localPort", "0", "between 1 and 65535")]
    [InlineData("name", "\"\"", "must not be empty")]
    public void RejectsInvalidFieldsNamingTheFieldAndValue(string field, string rawValue, string reasonFragment)
    {
        JsonObject root = (JsonObject)JsonNode.Parse(ProfilePortability.Export(Example()))!;
        root[field] = JsonNode.Parse(rawValue);

        var error = Assert.Throws<ProfilePortabilityException>(
            () => ProfilePortability.Import(root.ToJsonString()));
        Assert.Contains(field, error.Message, StringComparison.Ordinal);
        Assert.Contains(reasonFragment, error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void RejectsAMissingRequiredField()
    {
        JsonObject root = (JsonObject)JsonNode.Parse(ProfilePortability.Export(Example()))!;
        root.Remove("roleName");

        var error = Assert.Throws<ProfilePortabilityException>(
            () => ProfilePortability.Import(root.ToJsonString()));
        Assert.Contains("roleName", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void RejectsMalformedJson() =>
        Assert.Throws<ProfilePortabilityException>(() => ProfilePortability.Import("{not json"));

    [Fact]
    public void RejectsJsonThatIsNotAnObject() =>
        Assert.Throws<ProfilePortabilityException>(() => ProfilePortability.Import("[]"));

    /// <summary>An import failure is a configuration problem, so it classifies as one.</summary>
    [Fact]
    public void AnImportFailureClassifiesAsConfiguration() =>
        Assert.Equal(ErrorCategory.Configuration,
            ErrorCategories.Classify(ProfilePortabilityException.MalformedJson()));

    private static ConnectionProfile Example() => new()
    {
        Id = Guid.Parse("11111111-1111-4111-8111-111111111111"),
        Name = "Example Workstation",
        SsoStartUrl = "https://d-0000000000.awsapps.com/start",
        SsoRegion = "eu-west-1",
        AccountId = "000000000000",
        RoleName = "ExampleRole",
        ResourceRegion = "eu-central-1",
        InstanceTagKey = "Name",
        InstanceTagValue = "example-workstation",
        LocalPort = 8443,
        RemotePort = 8443,
    };
}
