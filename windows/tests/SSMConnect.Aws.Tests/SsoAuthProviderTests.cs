using Amazon.Runtime;
using Amazon.Runtime.Credentials.Internal;
using Amazon.Runtime.SharedInterfaces;
using Amazon.SSO;
using Amazon.SSO.Model;
using Amazon.SSOOIDC;
using Amazon.SSOOIDC.Model;
using Amazon.Util;
using Amazon.Util.Internal;
using SSMConnect.Aws;
using SSMConnect.Domain;
using SSMConnect.Workflow;
using Xunit;

#pragma warning disable xUnit1051 // Cancellation is explicitly controlled by these adapter tests.

namespace SSMConnect.Aws.Tests;

public sealed class SsoAuthProviderTests
{
    private static readonly DateTimeOffset Now = new(2030, 1, 1, 0, 0, 0, TimeSpan.Zero);
    private static ConnectionProfile Profile => new()
    {
        Id = Guid.NewGuid(), Name = "Synthetic", SsoStartUrl = "https://example.awsapps.com/start",
        SsoRegion = "eu-west-1", ResourceRegion = "eu-central-1", AccountId = "123456789012",
        RoleName = "Developer", InstanceTagKey = "Name", InstanceTagValue = "synthetic",
        LocalPort = 8443, RemotePort = 8443,
    };

    [Fact]
    public async Task CachedTokenUsesSsoRegionAndReturnsActualDistinctRoleExpiry()
    {
        var cache = new MemoryCache(Token());
        var sso = new FakeSso();
        var provider = Provider(cache, sso);
        AwsCredentials credentials = await provider.RefreshAsync(Profile, default);
        Assert.Equal(Now.AddMinutes(45), credentials.Expiration);
        Assert.Equal("cached-access", sso.Request?.AccessToken);
        AuthorizationMetadata? metadata = await provider.GetMetadataAsync(Profile, default);
        Assert.Equal(Now.AddHours(1), metadata?.AccessTokenExpiry);
        Assert.True(metadata?.CanRefresh);
        Assert.Equal(0, cache.Saves);
    }

    [Fact]
    public async Task NearExpirySilentlyRefreshesAndPersistsSdkCompatibleToken()
    {
        var token = Token();
        token.ExpiresAt = Now.AddMinutes(4).UtcDateTime;
        var cache = new MemoryCache(token);
        var sso = new FakeSso();
        var oidc = new FakeOidc();
        var provider = Provider(cache, sso, oidc);
        await provider.RefreshAsync(Profile, default);
        Assert.Equal("refresh_token", oidc.RefreshRequest?.GrantType);
        Assert.Equal("refresh", oidc.RefreshRequest?.RefreshToken);
        Assert.Equal("silently-renewed", sso.Request?.AccessToken);
        Assert.Equal(0, oidc.NewTokenCalls);
        Assert.Equal(1, cache.Saves);
        Assert.Equal(Now.AddHours(2).UtcDateTime, cache.Token?.ExpiresAt);
    }

    [Fact]
    public async Task ExplicitSignInBypassesEvenValidRejectedCacheWithoutLogoutOrDeletion()
    {
        var cache = new MemoryCache(Token());
        var sso = new FakeSso();
        var oidc = new FakeOidc();
        var provider = Provider(cache, sso, oidc);
        await provider.SignInAsync(Profile, default);
        Assert.Equal(1, oidc.NewTokenCalls);
        Assert.Null(oidc.RefreshRequest);
        Assert.Equal("force-new", sso.Request?.AccessToken);
        Assert.Equal("force-new", cache.Token?.AccessToken);
        Assert.Equal("shared-session", cache.Token?.Session);
        Assert.Equal(1, cache.Saves);
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task MissingOrRejectedSilentTokenNeverStartsInteractiveFlow(bool rejected)
    {
        var token = Token();
        token.ExpiresAt = Now.AddMinutes(4).UtcDateTime;
        var cache = new MemoryCache(rejected ? token : null);
        var oidc = new FakeOidc { RefreshError = new AmazonSSOOIDCException("sensitive") { ErrorCode = "InvalidGrantException" } };
        var provider = Provider(cache, new FakeSso(), oidc);
        await Assert.ThrowsAsync<SignInRequiredException>(() => provider.RefreshAsync(Profile, default));
        Assert.Equal(0, oidc.NewTokenCalls);
        Assert.Equal(0, cache.Saves);
    }

    [Theory]
    [InlineData("AccessDeniedException", typeof(AuthorizationAccessDeniedException))]
    [InlineData("UnauthorizedException", typeof(SignInRequiredException))]
    public async Task RoleDenialIsNotMistakenForRevocation(string code, Type expected)
    {
        var sso = new FakeSso { Error = new AmazonSSOException("secret https://signed/?token=sensitive") { ErrorCode = code } };
        var oidc = new FakeOidc();
        Exception? error = await Record.ExceptionAsync(() => Provider(new MemoryCache(Token()), sso, oidc).RefreshAsync(Profile, default));
        Assert.IsType(expected, error);
        Assert.DoesNotContain("sensitive", error.ToString());
        Assert.Equal(0, oidc.NewTokenCalls);
    }

    [Fact]
    public async Task CancellationFlowsToSdkAndOfflineDoesNotBecomeSignInRequired()
    {
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        var provider = Provider(new MemoryCache(Token()), new FakeSso());
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => provider.RefreshAsync(Profile, cancellation.Token));
        var sso = new FakeSso { Error = new HttpRequestException("sensitive") };
        await Assert.ThrowsAsync<AuthorizationUnavailableException>(() => Provider(new MemoryCache(Token()), sso).RefreshAsync(Profile, default));
    }

    [Fact]
    public async Task EmptySharedSessionCacheStillPersistsNewLoginUnderConfiguredSession()
    {
        var cache = new MemoryCache(null) { ConfiguredSession = "configured-session" };
        var oidc = new FakeOidc();
        await Provider(cache, new FakeSso(), oidc).SignInAsync(Profile, default);
        Assert.Equal("configured-session", cache.Token?.Session);
        Assert.Equal(1, oidc.NewTokenCalls);
    }

    [Fact]
    public void PinnedSdkTokenSerializationRoundTripsRefreshMetadata()
    {
        SsoToken token = Token();
        SsoToken roundTrip = SsoTokenUtils.FromJson(SsoTokenUtils.ToJson(token));
        Assert.Equal(token.AccessToken, roundTrip.AccessToken);
        Assert.Equal(token.RefreshToken, roundTrip.RefreshToken);
        Assert.Equal(token.ExpiresAt, roundTrip.ExpiresAt);
        Assert.Equal(token.RegistrationExpiresAt, roundTrip.RegistrationExpiresAt);
    }

    [Fact]
    public void PinnedPublicSdkCacheAndNativeCancellableLoginApisExist()
    {
        Assert.IsAssignableFrom<ISSOTokenFileCache>(new SSOTokenFileCache(
            CryptoUtilFactory.CryptoInstance, new FileRetriever(), new DirectoryRetriever()));
        Assert.NotNull(typeof(SSOTokenFileCache).GetMethod("SaveSsoTokenAsync"));
        Assert.NotNull(typeof(ICoreAmazonSSOOIDC_V2).GetMethod("GetSsoTokenAsync",
            [typeof(GetSsoTokenRequest), typeof(CancellationToken)]));
        Assert.NotNull(typeof(SSOImmutableCredentials).GetProperty("Expiration"));
    }

    private static SsoAuthProvider Provider(MemoryCache cache, FakeSso sso, FakeOidc? oidc = null) =>
        new(_ => throw new InvalidOperationException("Tests must not open a browser."), cache,
            region => { Assert.Equal("eu-west-1", region); return sso; },
            region => { Assert.Equal("eu-west-1", region); return oidc ?? new FakeOidc(); },
            () => Now);

    private static SsoToken Token() => new()
    {
        AccessToken = "cached-access", ExpiresAt = Now.AddHours(1).UtcDateTime,
        RefreshToken = "refresh", ClientId = "client", ClientSecret = "secret",
        RegistrationExpiresAt = Now.AddDays(1).ToString("O"),
        Region = "eu-west-1", StartUrl = "https://example.awsapps.com/start", Session = "shared-session",
    };

    private sealed class MemoryCache(SsoToken? token) : ISsoTokenCache
    {
        public SsoToken? Token = token;
        public int Saves;
        public string? ConfiguredSession;
        public string? SessionName(ConnectionProfile profile) => ConfiguredSession;
        public Task<SsoToken?> ReadAsync(ConnectionProfile profile, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            return Task.FromResult(Token);
        }
        public Task SaveAsync(SsoToken value, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            Token = value;
            Saves++;
            return Task.CompletedTask;
        }
    }

    private sealed class FakeSso() : AmazonSSOClient(new AnonymousAWSCredentials(), Amazon.RegionEndpoint.EUWest1)
    {
        public GetRoleCredentialsRequest? Request;
        public Exception? Error;
        public override Task<GetRoleCredentialsResponse> GetRoleCredentialsAsync(GetRoleCredentialsRequest request, CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            Request = request;
            return Error is not null ? Task.FromException<GetRoleCredentialsResponse>(Error) : Task.FromResult(new GetRoleCredentialsResponse
            {
                RoleCredentials = new RoleCredentials
                {
                    AccessKeyId = "synthetic", SecretAccessKey = "synthetic", SessionToken = "synthetic",
                    Expiration = Now.AddMinutes(45).ToUnixTimeMilliseconds(),
                },
            });
        }
    }

    private sealed class FakeOidc() : AmazonSSOOIDCClient(new AnonymousAWSCredentials(), Amazon.RegionEndpoint.EUWest1), ICoreAmazonSSOOIDC_V2
    {
        public int NewTokenCalls;
        public CreateTokenRequest? RefreshRequest;
        public Exception? RefreshError;
        public override Task<CreateTokenResponse> CreateTokenAsync(CreateTokenRequest request, CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            RefreshRequest = request;
            return RefreshError is not null ? Task.FromException<CreateTokenResponse>(RefreshError) : Task.FromResult(new CreateTokenResponse
            {
                AccessToken = "silently-renewed", RefreshToken = "new-refresh", ExpiresIn = 7200,
            });
        }
        Task<GetSsoTokenResponse> ICoreAmazonSSOOIDC_V2.GetSsoTokenAsync(GetSsoTokenRequest request, CancellationToken cancellationToken)
        {
            cancellationToken.ThrowIfCancellationRequested();
            NewTokenCalls++;
            return Task.FromResult(new GetSsoTokenResponse
            {
                AccessToken = "force-new", RefreshToken = "new-refresh", ExpiresAt = Now.AddHours(2).UtcDateTime,
                ClientId = "client", ClientSecret = "secret", RegistrationExpiresAt = Now.AddDays(1).ToString("O"),
            });
        }
    }
}
