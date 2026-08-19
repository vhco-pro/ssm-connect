using System.Text.Json;
using System.Text.Json.Nodes;
using SSMConnect.Domain;

namespace SSMConnect.Domain.Tests;

/// <summary>
/// Imports documents the macOS exporter actually produced.
/// </summary>
/// <remarks>
/// This is the half of AC-03 that neither client can satisfy alone. Both already round-trip their
/// own output and both validate against the schema, but agreeing with a schema separately is not
/// the same as agreeing with each other. These files came out of the other implementation, so
/// anything this client assumes and the schema does not require shows up here and nowhere else.
/// </remarks>
public sealed class ExchangeImportTests
{
    private static string ExchangeDirectory =>
        Path.Combine(AppContext.BaseDirectory, "contracts", "fixtures", "exchange");

    private static string Read(string fileName) =>
        File.ReadAllText(Path.Combine(ExchangeDirectory, fileName));

    public static TheoryData<string> ExchangeDocuments()
    {
        var data = new TheoryData<string>();
        foreach (string path in Directory.GetFiles(ExchangeDirectory, "*.json")
                     .OrderBy(p => p, StringComparer.Ordinal))
        {
            data.Add(Path.GetFileName(path));
        }

        return data;
    }

    [Fact]
    public void TheExchangeDocumentsAreAvailable() =>
        Assert.True(Directory.GetFiles(ExchangeDirectory, "macos-exported-*.json").Length >= 2,
            $"Expected the macOS exporter output in '{ExchangeDirectory}'.");

    [Theory]
    [MemberData(nameof(ExchangeDocuments))]
    public void ImportsADocumentTheOtherClientProduced(string fileName)
    {
        PortableProfileDocument document = ProfilePortability.Import(Read(fileName));

        Assert.Equal(PortableProfileDocument.CurrentSchemaVersion, document.SchemaVersion);
        Assert.NotEqual(Guid.Empty, document.Id);
        Assert.NotEmpty(document.Name);
        Assert.True(AwsRegion.IsValid(document.SsoRegion));
        Assert.True(AwsRegion.IsValid(document.ResourceRegion));
        Assert.Equal(PortableProfileDocument.DcvViewerAction, document.ConnectAction);

        // Nothing the other client wrote should land in the unknown bucket. If it does, this client
        // is missing a field the schema defines.
        Assert.Empty(document.UnknownFields);
    }

    [Fact]
    public void ImportsTheSingleUserDocument()
    {
        ConnectionProfile profile = ProfilePortability.ImportProfile(Read("macos-exported-single-user.json"));

        Assert.Equal(Guid.Parse("44444444-4444-4444-8444-444444444444"), profile.Id);
        Assert.Equal("Exported From macOS", profile.Name);
        Assert.Equal("https://d-0000000000.awsapps.com/start", profile.SsoStartUrl);
        Assert.Equal("eu-west-1", profile.SsoRegion);
        Assert.Equal("000000000000", profile.AccountId);
        Assert.Equal("ExampleWorkstationRole", profile.RoleName);
        Assert.Equal("eu-central-1", profile.ResourceRegion);
        Assert.Equal("Name", profile.InstanceTagKey);
        Assert.Equal("example-workstation-su", profile.InstanceTagValue);
        Assert.Equal(ConnectMode.SingleUser, profile.ConnectMode);
        Assert.Equal("example/dcv/password", profile.SecretId);
        Assert.Equal(8443, profile.LocalPort);
        Assert.Equal(8443, profile.RemotePort);
        Assert.True(profile.IsConfigured);
    }

    /// <summary>
    /// The interesting one. This document omits <c>secretId</c> entirely rather than writing an
    /// explicit null, so an importer that assumes the key is present-and-null breaks on it — and
    /// only on a document that crossed from another client.
    /// </summary>
    [Fact]
    public void ImportsTheMultiUserDocumentWhereSecretIdIsAbsentRatherThanNull()
    {
        string json = Read("macos-exported-multi-user.json");

        // The premise of this test, asserted rather than assumed: the key really is missing.
        Assert.False(((JsonObject)JsonNode.Parse(json)!).ContainsKey("secretId"));

        ConnectionProfile profile = ProfilePortability.ImportProfile(json);

        Assert.Equal(Guid.Parse("55555555-5555-4555-8555-555555555555"), profile.Id);
        Assert.Equal(ConnectMode.MultiUser, profile.ConnectMode);
        Assert.Null(profile.SecretId);
        Assert.Equal(8444, profile.AgentRemotePort);
        Assert.Equal(8444, profile.ResolvedAgentRemotePort);
        Assert.Equal("example-workstation-mu", profile.InstanceTagValue);
        Assert.True(profile.IsConfigured);
    }

    /// <summary>
    /// Re-exporting must not add a key the source did not have. Writing <c>"secretId": null</c>
    /// back would be a silent rewrite of the other client's document.
    /// </summary>
    [Fact]
    public void ReExportingAMultiUserDocumentDoesNotInventASecretIdKey()
    {
        PortableProfileDocument imported = ProfilePortability.Import(Read("macos-exported-multi-user.json"));
        var reExported = (JsonObject)JsonNode.Parse(ProfilePortability.Export(imported))!;

        Assert.False(reExported.ContainsKey("secretId"));
        Assert.Equal("multiUser", reExported["connectMode"]!.GetValue<string>());
        Assert.Equal(8444, reExported["agentRemotePort"]!.GetValue<int>());
    }

    /// <summary>
    /// A document that crossed once must survive crossing back, or the two clients agree only in
    /// one direction.
    /// </summary>
    [Theory]
    [MemberData(nameof(ExchangeDocuments))]
    public void SurvivesARoundTripThroughThisClient(string fileName)
    {
        PortableProfileDocument first = ProfilePortability.Import(Read(fileName));
        PortableProfileDocument second = ProfilePortability.Import(ProfilePortability.Export(first));

        Assert.Equal(first.Id, second.Id);
        Assert.Equal(first.Name, second.Name);
        Assert.Equal(first.ConnectMode, second.ConnectMode);
        Assert.Equal(first.SecretId, second.SecretId);
        Assert.Equal(first.AgentRemotePort, second.AgentRemotePort);
        Assert.Equal(first.LocalPort, second.LocalPort);
        Assert.Equal(first.RemotePort, second.RemotePort);
        Assert.Equal(first.AccountId, second.AccountId);
        Assert.Equal(first.SsoStartUrl, second.SsoStartUrl);
    }

    /// <summary>
    /// The security clause applies to a document from another client exactly as it does to any
    /// other. A trusted source is not an exemption.
    /// </summary>
    [Fact]
    public void RejectsAnExchangeDocumentThatGrewCredentialMaterial()
    {
        var tampered = (JsonObject)JsonNode.Parse(Read("macos-exported-single-user.json"))!;
        tampered["sessionToken"] = "should-never-be-imported";

        Assert.Throws<ProfilePortabilityException>(() => ProfilePortability.Import(tampered.ToJsonString()));
    }
}
