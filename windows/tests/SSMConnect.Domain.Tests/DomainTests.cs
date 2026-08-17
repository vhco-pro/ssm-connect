using SSMConnect.Domain;

namespace SSMConnect.Domain.Tests;

/// <summary>
/// Covers the domain rules the workflow fixtures cannot reach, because they are about rendering and
/// validation rather than orchestration.
/// </summary>
public sealed class AwsRegionTests
{
    [Theory]
    [InlineData("eu-central-1")]
    [InlineData("us-east-1")]
    [InlineData("ap-southeast-2")]
    [InlineData("a")]
    public void AcceptsValidRegions(string region) => Assert.True(AwsRegion.IsValid(region));

    [Theory]
    [InlineData("")]
    [InlineData("-eu-central-1")]
    [InlineData("eu-central-1-")]
    [InlineData("eu_central_1")]
    [InlineData("eu central 1")]
    public void RejectsMalformedRegions(string region) => Assert.False(AwsRegion.IsValid(region));

    [Fact]
    public void RejectsNull() => Assert.False(AwsRegion.IsValid(null));

    /// <summary>
    /// Surrounding whitespace makes a region invalid, deliberately: the SDK would reject it too, so
    /// silently trimming here would hide a profile the user needs to fix.
    /// </summary>
    [Fact]
    public void TreatsSurroundingWhitespaceAsInvalid()
    {
        Assert.False(AwsRegion.IsValid(" eu-central-1 "));
        Assert.True(AwsRegion.IsValid(AwsRegion.Normalize(" eu-central-1 ")));
    }

    [Fact]
    public void RejectsRegionsLongerThanTheSdkAllows() =>
        Assert.False(AwsRegion.IsValid(new string('a', 64)));
}

public sealed class DcvConnectionFileTests
{
    [Fact]
    public void SingleUserRendersPasswordAndNoTokenFields()
    {
        string ini = DcvConnectionFile.SingleUser(8443, "synthetic-password").ToIni();

        Assert.Contains("host=127.0.0.1", ini, StringComparison.Ordinal);
        Assert.Contains("port=8443", ini, StringComparison.Ordinal);
        Assert.Contains("user=ec2-user", ini, StringComparison.Ordinal);
        Assert.Contains("password=synthetic-password", ini, StringComparison.Ordinal);
        Assert.DoesNotContain("authtoken=", ini, StringComparison.Ordinal);
        Assert.DoesNotContain("sessionid=", ini, StringComparison.Ordinal);
    }

    [Fact]
    public void MultiUserRendersTokenAndSessionButNeverAPassword()
    {
        string ini = DcvConnectionFile
            .MultiUser(8443, "example.user", "example-session", "synthetic-token").ToIni();

        Assert.Contains("user=example.user", ini, StringComparison.Ordinal);
        Assert.Contains("sessionid=example-session", ini, StringComparison.Ordinal);
        Assert.Contains("authtoken=synthetic-token", ini, StringComparison.Ordinal);
        Assert.DoesNotContain("password=", ini, StringComparison.Ordinal);
    }

    /// <summary>
    /// The host must stay the IPv4 literal. Using <c>localhost</c> lets it resolve to ::1 first,
    /// where the IPv4-only port-forward has no listener and the viewer reports an unreachable
    /// endpoint.
    /// </summary>
    [Fact]
    public void AlwaysUsesTheIpv4LoopbackLiteral()
    {
        Assert.Equal("127.0.0.1", DcvConnectionFile.SingleUser(8443, "x").Host);
        Assert.DoesNotContain("localhost", DcvConnectionFile.SingleUser(8443, "x").ToIni(), StringComparison.Ordinal);
    }

    [Fact]
    public void StartsWithTheVersionHeaderTheViewerExpects() =>
        Assert.StartsWith("[version]\nformat=1.0\n\n[connect]\n",
            DcvConnectionFile.SingleUser(8443, "x").ToIni(), StringComparison.Ordinal);
}

public sealed class ConnectionProfileTests
{
    private static ConnectionProfile Configured() => new()
    {
        Id = Guid.Parse("11111111-1111-4111-8111-111111111111"),
        Name = "Example",
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

    [Fact]
    public void AConfiguredProfileIsConnectable() => Assert.True(Configured().IsConfigured);

    [Theory]
    [InlineData("InstanceTagValue")]
    [InlineData("RoleName")]
    [InlineData("SsoStartUrl")]
    public void AnEmptyRequiredFieldMakesTheProfileUnconfigured(string field)
    {
        ConnectionProfile profile = field switch
        {
            "InstanceTagValue" => Configured() with { InstanceTagValue = "" },
            "RoleName" => Configured() with { RoleName = "" },
            _ => Configured() with { SsoStartUrl = "" },
        };

        Assert.False(profile.IsConfigured);
    }

    [Fact]
    public void AMalformedRegionMakesTheProfileUnconfigured() =>
        Assert.False((Configured() with { ResourceRegion = "eu-central-1-" }).IsConfigured);

    /// <summary>
    /// A profile written before the connect-mode field existed must keep working, so an absent mode
    /// resolves to single-user rather than failing or defaulting to the identity-only path.
    /// </summary>
    [Fact]
    public void AnAbsentConnectModeResolvesToSingleUser()
    {
        ConnectionProfile profile = Configured();
        Assert.Null(profile.ConnectMode);
        Assert.Equal(Domain.ConnectMode.SingleUser, profile.ResolvedConnectMode);
    }

    [Fact]
    public void AnAbsentAgentPortResolvesToTheDefault()
    {
        Assert.Equal(8444, Configured().ResolvedAgentRemotePort);
        Assert.Equal(9000, (Configured() with { AgentRemotePort = 9000 }).ResolvedAgentRemotePort);
    }
}

public sealed class StateAndErrorTests
{
    [Fact]
    public void EveryConnectionStateRoundTripsThroughItsWireName()
    {
        foreach (ConnectionState state in Enum.GetValues<ConnectionState>())
        {
            Assert.Equal(state, ConnectionStateNames.Parse(state.Wire()));
        }
    }

    [Fact]
    public void EveryInstanceStateRoundTripsThroughItsWireName()
    {
        foreach (Ec2InstanceState state in Enum.GetValues<Ec2InstanceState>())
        {
            Assert.Equal(state, Ec2InstanceStateNames.Parse(state.Wire()));
        }
    }

    /// <summary>An unmodelled EC2 state must degrade, not throw, or a new AWS value breaks connect.</summary>
    [Fact]
    public void AnUnknownInstanceStateDegradesToUnknown() =>
        Assert.Equal(Ec2InstanceState.Unknown, Ec2InstanceStateNames.Parse("some-future-state"));

    [Theory]
    [InlineData(Ec2InstanceState.Terminated, true)]
    [InlineData(Ec2InstanceState.ShuttingDown, true)]
    [InlineData(Ec2InstanceState.Stopped, false)]
    [InlineData(Ec2InstanceState.Running, false)]
    public void TerminalInstanceStatesAreNotConnectable(Ec2InstanceState state, bool terminal) =>
        Assert.Equal(terminal, state.IsTerminal());

    [Fact]
    public void EachDomainErrorReportsItsContractCategory()
    {
        Assert.Equal(ErrorCategory.Configuration, ErrorCategories.Classify(new ProfileConfigurationException("resource region", "x-")));
        Assert.Equal(ErrorCategory.Authentication, ErrorCategories.Classify(new ExpiredCredentialsException()));
        Assert.Equal(ErrorCategory.InstanceTerminated, ErrorCategories.Classify(new InstanceTerminatedException("i-0")));
        Assert.Equal(ErrorCategory.Timeout, ErrorCategories.Classify(new StageTimeoutException("Sign-in")));
        Assert.Equal(ErrorCategory.Tunnel, ErrorCategories.Classify(new TunnelException("dropped")));
        Assert.Equal(ErrorCategory.Readiness, ErrorCategories.Classify(DcvReadinessException.DcvServerNotReady(8443)));
        Assert.Equal(ErrorCategory.Agent, ErrorCategories.Classify(new AgentException("401", responded: true)));
        Assert.Equal(ErrorCategory.Aws, ErrorCategories.Classify(new AwsServiceException("throttled")));
    }

    /// <summary>
    /// An unmodelled exception must not be silently classified as an AWS error, or a genuine bug
    /// would be reported to users as a service problem.
    /// </summary>
    [Fact]
    public void AnUnmodelledExceptionIsUnknown() =>
        Assert.Equal(ErrorCategory.Unknown, ErrorCategories.Classify(new InvalidOperationException("boom")));

    /// <summary>The message must name the field and the offending value; that is its whole purpose.</summary>
    [Fact]
    public void AConfigurationErrorNamesTheFieldAndValue()
    {
        var error = new ProfileConfigurationException("resource region", "eu-central-1-");
        Assert.Contains("resource region", error.Message, StringComparison.Ordinal);
        Assert.Contains("eu-central-1-", error.Message, StringComparison.Ordinal);
    }

    /// <summary>
    /// The two readiness failures must stay distinct: they point the user at different problems.
    /// </summary>
    [Fact]
    public void ReadinessFailuresDistinguishTunnelFromServer()
    {
        Assert.False(DcvReadinessException.TunnelNotEstablished(8443).TunnelEstablished);
        Assert.True(DcvReadinessException.DcvServerNotReady(8443).TunnelEstablished);
    }
}
