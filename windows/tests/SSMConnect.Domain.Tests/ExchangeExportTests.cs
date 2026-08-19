using SSMConnect.Domain;

namespace SSMConnect.Domain.Tests;

/// <summary>
/// Produces this client's side of the AC-03 exchange, and keeps the committed documents honest.
/// </summary>
/// <remarks>
/// The files in <c>contracts/fixtures/exchange</c> are exporter output, not hand-authored fixtures.
/// If they were maintained by hand they would drift from the exporter and stop proving anything, so
/// this test regenerates them and fails when they differ. Changing the exporter therefore fails
/// here until the documents are regenerated, exactly as the macOS side arranged for its own.
/// </remarks>
public sealed class ExchangeExportTests
{
    /// <summary>
    /// Written to the repository rather than the build output: these documents are meant to be
    /// committed and read by the other client.
    /// </summary>
    private static string ExchangeSourceDirectory
    {
        get
        {
            // Walk up to the repository root. The marker is deliberately both directories: the
            // build output also contains a copied "contracts" folder, and matching on that alone
            // writes the documents into bin where nobody will ever commit them.
            var directory = new DirectoryInfo(AppContext.BaseDirectory);
            while (directory is not null
                   && !(Directory.Exists(Path.Combine(directory.FullName, "contracts"))
                        && Directory.Exists(Path.Combine(directory.FullName, "windows"))))
            {
                directory = directory.Parent;
            }

            return directory is null
                ? throw new InvalidOperationException("Could not locate the contracts directory.")
                : Path.Combine(directory.FullName, "contracts", "fixtures", "exchange");
        }
    }

    public static TheoryData<string> Samples()
    {
        var data = new TheoryData<string>();
        foreach (string name in SampleProfiles.Keys.Order(StringComparer.Ordinal))
        {
            data.Add(name);
        }

        return data;
    }

    private static Dictionary<string, ConnectionProfile> SampleProfiles => new(StringComparer.Ordinal)
    {
        ["dotnet-exported-single-user.json"] = new ConnectionProfile
        {
            Id = Guid.Parse("66666666-6666-4666-8666-666666666666"),
            Name = "Exported From Windows",
            SsoStartUrl = "https://d-0000000000.awsapps.com/start",
            SsoRegion = "eu-west-1",
            AccountId = "000000000000",
            RoleName = "ExampleWorkstationRole",
            ResourceRegion = "eu-central-1",
            InstanceTagKey = "Name",
            InstanceTagValue = "example-workstation-su",
            ConnectMode = ConnectMode.SingleUser,
            SecretId = "example/dcv/password",
            LocalPort = 8443,
            RemotePort = 8443,
        },

        ["dotnet-exported-multi-user.json"] = new ConnectionProfile
        {
            Id = Guid.Parse("77777777-7777-4777-8777-777777777777"),
            Name = "Exported From Windows (Multi-User)",
            SsoStartUrl = "https://d-0000000000.awsapps.com/start",
            SsoRegion = "eu-west-1",
            AccountId = "000000000000",
            RoleName = "ExampleWorkstationRole",
            ResourceRegion = "eu-central-1",
            InstanceTagKey = "Name",
            InstanceTagValue = "example-workstation-mu",
            ConnectMode = ConnectMode.MultiUser,
            AgentRemotePort = 8444,
            SecretId = null,
            LocalPort = 8443,
            RemotePort = 8443,
        },

        // The mirror of the trap macOS set for this client. A profile stored before the connect-mode
        // field existed has no such key, and neither does its export. An importer that requires
        // connectMode, or that resolves it to "singleUser" on the way out, breaks on this and on
        // nothing else.
        ["dotnet-exported-legacy-no-connect-mode.json"] = new ConnectionProfile
        {
            Id = Guid.Parse("88888888-8888-4888-8888-888888888888"),
            Name = "Exported From Windows (Legacy, No Connect Mode)",
            SsoStartUrl = "https://d-0000000000.awsapps.com/start",
            SsoRegion = "eu-west-1",
            AccountId = "000000000000",
            RoleName = "ExampleWorkstationRole",
            ResourceRegion = "eu-central-1",
            InstanceTagKey = "Name",
            InstanceTagValue = "example-workstation-legacy",
            ConnectMode = null,
            AgentRemotePort = null,
            SecretId = "example/dcv/password",
            LocalPort = 8443,
            RemotePort = 8443,
        },
    };

    [Theory]
    [MemberData(nameof(Samples))]
    public void TheCommittedDocumentMatchesWhatThisClientExports(string fileName)
    {
        string expected = ProfilePortability.Export(SampleProfiles[fileName]);
        string path = Path.Combine(ExchangeSourceDirectory, fileName);

        if (!File.Exists(path))
        {
            Directory.CreateDirectory(ExchangeSourceDirectory);
            File.WriteAllText(path, expected + Environment.NewLine);
            Assert.Fail($"Generated the missing exchange document '{fileName}'. Review it and re-run.");
        }

        string actual = File.ReadAllText(path);
        if (!string.Equals(Normalise(actual), Normalise(expected), StringComparison.Ordinal))
        {
            File.WriteAllText(path, expected + Environment.NewLine);
            Assert.Fail(
                $"The committed exchange document '{fileName}' no longer matches the exporter. " +
                "It has been regenerated; review the diff and re-run.");
        }
    }

    /// <summary>The documents cross platforms, so a line-ending difference is not a real difference.</summary>
    private static string Normalise(string value) => value.Replace("\r\n", "\n", StringComparison.Ordinal).Trim();

    /// <summary>
    /// The legacy sample only earns its place if the key really is absent, so that is asserted
    /// rather than trusted.
    /// </summary>
    [Fact]
    public void TheLegacySampleOmitsConnectModeEntirely()
    {
        string exported = ProfilePortability.Export(SampleProfiles["dotnet-exported-legacy-no-connect-mode.json"]);

        Assert.DoesNotContain("connectMode", exported, StringComparison.Ordinal);
        Assert.DoesNotContain("agentRemotePort", exported, StringComparison.Ordinal);
        Assert.Equal(ConnectMode.SingleUser, ProfilePortability.ImportProfile(exported).ResolvedConnectMode);
    }

    [Fact]
    public void TheMultiUserSampleOmitsSecretIdEntirely() =>
        Assert.DoesNotContain("secretId",
            ProfilePortability.Export(SampleProfiles["dotnet-exported-multi-user.json"]),
            StringComparison.Ordinal);
}
