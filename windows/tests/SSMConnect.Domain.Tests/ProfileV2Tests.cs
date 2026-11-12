using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using SSMConnect.Domain;

namespace SSMConnect.Domain.Tests;

public sealed class ProfileV2Tests
{
    [Fact]
    public void Cfg02AndCfg09SharedSchemaInvalidShapesFailOnBothClients()
    {
        JsonArray cases = JsonNode.Parse(File.ReadAllText(Path.Combine(Fixtures, "v2-invalid-cases.json")))!.AsArray();
        foreach (JsonNode? test in cases)
        {
            JsonObject root = JsonNode.Parse(ProfilePortability.Export(Example()))!.AsObject();
            foreach (JsonNode? mutation in test!["mutations"]!.AsArray())
            {
                string[] path = mutation!["path"]!.AsArray().Select(part => part!.GetValue<string>()).ToArray();
                JsonNode current = root;
                foreach (string segment in path[..^1])
                {
                    current = current is JsonArray array ? array[int.Parse(segment, System.Globalization.CultureInfo.InvariantCulture)]! : current[segment]!;
                }
                JsonNode? value = mutation["value"]?.DeepClone();
                if (current is JsonArray target) { target[int.Parse(path[^1], System.Globalization.CultureInfo.InvariantCulture)] = value; }
                else { current[path[^1]] = value; }
            }
            Exception? error = Record.Exception(() => ProfilePortability.Import(root.ToJsonString()));
            Assert.True(error is ProfilePortabilityException, $"Expected an explicit profile error for '{test["name"]}'.");
        }
    }

    private static string Fixtures => Path.Combine(AppContext.BaseDirectory, "contracts", "fixtures", "profile-v2");
    private static PortableProfileDocument Example() => ProfilePortability.Import(
        File.ReadAllText(Path.Combine(Fixtures, "v2-current.json")));

    [Fact]
    public void Cfg02EquivalentYamlAndJsonPreserveEveryCapability()
    {
        PortableProfileDocument json = Example();
        PortableProfileDocument yaml = ProfilePortability.Import(
            File.ReadAllText(Path.Combine(Fixtures, "v2-current.yaml")), ProfileFileFormat.Yaml);
        Assert.Equal(ProfilePortability.Export(json), ProfilePortability.Export(yaml));
        ConnectionProfile native = json.ToProfile();
        Assert.Equal(ConnectAction.TunnelOnly, native.ConnectAction);
        Assert.True(native.WebForwards?.Enabled);
        Assert.True(native.RemoteDevelopment?.Enabled);
        Assert.NotNull(native.RemoteDevelopment);
        Assert.Equal("000000000000", native.AccountId);
        Assert.Equal("/home/example/code", native.RemoteDevelopment.Folder);
        Assert.Throws<ProfilePortabilityException>(() => json.EnsureSupported(new HashSet<string> { "tunnelOnly" }));
        Assert.Equal(json.Id, ProfilePortability.Import("\uFEFF" + ProfilePortability.Export(json)).Id);
    }

    [Fact]
    public void Cfg04GuiMappingRetainsNestedUnknownValuesAndPortableIdentity()
    {
        JsonObject root = JsonNode.Parse(ProfilePortability.Export(Example()))!.AsObject();
        root["futureNumber"] = JsonNode.Parse("9007199254740993");
        root["webForwards"]!["futureOption"] = "retain";
        root["webForwards"]!["localForwards"]![0]!["futureForwardOption"] = true;
        PortableProfileDocument original = ProfilePortability.Import(root.ToJsonString());
        ConnectionProfile native = original.ToProfile() with { Id = Guid.NewGuid(), Name = "Edited" };
        PortableProfileDocument edited = original.WithProfile(native);
        Assert.Equal(original.Id, edited.Id);
        string exported = ProfilePortability.Export(edited, ProfileFileFormat.Yaml);
        PortableProfileDocument reloaded = ProfilePortability.Import(exported, ProfileFileFormat.Yaml);
        Assert.Equal("retain", reloaded.WebForwards!["futureOption"]!.GetValue<string>());
        Assert.True(reloaded.WebForwards["localForwards"]![0]!["futureForwardOption"]!.GetValue<bool>());
        Assert.Equal("9007199254740993", reloaded.UnknownFields["futureNumber"]!.ToJsonString());
        Assert.Equal(exported, ProfilePortability.Export(reloaded, ProfileFileFormat.Yaml));
    }

    [Theory]
    [InlineData("1e127")]
    [InlineData("1e-128")]
    [InlineData("1.0e-128")]
    [InlineData("9007199254740993")]
    [InlineData("12345678901234567890123456789012345678")]
    public void Cfg02ScientificOptionalNumbersRoundTripWithoutRounding(string number)
    {
        JsonObject fields = JsonNode.Parse(ProfilePortability.Export(Example()))!.AsObject();
        fields["futureNumber"] = JsonNode.Parse(number);
        PortableProfileDocument document = ProfilePortability.Import(fields.ToJsonString());
        Assert.NotEqual("0", document.UnknownFields["futureNumber"]!.ToJsonString());
        foreach (ProfileFileFormat format in Enum.GetValues<ProfileFileFormat>())
        {
            string written = ProfilePortability.Export(document, format);
            PortableProfileDocument loaded = ProfilePortability.Import(written, format);
            Assert.Equal(document.UnknownFields["futureNumber"]!.ToJsonString(),
                loaded.UnknownFields["futureNumber"]!.ToJsonString());
        }
    }

    [Theory]
    [InlineData("x: !execute command")]
    [InlineData("x: &owned value\ny: *owned")]
    [InlineData("x: 1\nx: 2")]
    [InlineData("future:\n  Session_Token: do-not-log")]
    [InlineData("---\nx: 1\n---\nx: 2")]
    [InlineData("futureNumber: 1e128")]
    [InlineData("futureNumber: 1e-129")]
    public void Cfg09UnsafeYamlFailsExplicitlyWithoutEchoingCredentials(string extra)
    {
        string yaml = ProfilePortability.Export(Example(), ProfileFileFormat.Yaml);
        ProfilePortabilityException error = Assert.Throws<ProfilePortabilityException>(() =>
            ProfilePortability.Import(yaml + "\n" + extra, ProfileFileFormat.Yaml));
        Assert.DoesNotContain("do-not-log", error.Message, StringComparison.Ordinal);
    }

    [Fact]
    public void Cfg09ExactResourceBoundariesAreEnforced()
    {
        PortableProfileDocument document = Example();
        string json = ProfilePortability.Export(document);
        string padded = json + new string(' ', ProfileDocumentSyntax.MaximumBytes - Encoding.UTF8.GetByteCount(json));
        Assert.Equal(document.Id, ProfilePortability.Import(padded).Id);
        Assert.Throws<ProfilePortabilityException>(() => ProfilePortability.Import(padded + " "));
        string yaml = ProfilePortability.Export(document, ProfileFileFormat.Yaml);
        string Nested(int count) => yaml + "\nbudget: " + new string('[', count) + "0" + new string(']', count);
        Assert.NotNull(ProfilePortability.Import(Nested(31), ProfileFileFormat.Yaml).UnknownFields["budget"]);
        Assert.Throws<ProfilePortabilityException>(() => ProfilePortability.Import(Nested(32), ProfileFileFormat.Yaml));
        string many = yaml + "\nbudget: [" + string.Join(',', Enumerable.Repeat("0", ProfileDocumentSyntax.MaximumNodes)) + "]";
        Assert.Throws<ProfilePortabilityException>(() => ProfilePortability.Import(many, ProfileFileFormat.Yaml));
    }

    [Fact]
    public void Cfg09DuplicateJsonEscapedKeysAndKnownFieldOverridesFail()
    {
        string json = ProfilePortability.Export(Example());
        Assert.Throws<ProfilePortabilityException>(() => ProfilePortability.Import("{\"\\u006eame\":\"first\"," + json[1..]));
        Assert.Throws<ProfilePortabilityException>(() => ProfilePortability.Export(Example() with
        {
            UnknownFields = new Dictionary<string, JsonNode?> { ["name"] = JsonValue.Create("override") },
        }));
    }

    [Fact]
    public void Cfg03ExistingV1MigratesOnlyOnExplicitEditing()
    {
        string fixture = Path.Combine(AppContext.BaseDirectory, "contracts", "fixtures", "profiles", "single-user.json");
        PortableProfileDocument original = ProfilePortability.Import(File.ReadAllText(fixture));
        Assert.Equal(1, original.SchemaVersion);
        Assert.Equal(1, ProfilePortability.Import(ProfilePortability.Export(original)).SchemaVersion);
        Assert.Equal(2, original.WithProfile(original.ToProfile()).SchemaVersion);
    }

    [Fact]
    public void Cfg02ExportedV2DocumentIsAvailableForActualSwiftCrossing()
    {
        string directory = Path.Combine(AppContext.BaseDirectory, "artifacts", "exported-profiles-v2");
        Directory.CreateDirectory(directory);
        PortableProfileDocument document = Example();
        File.WriteAllText(Path.Combine(directory, "dotnet-v2-current.json"),
            ProfilePortability.Export(document.WithProfile(document.ToProfile() with { Id = Guid.NewGuid() })));
    }

    [Fact]
    public void Cfg02ImportsActualMacosV2ExportAndRetainsGuiDocumentIdentity()
    {
        PortableProfileDocument document = ProfilePortability.Import(
            File.ReadAllText(Path.Combine(Fixtures, "macos-v2-current.json")));
        Assert.Equal(ConnectAction.TunnelOnly, document.ToProfile().ConnectAction);
        Assert.True(document.ToProfile().WebForwards?.Enabled);
        Assert.True(document.ToProfile().RemoteDevelopment?.Enabled);
        PortableProfileDocument edited = document.WithProfile(document.ToProfile() with { Id = Guid.NewGuid(), Name = "Edited on Windows" });
        Assert.Equal(document.Id, edited.Id);
        Assert.Equal("preserve", edited.UnknownFields["futureOptional"]!["label"]!.GetValue<string>());
        Assert.Equal("Edited on Windows", ProfilePortability.Import(ProfilePortability.Export(edited)).Name);
    }
}
