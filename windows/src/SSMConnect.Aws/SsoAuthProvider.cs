using Amazon;
using Amazon.Runtime;
using Amazon.Runtime.CredentialManagement;
using Amazon.Runtime.Credentials.Internal;
using Amazon.Runtime.SharedInterfaces;
using Amazon.SSO;
using Amazon.SSO.Model;
using Amazon.SSOOIDC;
using Amazon.SSOOIDC.Model;
using Amazon.Util;
using Amazon.Util.Internal;
using SSMConnect.Domain;
using SSMConnect.Workflow;

namespace SSMConnect.Aws;

/// <summary>
/// SDK-compatible cache seam. The SDK exposes these public cache types in an Internal namespace
/// and documents them as internal-use: this compatibility dependency is isolated here and tested
/// against the installed AWSSDK.Core 4.0.101 API. No logout or cache deletion is used.
/// </summary>
public interface ISsoTokenCache
{
    string? SessionName(ConnectionProfile profile) => null;
    Task<SsoToken?> ReadAsync(ConnectionProfile profile, CancellationToken cancellationToken);
    Task SaveAsync(SsoToken token, CancellationToken cancellationToken);
}

public sealed class SdkSsoTokenCache : ISsoTokenCache
{
    private readonly SSOTokenFileCache _cache = new(
        CryptoUtilFactory.CryptoInstance, new FileRetriever(), new DirectoryRetriever());

    public string? SessionName(ConnectionProfile profile) =>
        new CredentialProfileStoreChain().ListProfiles()
            .FirstOrDefault(candidate =>
                candidate.Options.SsoAccountId == profile.AccountId
                && candidate.Options.SsoRoleName == profile.RoleName
                && candidate.Options.SsoRegion == profile.SsoRegion
                && candidate.Options.SsoStartUrl == profile.SsoStartUrl)?.Options.SsoSession;

    public async Task<SsoToken?> ReadAsync(ConnectionProfile profile, CancellationToken cancellationToken)
    {
        TryResponse<SsoToken> response = await _cache.TryGetSsoTokenAsync(new SSOTokenManagerGetTokenOptions
        {
            StartUrl = profile.SsoStartUrl,
            Region = profile.SsoRegion,
            Session = SessionName(profile),
            SupportsGettingNewToken = false,
        }, null, cancellationToken).ConfigureAwait(false);
        return response.Success ? response.Value : null;
    }

    public Task SaveAsync(SsoToken token, CancellationToken cancellationToken) =>
        _cache.SaveSsoTokenAsync(token, null, cancellationToken);
}

/// <summary>
/// Silent cache reuse/refresh and explicit force-new device authorization are separate paths.
/// All clients use the SSO region; role expiry comes from GetRoleCredentials, never a local guess.
/// </summary>
public sealed class SsoAuthProvider : IAuthProvider
{
    public const string ClientName = "SSM Connect";
    private readonly Action<string> _openVerificationUri;
    private readonly ISsoTokenCache _cache;
    private readonly Func<string, IAmazonSSO> _sso;
    private readonly Func<string, IAmazonSSOOIDC> _oidc;
    private readonly Func<DateTimeOffset> _now;

    public SsoAuthProvider(Action<string> openVerificationUri, ISsoTokenCache? cache = null,
        Func<string, IAmazonSSO>? sso = null, Func<string, IAmazonSSOOIDC>? oidc = null,
        Func<DateTimeOffset>? now = null)
    {
        _openVerificationUri = openVerificationUri;
        _cache = cache ?? new SdkSsoTokenCache();
        _sso = sso ?? (region => new AmazonSSOClient(new AnonymousAWSCredentials(), RegionEndpoint.GetBySystemName(region)));
        _oidc = oidc ?? (region => new AmazonSSOOIDCClient(new AnonymousAWSCredentials(), RegionEndpoint.GetBySystemName(region)));
        _now = now ?? (() => DateTimeOffset.UtcNow);
    }

    public Task<AwsCredentials> AuthenticateAsync(ConnectionProfile profile, CancellationToken cancellationToken) =>
        RefreshAsync(profile, cancellationToken);

    public Task<AwsCredentials> RefreshAsync(ConnectionProfile profile, CancellationToken cancellationToken) =>
        AcquireAsync(profile, interactive: false, cancellationToken);

    public Task<AwsCredentials> SignInAsync(ConnectionProfile profile, CancellationToken cancellationToken) =>
        AcquireAsync(profile, interactive: true, cancellationToken);

    public async Task<AuthorizationMetadata?> GetMetadataAsync(ConnectionProfile profile, CancellationToken cancellationToken)
    {
        try
        {
            SsoToken? token = await _cache.ReadAsync(profile, cancellationToken).ConfigureAwait(false);
            return token is null ? null : new AuthorizationMetadata(Utc(token.ExpiresAt), CanRefresh(token));
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception) { return null; } // Cache metadata is optional, never an invented deadline.
    }

    private async Task<AwsCredentials> AcquireAsync(ConnectionProfile profile, bool interactive, CancellationToken cancellationToken)
    {
        try
        {
            cancellationToken.ThrowIfCancellationRequested();
            SsoToken? cached = await _cache.ReadAsync(profile, cancellationToken).ConfigureAwait(false);
            SsoToken token = interactive
                ? await NewTokenAsync(profile, cached?.Session ?? _cache.SessionName(profile), cancellationToken).ConfigureAwait(false)
                : await SilentTokenAsync(profile, cached, cancellationToken).ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
            using IAmazonSSO sso = _sso(profile.SsoRegion);
            GetRoleCredentialsResponse response = await sso.GetRoleCredentialsAsync(new GetRoleCredentialsRequest
            {
                AccountId = profile.AccountId,
                RoleName = profile.RoleName,
                AccessToken = token.AccessToken,
            }, cancellationToken).ConfigureAwait(false);
            RoleCredentials? role = response.RoleCredentials;
            if (role is null || string.IsNullOrEmpty(role.AccessKeyId) || string.IsNullOrEmpty(role.SecretAccessKey)
                || string.IsNullOrEmpty(role.SessionToken) || role.Expiration is not long expiration || expiration <= 0)
            {
                throw new SignInRequiredException();
            }
            return new AwsCredentials(role.AccessKeyId, role.SecretAccessKey, role.SessionToken,
                DateTimeOffset.FromUnixTimeMilliseconds(expiration));
        }
        catch (OperationCanceledException) { throw; }
        catch (SignInRequiredException) { throw; }
        catch (AmazonServiceException error) when (error.ErrorCode is "InvalidGrantException"
            or "InvalidClientException" or "UnauthorizedClientException" or "ExpiredTokenException" or "UnauthorizedException")
        {
            throw new SignInRequiredException();
        }
        catch (Exception error)
        {
            Exception translated = AwsErrors.Translate(error);
            if (translated is ConnectionException) { throw translated; }
            throw new AuthorizationUnavailableException();
        }
    }

    private async Task<SsoToken> SilentTokenAsync(ConnectionProfile profile, SsoToken? token, CancellationToken cancellationToken)
    {
        if (token is null || string.IsNullOrEmpty(token.AccessToken)) { throw new SignInRequiredException(); }
        if (Utc(token.ExpiresAt) > _now() + TimeSpan.FromMinutes(5)) { return token; }
        if (!CanRefresh(token))
        {
            if (Utc(token.ExpiresAt) <= _now()) { throw new SignInRequiredException(); }
            return token;
        }
        using IAmazonSSOOIDC oidc = _oidc(profile.SsoRegion);
        CreateTokenResponse response = await oidc.CreateTokenAsync(new CreateTokenRequest
        {
            ClientId = token.ClientId,
            ClientSecret = token.ClientSecret,
            RefreshToken = token.RefreshToken,
            GrantType = "refresh_token",
        }, cancellationToken).ConfigureAwait(false);
        if (string.IsNullOrEmpty(response.AccessToken) || response.ExpiresIn is not int seconds || seconds <= 0)
        {
            throw new SignInRequiredException();
        }
        token.AccessToken = response.AccessToken;
        token.ExpiresAt = (_now() + TimeSpan.FromSeconds(seconds)).UtcDateTime;
        token.RefreshToken = response.RefreshToken ?? token.RefreshToken;
        await _cache.SaveAsync(token, cancellationToken).ConfigureAwait(false);
        return token;
    }

    private async Task<SsoToken> NewTokenAsync(ConnectionProfile profile, string? session, CancellationToken cancellationToken)
    {
        using IAmazonSSOOIDC oidc = _oidc(profile.SsoRegion);
        var core = (ICoreAmazonSSOOIDC_V2)oidc;
        GetSsoTokenResponse response = await core.GetSsoTokenAsync(new GetSsoTokenRequest
        {
            ClientName = ClientName,
            ClientType = "public",
            StartUrl = profile.SsoStartUrl,
            Scopes = ["sso:account:access"],
            SsoVerificationCallback = verification =>
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (Uri.TryCreate(verification.VerificationUriComplete, UriKind.Absolute, out Uri? uri)
                    && uri.Scheme == Uri.UriSchemeHttps)
                {
                    _openVerificationUri(uri.AbsoluteUri);
                }
            },
        }, cancellationToken).ConfigureAwait(false);
        cancellationToken.ThrowIfCancellationRequested();
        if (string.IsNullOrEmpty(response.AccessToken)) { throw new SignInRequiredException(); }
        var token = new SsoToken
        {
            AccessToken = response.AccessToken,
            ExpiresAt = response.ExpiresAt,
            RefreshToken = response.RefreshToken,
            ClientId = response.ClientId,
            ClientSecret = response.ClientSecret,
            RegistrationExpiresAt = response.RegistrationExpiresAt,
            Region = profile.SsoRegion,
            StartUrl = profile.SsoStartUrl,
            Session = session,
        };
        await _cache.SaveAsync(token, cancellationToken).ConfigureAwait(false);
        return token;
    }

    private bool CanRefresh(SsoToken token) =>
        !string.IsNullOrEmpty(token.RefreshToken) && !string.IsNullOrEmpty(token.ClientId)
        && !string.IsNullOrEmpty(token.ClientSecret)
        && DateTimeOffset.TryParse(token.RegistrationExpiresAt, System.Globalization.CultureInfo.InvariantCulture,
            System.Globalization.DateTimeStyles.AssumeUniversal, out DateTimeOffset registrationExpiry)
        && registrationExpiry > _now();

    private static DateTimeOffset Utc(DateTime value) => new(DateTime.SpecifyKind(value, DateTimeKind.Utc));
}
