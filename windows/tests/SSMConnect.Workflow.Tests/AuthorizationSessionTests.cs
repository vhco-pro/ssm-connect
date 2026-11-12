using SSMConnect.Domain;

#pragma warning disable xUnit1051 // Cancellation and scheduling are controlled by these tests.

namespace SSMConnect.Workflow.Tests;

public sealed class AuthorizationSessionTests
{
    internal static readonly DateTimeOffset Start = new(2030, 1, 1, 0, 0, 0, TimeSpan.Zero);
    internal static ConnectionProfile Profile() => new()
    {
        Id = Guid.NewGuid(), Name = "Synthetic", SsoStartUrl = "https://example.awsapps.com/start",
        SsoRegion = "eu-west-1", AccountId = "123456789012", RoleName = "Developer",
        ResourceRegion = "eu-central-1", InstanceTagKey = "Name", InstanceTagValue = "workstation",
        LocalPort = 8443, RemotePort = 8443,
    };
    internal static AwsCredentials Credentials(string id = "synthetic", DateTimeOffset? expiry = null) =>
        new(id, "secret-never-log", "token-never-log", expiry ?? Start.AddHours(1));

    [Fact] // AUTH-01
    public async Task ScheduledRenewalUsesKnownEarliestExpiryAndDoesNotSignIn()
    {
        ConnectionProfile profile = Profile();
        var clock = new TestClock();
        var delay = new ControlledDelay();
        var provider = new TestAuth { Metadata = new(Start.AddMinutes(40), true) };
        using var session = new AuthorizationSession(profile, provider, clock, delay);
        await session.AuthenticateAsync(profile, default);
        Assert.Equal(TimeSpan.FromMinutes(35), delay.Duration);
        clock.UtcNow = Start.AddMinutes(35);
        Task ready = UntilStatus(session, AuthorizationStatus.Ready, afterNextChange: true);
        provider.Metadata = new(Start.AddHours(2), true);
        delay.Release();
        await ready;
        Assert.Equal(2, provider.SilentCalls);
        Assert.Equal(0, provider.InteractiveCalls);
        Assert.Equal(Start.AddHours(1), session.RoleCredentialsExpiry);
        Assert.Equal(Start.AddHours(2), session.Metadata?.AccessTokenExpiry);
        Assert.Contains("deadline is unknown", session.Snapshot.Detail);
    }

    [Fact] // AUTH-01
    public async Task ConcurrentRequestsAndFreshnessChecksDeduplicateOneBoundedRenewal()
    {
        var profile = Profile();
        var response = Completion<AwsCredentials>();
        var provider = new TestAuth { Silent = _ => response.Task };
        using var session = NewSession(profile, provider);
        Task<AwsCredentials>[] pending = Enumerable.Range(0, 8)
            .Select(_ => session.AuthenticateAsync(profile, default)).ToArray();
        await provider.SilentStarted.Task;
        for (int i = 0; i < 10; i++) { session.CheckFreshness(); }
        Assert.Equal(1, provider.SilentCalls);
        response.SetResult(Credentials());
        await Task.WhenAll(pending);
        Assert.Equal(0, provider.InteractiveCalls);
    }

    [Fact] // AUTH-02, AUTH-03
    public async Task SilentRejectionWaitsForOneExplicitSignInAndResumesAllSameContextWork()
    {
        var profile = Profile();
        var signIn = Completion<AwsCredentials>();
        var provider = new TestAuth
        {
            Silent = _ => Task.FromException<AwsCredentials>(new SignInRequiredException()),
            Interactive = _ => signIn.Task,
        };
        using var session = NewSession(profile, provider);
        Task required = UntilStatus(session, AuthorizationStatus.SignInRequired);
        Task<AwsCredentials> a = session.AuthenticateAsync(profile, default);
        Task<AwsCredentials> b = session.AuthenticateAsync(profile, default);
        await required;
        Assert.False(a.IsCompleted);
        Assert.False(b.IsCompleted);
        session.CheckFreshness();
        Assert.Equal(0, provider.InteractiveCalls);
        Task<AwsCredentials> login = session.SignInAsync();
        Task<AwsCredentials> duplicate = session.SignInAsync();
        await provider.InteractiveStarted.Task;
        Assert.Equal(1, provider.InteractiveCalls);
        signIn.SetResult(Credentials("fresh"));
        AwsCredentials[] results = await Task.WhenAll(a, b, login, duplicate);
        Assert.All(results, result => Assert.Equal("fresh", result.AccessKeyId));
    }

    [Fact] // AUTH-02
    public async Task NonRenewableKnownTokenWarnsBeforeExpiryWithoutCallingProviderAgain()
    {
        var profile = Profile();
        var clock = new TestClock();
        var provider = new TestAuth { Metadata = new(Start.AddMinutes(10), false) };
        using var session = new AuthorizationSession(profile, provider, clock, new ControlledDelay());
        await session.AuthenticateAsync(profile, default);
        clock.UtcNow = Start.AddMinutes(5);
        session.CheckFreshness();
        Assert.Equal(AuthorizationStatus.SignInRequired, session.Status);
        Assert.Equal(Start.AddMinutes(10), session.Metadata?.AccessTokenExpiry);
        Assert.Equal(1, provider.SilentCalls);
        Assert.Equal(0, provider.InteractiveCalls);
    }

    [Fact] // AUTH-04
    public async Task RevokedOperationIsRetriedExactlyOnceThenBecomesActionable()
    {
        var profile = Profile();
        var provider = new TestAuth();
        using var session = NewSession(profile, provider);
        int calls = 0;
        await Assert.ThrowsAsync<SignInRequiredException>(() => session.ExecuteAsync<int>(profile, _ =>
        {
            calls++;
            throw new ExpiredCredentialsException();
        }));
        Assert.Equal(2, calls);
        Assert.Equal(2, provider.SilentCalls);
        Assert.Equal(AuthorizationStatus.SignInRequired, session.Status);
        Assert.Equal(0, provider.InteractiveCalls);
    }

    [Fact] // AUTH-03, AUTH-04
    public async Task RejectedOperationResumesOriginalTargetAfterExplicitSignIn()
    {
        var profile = Profile();
        var provider = new TestAuth();
        using var session = NewSession(profile, provider);
        await session.AuthenticateAsync(profile, default);
        provider.Silent = _ => Task.FromException<AwsCredentials>(new SignInRequiredException());
        int calls = 0;
        Task required = UntilStatus(session, AuthorizationStatus.SignInRequired);
        Task<string> operation = session.ExecuteAsync(profile, credentials =>
        {
            calls++;
            if (calls == 1) { throw new ExpiredCredentialsException(); }
            return Task.FromResult(credentials.AccessKeyId + profile.InstanceTagValue);
        });
        await required;
        await session.SignInAsync();
        Assert.Equal("interactiveworkstation", await operation);
        Assert.Equal(2, calls);
    }

    [Theory] // AUTH-05
    [InlineData("apply")]
    [InlineData("stop")]
    [InlineData("dispose")]
    public async Task InvalidatingContextPreventsReplayEvenIfProviderIgnoresCancellation(string action)
    {
        var profile = Profile();
        var response = Completion<AwsCredentials>();
        var provider = new TestAuth { Interactive = _ => response.Task };
        using var session = NewSession(profile, provider);
        int operations = 0;
        Task required = UntilStatus(session, AuthorizationStatus.SignInRequired);
        provider.Silent = _ => Task.FromException<AwsCredentials>(new SignInRequiredException());
        Task<int> work = session.ExecuteAsync(profile, _ => Task.FromResult(++operations));
        await required;
        Task<AwsCredentials> login = session.SignInAsync();
        await provider.InteractiveStarted.Task;
        if (action == "apply") { session.Apply(profile with { InstanceTagValue = "different" }); }
        else if (action == "stop") { session.CancelPending(); }
        else { session.Dispose(); }
        response.SetResult(Credentials("stale"));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => work);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => login);
        Assert.Equal(0, operations);
        Assert.Equal(AuthorizationStatus.Idle, session.Status);
    }

    [Fact] // AUTH-05
    public async Task CancelingOneWaiterDoesNotCancelAnotherWaiter()
    {
        var profile = Profile();
        var response = Completion<AwsCredentials>();
        var provider = new TestAuth { Silent = _ => response.Task };
        using var session = NewSession(profile, provider);
        using var cancel = new CancellationTokenSource();
        Task<AwsCredentials> canceled = session.AuthenticateAsync(profile, cancel.Token);
        Task<AwsCredentials> remaining = session.AuthenticateAsync(profile, default);
        cancel.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => canceled);
        response.SetResult(Credentials());
        await remaining;
        Assert.Equal(AuthorizationStatus.Ready, session.Status);
        Assert.Equal(1, provider.SilentCalls);
    }

    [Fact] // AUTH-05
    public async Task CancelingExplicitSignInStopsTheInteractiveRequest()
    {
        var profile = Profile();
        var canceled = Completion<bool>();
        var provider = new TestAuth
        {
            Interactive = async token =>
            {
                using var registration = token.Register(() => canceled.TrySetResult(true));
                await Task.Delay(Timeout.InfiniteTimeSpan, token);
                return Credentials();
            },
        };
        using var session = NewSession(profile, provider);
        using var cancel = new CancellationTokenSource();
        Task<AwsCredentials> login = session.SignInAsync(cancel.Token);
        await provider.InteractiveStarted.Task;
        cancel.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => login);
        await canceled.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Assert.Equal(AuthorizationStatus.SignInRequired, session.Status);
    }

    [Theory] // AUTH-07
    [InlineData(false)]
    [InlineData(true)]
    public async Task OfflineAndRoleDenialAreDistinctAndNeverOpenBrowser(bool denied)
    {
        var profile = Profile();
        var provider = new TestAuth
        {
            Silent = _ => Task.FromException<AwsCredentials>(denied
                ? new AuthorizationAccessDeniedException()
                : new HttpRequestException("secret-never-log https://signed.example/?token=token-never-log")),
        };
        using var session = NewSession(profile, provider);
        if (denied)
        {
            await Assert.ThrowsAsync<AuthorizationAccessDeniedException>(() => session.AuthenticateAsync(profile, default));
        }
        else
        {
            await Assert.ThrowsAsync<AuthorizationUnavailableException>(() => session.AuthenticateAsync(profile, default));
        }
        Assert.Equal(denied ? AuthorizationStatus.AccessDenied : AuthorizationStatus.Unavailable, session.Status);
        Assert.DoesNotContain("secret-never-log", session.Snapshot.ToString());
        Assert.DoesNotContain("token-never-log", session.Snapshot.ToString());
        Assert.Equal(0, provider.InteractiveCalls);
        Assert.Equal(1, provider.SilentCalls);
    }

    [Fact]
    public void CredentialToStringIsRedacted() =>
        Assert.Equal("AWS credentials (redacted)", Credentials().ToString());

    [Fact]
    public async Task BoundedSilentRequestTimeoutDoesNotLeavePendingWaitersOrOpenBrowser()
    {
        var profile = Profile();
        var provider = new TestAuth { Silent = _ => Completion<AwsCredentials>().Task };
        using var session = new AuthorizationSession(profile, provider, new TestClock(), new ControlledDelay(),
            requestTimeout: TimeSpan.Zero);
        await Assert.ThrowsAsync<AuthorizationUnavailableException>(() =>
            session.AuthenticateAsync(profile, default).WaitAsync(TimeSpan.FromSeconds(5)));
        Assert.Equal(AuthorizationStatus.Unavailable, session.Status);
        Assert.Equal(0, provider.InteractiveCalls);
    }

    [Fact] // AUTH-02
    public async Task AlreadyNearNonRenewableDeadlineIsVisibleImmediately()
    {
        var profile = Profile();
        var provider = new TestAuth { Metadata = new(Start.AddSeconds(10), false) };
        using var session = NewSession(profile, provider);
        await session.AuthenticateAsync(profile, default);
        Assert.Equal(AuthorizationStatus.SignInRequired, session.Status);
        Assert.Equal(Start.AddSeconds(10), session.Metadata?.AccessTokenExpiry);
        Assert.Equal(0, provider.InteractiveCalls);
    }

    [Fact]
    public async Task RetryAfterOfflineFailureUsesOneSilentAttempt()
    {
        var profile = Profile();
        var provider = new TestAuth { Silent = _ => Task.FromException<AwsCredentials>(new HttpRequestException("offline")) };
        using var session = NewSession(profile, provider);
        await Assert.ThrowsAsync<AuthorizationUnavailableException>(() => session.AuthenticateAsync(profile, default));
        provider.Silent = _ => Task.FromResult(Credentials("retried"));
        Assert.Equal("retried", (await session.RetryAsync()).AccessKeyId);
        Assert.Equal(AuthorizationStatus.Ready, session.Status);
        Assert.Equal(2, provider.SilentCalls);
        Assert.Equal(0, provider.InteractiveCalls);
    }

    [Fact] // AUTH-04
    public async Task ConcurrentRejectedOperationsShareOneRecovery()
    {
        var profile = Profile();
        var provider = new TestAuth();
        using var session = NewSession(profile, provider);
        await session.AuthenticateAsync(profile, default);
        var refresh = Completion<AwsCredentials>();
        provider.Silent = _ => refresh.Task;
        var bothStarted = Completion<bool>();
        int initialCalls = 0;
        async Task<string> Operation(AwsCredentials credentials)
        {
            if (credentials.AccessKeyId == "fresh") { return credentials.AccessKeyId; }
            if (Interlocked.Increment(ref initialCalls) == 2) { bothStarted.TrySetResult(true); }
            await bothStarted.Task;
            throw new ExpiredCredentialsException();
        }
        Task refreshing = UntilStatus(session, AuthorizationStatus.Refreshing);
        Task<string> first = session.ExecuteAsync(profile, Operation);
        Task<string> second = session.ExecuteAsync(profile, Operation);
        await refreshing;
        refresh.SetResult(Credentials("fresh"));
        Assert.Equal(["fresh", "fresh"], await Task.WhenAll(first, second));
        Assert.Equal(2, provider.SilentCalls);
        Assert.Equal(0, provider.InteractiveCalls);
    }

    [Theory] // AUTH-05: force provider completion from inside cancellation, without timing sleeps.
    [InlineData("apply")]
    [InlineData("cancel")]
    [InlineData("dispose")]
    public async Task ContextIsRetiredBeforeReentrantProviderCancellation(string action)
    {
        var profile = Profile();
        ConnectionProfile next = profile with { InstanceTagValue = "new-selection" };
        var provider = new TestAuth
        {
            Silent = _ => Task.FromException<AwsCredentials>(new SignInRequiredException()),
        };
        using var session = NewSession(profile, provider);
        var registered = Completion<bool>();
        // Inline continuations exercise cancellation reentrancy rather than scheduler luck.
        var response = new TaskCompletionSource<AwsCredentials>();
        AuthorizationStatus? statusDuringCancellation = null;
        Exception? oldProfileError = null;
        CancellationTokenRegistration registration = default;
        provider.Interactive = token =>
        {
            registration = token.Register(() =>
            {
                statusDuringCancellation = session.Status;
                if (action == "apply")
                {
                    try { _ = session.GetMetadataAsync(profile, default); }
                    catch (Exception error) { oldProfileError = error; }
                }
                response.TrySetException(new HttpRequestException("synthetic provider cancellation"));
            });
            registered.TrySetResult(true);
            return response.Task;
        };
        int operations = 0;
        Task required = UntilStatus(session, AuthorizationStatus.SignInRequired);
        Task<int> pending = session.ExecuteAsync(profile, _ => Task.FromResult(++operations));
        await required;
        Task<AwsCredentials> login = session.SignInAsync();
        await registered.Task.WaitAsync(TimeSpan.FromSeconds(5));

        if (action == "apply") { session.Apply(next); }
        else if (action == "cancel") { session.CancelPending(); }
        else { session.Dispose(); }

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => pending);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => login);
        await Assert.ThrowsAsync<HttpRequestException>(() => response.Task);
        registration.Dispose();
        Assert.Equal(AuthorizationStatus.Idle, statusDuringCancellation);
        Assert.Equal(AuthorizationStatus.Idle, session.Status);
        Assert.Equal(0, operations);
        if (action == "apply") { Assert.IsAssignableFrom<OperationCanceledException>(oldProfileError); }
        if (action != "dispose")
        {
            provider.Interactive = _ => Task.FromResult(Credentials("fresh-generation"));
            Assert.Equal("fresh-generation", (await session.SignInAsync()).AccessKeyId);
            Assert.Equal(AuthorizationStatus.Ready, session.Status);
            Assert.Equal(0, operations);
        }
    }

    [Fact] // AUTH-03: a retired silent attempt must not fault the interactive flow's shared waiters.
    public async Task InteractiveReplacementIsInstalledBeforeCancelingSilentRequest()
    {
        var profile = Profile();
        var provider = new TestAuth();
        using var session = NewSession(profile, provider);
        var registered = Completion<bool>();
        var silentResponse = new TaskCompletionSource<AwsCredentials>();
        var interactiveResponse = Completion<AwsCredentials>();
        AuthorizationStatus? statusDuringCancellation = null;
        CancellationTokenRegistration registration = default;
        provider.Silent = token =>
        {
            registration = token.Register(() =>
            {
                statusDuringCancellation = session.Status;
                silentResponse.TrySetException(new HttpRequestException("retired silent request"));
            });
            registered.TrySetResult(true);
            return silentResponse.Task;
        };
        provider.Interactive = _ => interactiveResponse.Task;

        Task<AwsCredentials> pending = session.AuthenticateAsync(profile, default);
        await registered.Task.WaitAsync(TimeSpan.FromSeconds(5));
        Task<AwsCredentials> login = session.SignInAsync();
        await provider.InteractiveStarted.Task.WaitAsync(TimeSpan.FromSeconds(5));
        interactiveResponse.SetResult(Credentials("interactive-replacement"));
        AwsCredentials[] results = await Task.WhenAll(pending, login).WaitAsync(TimeSpan.FromSeconds(5));
        await Assert.ThrowsAsync<HttpRequestException>(() => silentResponse.Task);
        registration.Dispose();
        Assert.Equal(AuthorizationStatus.SigningIn, statusDuringCancellation);
        Assert.All(results, result => Assert.Equal("interactive-replacement", result.AccessKeyId));
        Assert.Equal(AuthorizationStatus.Ready, session.Status);
        Assert.Equal(1, provider.SilentCalls);
        Assert.Equal(1, provider.InteractiveCalls);
    }

    internal static AuthorizationSession NewSession(ConnectionProfile profile, IAuthProvider provider) =>
        new(profile, provider, new TestClock(), new ControlledDelay());

    internal static TaskCompletionSource<T> Completion<T>() => new(TaskCreationOptions.RunContinuationsAsynchronously);

    internal static Task UntilStatus(AuthorizationSession session, AuthorizationStatus status, bool afterNextChange = false)
    {
        var signal = Completion<bool>();
        void Handler(AuthorizationSnapshot snapshot)
        {
            if (snapshot.Status == status) { signal.TrySetResult(true); }
        }
        session.Changed += Handler;
        if (!afterNextChange && session.Status == status) { signal.TrySetResult(true); }
        return AwaitAsync();
        async Task AwaitAsync()
        {
            try { await signal.Task.WaitAsync(TimeSpan.FromSeconds(5)); }
            finally { session.Changed -= Handler; }
        }
    }

    internal sealed class TestClock : IClock { public DateTimeOffset UtcNow { get; set; } = Start; }
    internal sealed class ControlledDelay : IDelay
    {
        private TaskCompletionSource<bool> _release = Completion<bool>();
        public TimeSpan Duration { get; private set; }
        public Task WaitAsync(TimeSpan duration, CancellationToken cancellationToken)
        {
            Duration = duration;
            return _release.Task.WaitAsync(cancellationToken);
        }
        public void Release()
        {
            TaskCompletionSource<bool> previous = _release;
            _release = Completion<bool>();
            previous.TrySetResult(true);
        }
    }
    internal sealed class TestAuth : IAuthProvider
    {
        public int SilentCalls;
        public int InteractiveCalls;
        public TaskCompletionSource<bool> SilentStarted { get; } = Completion<bool>();
        public TaskCompletionSource<bool> InteractiveStarted { get; } = Completion<bool>();
        public AuthorizationMetadata? Metadata { get; set; }
        public Func<CancellationToken, Task<AwsCredentials>> Silent { get; set; } = _ => Task.FromResult(Credentials());
        public Func<CancellationToken, Task<AwsCredentials>> Interactive { get; set; } = _ => Task.FromResult(Credentials("interactive"));
        public Task<AwsCredentials> AuthenticateAsync(ConnectionProfile profile, CancellationToken cancellationToken) =>
            RefreshAsync(profile, cancellationToken);
        public Task<AwsCredentials> RefreshAsync(ConnectionProfile profile, CancellationToken cancellationToken)
        {
            Interlocked.Increment(ref SilentCalls);
            SilentStarted.TrySetResult(true);
            return Silent(cancellationToken);
        }
        public Task<AwsCredentials> SignInAsync(ConnectionProfile profile, CancellationToken cancellationToken)
        {
            Interlocked.Increment(ref InteractiveCalls);
            InteractiveStarted.TrySetResult(true);
            return Interactive(cancellationToken);
        }
        public Task<AuthorizationMetadata?> GetMetadataAsync(ConnectionProfile profile, CancellationToken cancellationToken) =>
            Task.FromResult(Metadata);
    }
}
