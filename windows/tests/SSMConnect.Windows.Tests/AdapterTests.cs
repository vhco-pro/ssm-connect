using System.Net;
using System.Text.Json;
using SSMConnect.Aws;
using SSMConnect.Domain;
using SSMConnect.Windows;
using SSMConnect.Workflow;

namespace SSMConnect.Windows.Tests;

/// <summary>
/// Covers adapter behavior that does not need live AWS. The parts that do — the SSO browser
/// fallback, a real tunnel, a real DCV session — are exercised by the development harness against
/// real infrastructure, because a mock of them would only assert the mock.
/// </summary>
public sealed class StsPresignerTests
{
    private static readonly AwsCredentials Credentials =
        new("ASIAEXAMPLEEXAMPLE01", "synthetic-secret-key", "synthetic-session-token", null);

    private static readonly DateTimeOffset FixedTime =
        new(2026, 8, 19, 12, 0, 0, TimeSpan.Zero);

    [Fact]
    public void ProducesADeterministicSignatureForAFixedInput()
    {
        string first = StsPresigner.Presign(Credentials, "eu-central-1", FixedTime);
        string second = StsPresigner.Presign(Credentials, "eu-central-1", FixedTime);

        Assert.Equal(first, second);
    }

    [Fact]
    public void SignsForTheRegionalStsEndpoint() =>
        Assert.StartsWith("https://sts.eu-central-1.amazonaws.com/?",
            StsPresigner.Presign(Credentials, "eu-central-1", FixedTime), StringComparison.Ordinal);

    [Fact]
    public void CarriesTheParametersTheAgentVerifies()
    {
        string url = StsPresigner.Presign(Credentials, "eu-central-1", FixedTime);

        Assert.Contains("Action=GetCallerIdentity", url, StringComparison.Ordinal);
        Assert.Contains("X-Amz-Algorithm=AWS4-HMAC-SHA256", url, StringComparison.Ordinal);
        Assert.Contains("X-Amz-SignedHeaders=host", url, StringComparison.Ordinal);
        Assert.Contains("X-Amz-Security-Token=", url, StringComparison.Ordinal);
        Assert.Contains("X-Amz-Signature=", url, StringComparison.Ordinal);
    }

    /// <summary>
    /// SigV4 canonicalisation is byte-exact, so the query must be sorted. A signature over an
    /// unsorted query verifies locally and is rejected by STS.
    /// </summary>
    [Fact]
    public void OrdersTheCanonicalQueryForSignatureStability()
    {
        string url = StsPresigner.Presign(Credentials, "eu-central-1", FixedTime);
        string query = url[(url.IndexOf('?', StringComparison.Ordinal) + 1)..];
        string[] keys = query.Split('&')
            .Select(pair => pair.Split('=')[0])
            .Where(key => key != "X-Amz-Signature")
            .ToArray();

        Assert.Equal(keys.Order(StringComparer.Ordinal), keys);
    }

    /// <summary>The token is short-lived by design: it is minted per use and never stored.</summary>
    [Fact]
    public void RequestsAShortExpiry() =>
        Assert.Contains($"X-Amz-Expires={StsPresigner.DefaultExpirySeconds}",
            StsPresigner.Presign(Credentials, "eu-central-1", FixedTime), StringComparison.Ordinal);

    [Fact]
    public void ADifferentSecretProducesADifferentSignature()
    {
        string a = StsPresigner.Presign(Credentials, "eu-central-1", FixedTime);
        string b = StsPresigner.Presign(Credentials with { SecretAccessKey = "another-secret" },
            "eu-central-1", FixedTime);

        Assert.NotEqual(a, b);
    }

    [Fact]
    public void OmitsTheSecurityTokenWhenThereIsNone() =>
        Assert.DoesNotContain("X-Amz-Security-Token",
            StsPresigner.Presign(Credentials with { SessionToken = "" }, "eu-central-1", FixedTime),
            StringComparison.Ordinal);
}

public sealed class AwsErrorTranslationTests
{
    [Theory]
    [InlineData("ExpiredToken")]
    [InlineData("ExpiredTokenException")]
    [InlineData("RequestExpired")]
    [InlineData("UnauthorizedAccess")]
    public void ExpiryIsTranslatedSoTheWorkflowCanRecover(string errorCode)
    {
        var sdkError = new Amazon.Runtime.AmazonServiceException("expired") { ErrorCode = errorCode };

        Exception translated = AwsErrors.Translate(sdkError);

        Assert.IsType<ExpiredCredentialsException>(translated);
        Assert.Equal(ErrorCategory.Authentication, ErrorCategories.Classify(translated));
    }

    /// <summary>
    /// Anything that is not expiry must not be retried as if it were, or a permissions problem
    /// would loop through re-authentication instead of being reported.
    /// </summary>
    [Fact]
    public void ANonExpiryServiceErrorBecomesAnAwsFailure()
    {
        var sdkError = new Amazon.Runtime.AmazonServiceException("No access")
        {
            ErrorCode = "AccessDenied",
            StatusCode = HttpStatusCode.Forbidden,
        };

        Exception translated = AwsErrors.Translate(sdkError);

        Assert.IsType<AwsServiceException>(translated);
        Assert.Equal(ErrorCategory.Aws, ErrorCategories.Classify(translated));
        Assert.Contains("AccessDenied", translated.Message, StringComparison.Ordinal);
        Assert.Contains("HTTP 403", translated.Message, StringComparison.Ordinal);
    }

    /// <summary>A domain error passing back through the adapter must not be reclassified.</summary>
    [Fact]
    public void ADomainErrorPassesThroughUnchanged()
    {
        var original = new InstanceTerminatedException("i-0aaaaaaaaaaaaaaa1");
        Assert.Same(original, AwsErrors.Translate(original));
    }

    [Fact]
    public void AnUnrelatedExceptionIsLeftAloneRatherThanMislabelled()
    {
        var original = new InvalidOperationException("boom");
        Assert.Same(original, AwsErrors.Translate(original));
    }
}

public sealed class WorkstationAgentClientTests
{
    /// <summary>
    /// The retry-versus-propagate distinction the workflow depends on: an agent that answers has
    /// made a decision, and a multi-user host is identity-only, so it must never be retried into a
    /// fallback.
    /// </summary>
    [Fact]
    public async Task AnAgentResponseIsNotTransient()
    {
        using var listener = new StubAgent(HttpStatusCode.Unauthorized, "{\"error\":\"denied\"}");
        using var client = new WorkstationAgentClient();

        var error = await Assert.ThrowsAsync<AgentException>(
            () => client.EnsureSessionAsync(listener.Port, "synthetic-token", TestContext.Current.CancellationToken));

        Assert.True(error.Responded);
        Assert.Equal(ErrorCategory.Agent, ErrorCategories.Classify(error));
    }

    /// <summary>
    /// Nothing listening is transient: the tunnel may still be settling, and ensure-session is
    /// idempotent, so the workflow retries it.
    /// </summary>
    [Fact]
    public async Task AnUnreachableAgentIsTransient()
    {
        int unusedPort = StubAgent.FindFreePort();
        using var client = new WorkstationAgentClient();

        var error = await Assert.ThrowsAsync<AgentException>(
            () => client.EnsureSessionAsync(unusedPort, "synthetic-token", TestContext.Current.CancellationToken));

        Assert.False(error.Responded);
    }

    [Fact]
    public async Task ReadsTheProvisionedSession()
    {
        using var listener = new StubAgent(
            HttpStatusCode.OK, "{\"user\":\"example.user\",\"sessionId\":\"example.user-session\"}");
        using var client = new WorkstationAgentClient();

        EnsureSessionResult result = await client.EnsureSessionAsync(
            listener.Port, "synthetic-token", TestContext.Current.CancellationToken);

        Assert.Equal("example.user", result.User);
        Assert.Equal("example.user-session", result.SessionId);
    }

    [Fact]
    public async Task RejectsAnIncompleteSession()
    {
        using var listener = new StubAgent(HttpStatusCode.OK, "{\"user\":\"example.user\"}");
        using var client = new WorkstationAgentClient();

        var error = await Assert.ThrowsAsync<AgentException>(
            () => client.EnsureSessionAsync(listener.Port, "synthetic-token", TestContext.Current.CancellationToken));

        Assert.True(error.Responded);
    }

    /// <summary>A loopback HTTP listener standing in for the on-box agent.</summary>
    private sealed class StubAgent : IDisposable
    {
        private readonly HttpListener _listener = new();

        internal StubAgent(HttpStatusCode status, string body)
        {
            Port = FindFreePort();
            _listener.Prefixes.Add($"http://127.0.0.1:{Port}/");
            _listener.Start();

            _ = Task.Run(async () =>
            {
                try
                {
                    HttpListenerContext context = await _listener.GetContextAsync().ConfigureAwait(false);
                    context.Response.StatusCode = (int)status;
                    context.Response.ContentType = "application/json";
                    byte[] payload = System.Text.Encoding.UTF8.GetBytes(body);
                    await context.Response.OutputStream.WriteAsync(payload).ConfigureAwait(false);
                    context.Response.Close();
                }
                catch (Exception)
                {
                    // The listener was disposed while waiting; that is the normal end of the stub.
                }
            });
        }

        internal int Port { get; }

        internal static int FindFreePort()
        {
            using var probe = new System.Net.Sockets.TcpListener(IPAddress.Loopback, 0);
            probe.Start();
            int port = ((IPEndPoint)probe.LocalEndpoint).Port;
            probe.Stop();
            return port;
        }

        public void Dispose() => _listener.Close();
    }
}

public sealed class FileInstanceIdStoreTests
{
    [Fact]
    public void RemembersTheLastInstancePerProfileAcrossRestarts()
    {
        string path = Path.Combine(Path.GetTempPath(), $"ssm-connect-test-{Guid.NewGuid():N}.json");
        try
        {
            Guid profile = Guid.NewGuid();
            Guid other = Guid.NewGuid();

            var store = new FileInstanceIdStore(path);
            Assert.Null(store.LastInstanceId(profile));

            store.SetLastInstanceId(profile, "i-0aaaaaaaaaaaaaaa1");
            store.SetLastInstanceId(other, "i-0bbbbbbbbbbbbbbb2");

            // A fresh instance reads what the previous one wrote, which is what replacement
            // detection depends on after a restart.
            var reopened = new FileInstanceIdStore(path);
            Assert.Equal("i-0aaaaaaaaaaaaaaa1", reopened.LastInstanceId(profile));
            Assert.Equal("i-0bbbbbbbbbbbbbbb2", reopened.LastInstanceId(other));
        }
        finally
        {
            File.Delete(path);
        }
    }

    /// <summary>The store holds an instance ID and nothing else; it must never become a secret store.</summary>
    [Fact]
    public void StoresOnlyInstanceIdentifiers()
    {
        string path = Path.Combine(Path.GetTempPath(), $"ssm-connect-test-{Guid.NewGuid():N}.json");
        try
        {
            new FileInstanceIdStore(path).SetLastInstanceId(Guid.NewGuid(), "i-0aaaaaaaaaaaaaaa1");
            JsonDocument document = JsonDocument.Parse(File.ReadAllText(path));

            foreach (JsonProperty property in document.RootElement.EnumerateObject())
            {
                Assert.Equal(JsonValueKind.String, property.Value.ValueKind);
                Assert.StartsWith("i-", property.Value.GetString(), StringComparison.Ordinal);
            }
        }
        finally
        {
            File.Delete(path);
        }
    }
}

public sealed class DcvViewerLauncherTests
{
    /// <summary>
    /// The certificate-validation policy is a deliberate, narrow exception. Pinning the exact
    /// argument here means a change to it has to be a change to this test too.
    /// </summary>
    [Fact]
    public void PinsTheCertificateValidationPolicy() =>
        Assert.Equal("--certificate-validation-policy=accept-untrusted",
            DcvViewerLauncher.AcceptUntrustedArgument);

    [Fact]
    public void OwnsItsConnectionFileDirectoryUnderLocalAppData()
    {
        string expectedRoot = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        Assert.StartsWith(expectedRoot, DcvViewerLauncher.ConnectionFileDirectory, StringComparison.Ordinal);
        Assert.Contains("SSM Connect", DcvViewerLauncher.ConnectionFileDirectory, StringComparison.Ordinal);
    }

    /// <summary>
    /// Sweeping must be bounded by age as well as by name, or a launch in flight would have its own
    /// file deleted out from under the viewer.
    /// </summary>
    [Fact]
    public void SweepsOnlyItsOwnFilesAndOnlyOldOnes()
    {
        Directory.CreateDirectory(DcvViewerLauncher.ConnectionFileDirectory);

        string old = Path.Combine(DcvViewerLauncher.ConnectionFileDirectory,
            $"{DcvConnectionFile.TempFilePrefix}sweep-old.{DcvConnectionFile.FileExtension}");
        string fresh = Path.Combine(DcvViewerLauncher.ConnectionFileDirectory,
            $"{DcvConnectionFile.TempFilePrefix}sweep-fresh.{DcvConnectionFile.FileExtension}");
        string foreign = Path.Combine(DcvViewerLauncher.ConnectionFileDirectory, "someone-else.dcv");

        try
        {
            File.WriteAllText(old, "x");
            File.WriteAllText(fresh, "x");
            File.WriteAllText(foreign, "x");
            File.SetLastWriteTimeUtc(old, DateTime.UtcNow - DcvViewerLauncher.OrphanAge - TimeSpan.FromMinutes(5));

            new DcvViewerLauncher(viewerPath: "unused").SweepOrphanedFiles();

            Assert.False(File.Exists(old));
            Assert.True(File.Exists(fresh));
            Assert.True(File.Exists(foreign));
        }
        finally
        {
            foreach (string path in new[] { old, fresh, foreign })
            {
                File.Delete(path);
            }
        }
    }

    /// <summary>
    /// The viewer is resolved through its file association rather than a hardcoded path. This host
    /// has it installed, which is the case that matters; a host without it must report absence
    /// rather than throw.
    /// </summary>
    [Fact]
    public void ReportsViewerPresenceWithoutThrowingEitherWay()
    {
        string? discovered = DcvViewerLauncher.DiscoverViewerPath();
        var launcher = new DcvViewerLauncher();

        if (discovered is null)
        {
            Assert.False(launcher.IsViewerInstalled());
            return;
        }

        Assert.EndsWith("dcvviewer.exe", discovered, StringComparison.OrdinalIgnoreCase);
        Assert.True(launcher.IsViewerInstalled());
    }
}

public sealed class PluginTunnelProviderTests
{
    [Fact]
    public void ReportsWhetherThePluginIsPresent()
    {
        var provider = new PluginTunnelProvider();
        Assert.Equal(File.Exists(PluginTunnelProvider.DiscoverPluginPath()), provider.IsPluginAvailable);
    }

    /// <summary>
    /// An installed release ships its own plugin and must use it, because that is the version the
    /// release was tested against and the one its redistribution files describe.
    /// </summary>
    [Fact]
    public void PrefersTheBundledPluginOverASystemInstallation()
    {
        string directory = Path.GetDirectoryName(Environment.ProcessPath)!;
        string bundled = Path.Combine(directory, PluginTunnelProvider.BundledPluginRelativePath);

        Assert.Equal(
            File.Exists(bundled) ? bundled : PluginTunnelProvider.SystemPluginPath,
            PluginTunnelProvider.DiscoverPluginPath());
    }

    /// <summary>The bundled path is relative to the app, so an installed copy resolves beside it.</summary>
    [Fact]
    public void LooksForTheBundledPluginBesideTheApplication() =>
        Assert.Equal(PluginTunnelProvider.BundledPluginRelativePath,
            Path.Combine("session-manager-plugin", "session-manager-plugin.exe"));

    [Fact]
    public async Task ReportsAMissingPluginAsATunnelFailure()
    {
        var provider = new PluginTunnelProvider(pluginPath: @"C:\does\not\exist\session-manager-plugin.exe");

        var error = await Assert.ThrowsAsync<TunnelException>(() => provider.StartTunnelAsync(
            new SsmSession("synthetic"), "eu-central-1", "i-0aaaaaaaaaaaaaaa1", 58443, 8443,
            TestContext.Current.CancellationToken));

        Assert.Equal(ErrorCategory.Tunnel, ErrorCategories.Classify(error));
    }
}
