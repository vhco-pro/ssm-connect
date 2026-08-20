using Amazon.Runtime.CredentialManagement;
using SSMConnect.Domain;

namespace SSMConnect.Aws;

/// <summary>An IAM Identity Center profile found in the shared AWS config.</summary>
/// <remarks>
/// Carries only what the config actually knows. The instance tag and the Secrets Manager ID are
/// deliberately absent: the AWS config has no concept of either, so the user still supplies them.
/// Pretending otherwise would produce a profile that looks complete and cannot connect.
/// </remarks>
public sealed record DiscoveredSsoProfile(
    string Name,
    string StartUrl,
    string SsoRegion,
    string AccountId,
    string RoleName,
    string ResourceRegion)
{
    /// <summary>A one-line summary for a chooser, matching what the macOS client shows.</summary>
    public string Summary => $"{AccountId} · {ResourceRegion}";
}

/// <summary>
/// Reads IAM Identity Center profiles from the standard AWS config directory.
/// </summary>
/// <remarks>
/// Specification XP-02. The macOS client has had this from the start; typing an SSO start URL,
/// account ID, role name and two regions by hand is both tedious and the easiest place to make a
/// silent mistake.
/// <para>
/// The SDK's own profile store is used rather than parsing <c>~/.aws/config</c> by hand, so
/// <c>sso_session</c> indirection, alternate config locations, and the environment variables that
/// override them all behave exactly as every other AWS tool on the machine.
/// </para>
/// </remarks>
public static class SsoProfileDiscovery
{
    public static IReadOnlyList<DiscoveredSsoProfile> Discover()
    {
        var chain = new CredentialProfileStoreChain();
        var found = new List<DiscoveredSsoProfile>();

        foreach (CredentialProfile profile in chain.ListProfiles())
        {
            CredentialProfileOptions? options = profile.Options;
            if (options is null
                || string.IsNullOrWhiteSpace(options.SsoStartUrl)
                || string.IsNullOrWhiteSpace(options.SsoAccountId)
                || string.IsNullOrWhiteSpace(options.SsoRoleName))
            {
                continue;
            }

            // The resource region is the profile's own region; the SSO region is where Identity
            // Center lives. They are frequently different, which is exactly the pair people get
            // wrong by hand.
            string resourceRegion = profile.Region?.SystemName ?? options.SsoRegion ?? string.Empty;

            found.Add(new DiscoveredSsoProfile(
                profile.Name,
                options.SsoStartUrl,
                options.SsoRegion ?? string.Empty,
                options.SsoAccountId,
                options.SsoRoleName,
                resourceRegion));
        }

        return [.. found.OrderBy(profile => profile.Name, StringComparer.OrdinalIgnoreCase)];
    }

    /// <summary>
    /// Builds a connection profile from a discovered entry, leaving the fields AWS config cannot
    /// supply for the user to fill in.
    /// </summary>
    public static ConnectionProfile ToConnectionProfile(this DiscoveredSsoProfile discovered) => new()
    {
        Id = Guid.NewGuid(),
        Name = discovered.Name,
        SsoStartUrl = discovered.StartUrl,
        SsoRegion = discovered.SsoRegion,
        AccountId = discovered.AccountId,
        RoleName = discovered.RoleName,
        ResourceRegion = discovered.ResourceRegion,
        InstanceTagKey = "Name",
        InstanceTagValue = string.Empty,
        LocalPort = 8443,
        RemotePort = 8443,
    };
}
