using SSMConnect.Domain;

namespace SSMConnect.Domain.Tests;

/// <summary>
/// The identity rule is shared with the macOS client and with the workstation agent's Go
/// implementation. These cases mirror the macOS suite deliberately: a divergence here denies a
/// validated user their own session, which is the failure the reject-based design exists to prevent.
/// </summary>
public sealed class IdentityMapperTests
{
    [Theory]
    [InlineData("arn:aws:sts::000000000000:assumed-role/ExampleRole/alice", "alice")]
    [InlineData("arn:aws:sts::000000000000:assumed-role/ExampleRole/alice@example.com", "alice")]
    [InlineData("arn:aws:sts::000000000000:assumed-role/ExampleRole/Alice.Smith@example.com", null)]
    [InlineData("arn:aws:sts::000000000000:assumed-role/ExampleRole/bob_jones", "bob_jones")]
    [InlineData("arn:aws:sts::000000000000:assumed-role/ExampleRole/user-1", "user-1")]
    public void MapsAnArnToItsWorkstationUsername(string arn, string? expected)
    {
        if (expected is null)
        {
            Assert.Throws<IdentityMappingException>(() => IdentityMapper.UsernameFromArn(arn));
            return;
        }

        Assert.Equal(expected, IdentityMapper.UsernameFromArn(arn));
    }

    [Theory]
    [InlineData("arn:aws:sts::000000000000:assumed-role/ExampleRole/")]
    [InlineData("no-slash-at-all")]
    public void RejectsAnArnWithNoRoleSessionName(string arn) =>
        Assert.Throws<IdentityMappingException>(() => IdentityMapper.UsernameFromArn(arn));

    /// <summary>
    /// The rule rejects rather than transforms. Silently stripping a dot or truncating a long name
    /// could map two distinct identities onto one account, which is worse than refusing.
    /// </summary>
    [Theory]
    [InlineData("alice.smith")]
    [InlineData("1alice")]
    [InlineData("-alice")]
    [InlineData("alice smith")]
    [InlineData("alice$")]
    [InlineData("")]
    public void RejectsRatherThanTransformsAnUnsafeName(string raw) =>
        Assert.Throws<IdentityMappingException>(() => IdentityMapper.Sanitize(raw));

    [Fact]
    public void RejectsANameLongerThanTheAgentAccepts()
    {
        Assert.Equal(new string('a', 32), IdentityMapper.Sanitize(new string('a', 32)));
        Assert.Throws<IdentityMappingException>(() => IdentityMapper.Sanitize(new string('a', 33)));
    }

    [Theory]
    [InlineData("root")]
    [InlineData("ec2-user")]
    [InlineData("dcv")]
    [InlineData("ssm-user")]
    [InlineData("admin")]
    [InlineData("nobody")]
    public void RefusesReservedSystemAccounts(string reserved) =>
        Assert.Throws<IdentityMappingException>(() => IdentityMapper.Sanitize(reserved));

    /// <summary>
    /// The reserved list is contract with the agent, so it is pinned rather than merely spot-checked.
    /// </summary>
    [Fact]
    public void ThePinnedReservedListMatchesTheAgent()
    {
        string[] expected =
        [
            "root", "daemon", "bin", "sys", "sync", "games", "man", "lp", "mail", "news",
            "proxy", "www-data", "backup", "list", "nobody", "systemd-network", "dbus",
            "sshd", "rpc", "dcv", "dcvsmagent", "ec2-user", "ssm-user", "admin", "ubuntu", "centos",
        ];

        Assert.Equal(expected.Order(StringComparer.Ordinal), IdentityMapper.Reserved.Order(StringComparer.Ordinal));
    }

    /// <summary>Uppercase reduces to lowercase; that reduction is lossless and therefore allowed.</summary>
    [Fact]
    public void LowercasesBeforeValidating() => Assert.Equal("alice", IdentityMapper.Sanitize("ALICE"));

    /// <summary>An identity failure is an authentication problem, so it classifies as one.</summary>
    [Fact]
    public void AnIdentityFailureClassifiesAsAuthentication() =>
        Assert.Equal(ErrorCategory.Authentication,
            ErrorCategories.Classify(IdentityMappingException.UnsafeUsername()));
}
