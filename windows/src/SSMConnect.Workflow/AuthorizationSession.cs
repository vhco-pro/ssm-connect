using SSMConnect.Domain;

namespace SSMConnect.Workflow;

public enum AuthorizationStatus { Idle, Ready, Refreshing, SignInRequired, SigningIn, Unavailable, AccessDenied }

/// <summary>Safe to display or dispatch to the UI; never contains provider error text.</summary>
public sealed record AuthorizationSnapshot(
    AuthorizationStatus Status, DateTimeOffset? RoleCredentialsExpiry,
    AuthorizationMetadata? Metadata, string? ErrorMessage)
{
    public string Detail => Status switch
    {
        AuthorizationStatus.Ready => "Authorization ready for new operations. SSO session deadline is unknown.",
        AuthorizationStatus.Refreshing => "Renewing authorization; established connections are unchanged.",
        AuthorizationStatus.SigningIn => "Signing in with SSO; pending same-target operations will resume.",
        AuthorizationStatus.SignInRequired => "Sign In Required for new operations. Established connections are unchanged. SSO session deadline is unknown.",
        _ => ErrorMessage ?? "SSO session deadline is unknown.",
    };
}

/// <summary>
/// Shared authorization for one immutable profile context. Renewal does not own or tear down
/// transports. Changed can run on any thread; a UI subscriber must dispatch its updates.
/// </summary>
public sealed class AuthorizationSession : IAuthProvider, IDisposable
{
    private readonly Lock _gate = new();
    private readonly IAuthProvider _provider;
    private readonly IClock _clock;
    private readonly IDelay _delay;
    private readonly TimeSpan _leadTime;
    private readonly TimeSpan _requestTimeout;
    private ConnectionProfile _profile;
    private AwsCredentials? _credentials;
    private AuthorizationSnapshot _snapshot = new(AuthorizationStatus.Idle, null, null, null);
    private CancellationTokenSource _context = new();
    private CancellationTokenSource? _request;
    private CancellationTokenSource? _renewal;
    private TaskCompletionSource<AwsCredentials> _ready = NewCompletion();
    private int _waiters;
    private long _generation;
    private bool _disposed;

    public AuthorizationSession(ConnectionProfile profile, IAuthProvider provider,
        IClock? clock = null, IDelay? delay = null, TimeSpan? leadTime = null,
        TimeSpan? requestTimeout = null)
    {
        _profile = profile;
        _provider = provider;
        _clock = clock ?? new SystemClock();
        _delay = delay ?? new SystemDelay();
        _leadTime = leadTime ?? TimeSpan.FromMinutes(5);
        _requestTimeout = requestTimeout ?? TimeSpan.FromMinutes(5);
    }

    public event Action<AuthorizationSnapshot>? Changed;

    public AuthorizationSnapshot Snapshot { get { lock (_gate) { return _snapshot; } } }
    public AuthorizationStatus Status => Snapshot.Status;
    public string? ErrorMessage => Snapshot.ErrorMessage;
    public DateTimeOffset? RoleCredentialsExpiry => Snapshot.RoleCredentialsExpiry;
    public AuthorizationMetadata? Metadata => Snapshot.Metadata;

    public Task<AwsCredentials> AuthenticateAsync(ConnectionProfile profile, CancellationToken cancellationToken) =>
        GetAsync(profile, force: false, interactive: false, rejected: null, cancellationToken);

    public Task<AwsCredentials> RefreshAsync(ConnectionProfile profile, CancellationToken cancellationToken) =>
        GetAsync(profile, force: true, interactive: false, rejected: null, cancellationToken);

    public Task<AwsCredentials> SignInAsync(ConnectionProfile profile, CancellationToken cancellationToken) =>
        GetAsync(profile, force: true, interactive: true, rejected: null, cancellationToken);

    public Task<AwsCredentials> SignInAsync(CancellationToken cancellationToken = default) =>
        SignInAsync(CurrentProfile(), cancellationToken);

    public Task<AwsCredentials> RetryAsync(CancellationToken cancellationToken = default) =>
        RefreshAsync(CurrentProfile(), cancellationToken);

    public Task<AuthorizationMetadata?> GetMetadataAsync(ConnectionProfile profile, CancellationToken cancellationToken)
    {
        lock (_gate)
        {
            CheckContext(profile, cancellationToken);
            return Task.FromResult(_snapshot.Metadata);
        }
    }

    /// <summary>Retries only a rejected AWS authorization, once, without replacing healthy channels.</summary>
    public async Task<T> ExecuteAsync<T>(ConnectionProfile profile,
        Func<AwsCredentials, Task<T>> operation, CancellationToken cancellationToken = default)
    {
        CancellationToken context;
        long generation;
        lock (_gate)
        {
            CheckContext(profile, cancellationToken);
            context = _context.Token;
            generation = _generation;
        }
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(context, cancellationToken);
        AwsCredentials credentials = await GetAsync(profile, false, false, null, linked.Token, generation).ConfigureAwait(false);
        lock (_gate) { CheckGeneration(generation, linked.Token); }
        try { return await operation(credentials).ConfigureAwait(false); }
        catch (ExpiredCredentialsException)
        {
            AwsCredentials fresh = await GetAsync(profile, true, false, credentials, linked.Token, generation).ConfigureAwait(false);
            lock (_gate) { CheckGeneration(generation, linked.Token); }
            try { return await operation(fresh).ConfigureAwait(false); }
            catch (ExpiredCredentialsException)
            {
                RequireSignIn(profile, generation, linked.Token);
                throw new SignInRequiredException();
            }
        }
    }

    public void Apply(ConnectionProfile profile)
    {
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            if (_profile == profile) { return; }
            _profile = profile;
            InvalidateLocked();
        }
        Publish();
    }

    /// <summary>Stop, profile changes and exit invalidate pending recovery, not established transports.</summary>
    public void CancelPending()
    {
        lock (_gate) { if (_disposed) { return; } InvalidateLocked(); }
        Publish();
    }

    public void CheckFreshness()
    {
        lock (_gate)
        {
            if (_disposed || _request is not null || _snapshot.Status != AuthorizationStatus.Ready) { return; }
            DateTimeOffset threshold = _clock.UtcNow + _leadTime;
            if (_snapshot.Metadata is { CanRefresh: false } metadata && metadata.AccessTokenExpiry <= threshold)
            {
                MarkSignInRequiredLocked();
            }
            else if (_snapshot.RoleCredentialsExpiry <= threshold || _snapshot.Metadata?.AccessTokenExpiry <= threshold)
            {
                StartLocked(interactive: false);
            }
            else { return; }
        }
        Publish();
    }

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed) { return; }
            _disposed = true;
            InvalidateLocked();
            _context.Dispose();
        }
        Publish();
    }

    private async Task<AwsCredentials> GetAsync(ConnectionProfile profile, bool force, bool interactive,
        AwsCredentials? rejected, CancellationToken cancellationToken, long? expectedGeneration = null)
    {
        Task<AwsCredentials> ready;
        CancellationToken context;
        long generation;
        lock (_gate)
        {
            if (expectedGeneration is long expected) { CheckGeneration(expected, cancellationToken); }
            CheckContext(profile, cancellationToken);
            if (!interactive && _snapshot.Status == AuthorizationStatus.Ready && _credentials is { } credentials
                && (credentials.Expiration is null || credentials.Expiration > _clock.UtcNow)
                && (!force || (rejected is not null && !ReferenceEquals(rejected, credentials))))
            {
                return credentials;
            }
            if (interactive && _snapshot.Status != AuthorizationStatus.SigningIn)
            {
                StartLocked(interactive: true);
            }
            else if (_request is null && _snapshot.Status != AuthorizationStatus.SignInRequired)
            {
                StartLocked(interactive: false);
            }
            ready = _ready.Task;
            context = _context.Token;
            generation = _generation;
            _waiters++;
        }
        Publish();
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(context, cancellationToken);
        try
        {
            AwsCredentials result = await ready.WaitAsync(linked.Token).ConfigureAwait(false);
            lock (_gate) { CheckGeneration(generation, cancellationToken); }
            return result;
        }
        catch
        {
            // Generation invalidation wins even before linked cancellation callbacks have run.
            lock (_gate) { CheckGeneration(generation, cancellationToken); }
            throw;
        }
        finally
        {
            bool changed = false;
            lock (_gate)
            {
                if (generation == _generation)
                {
                    _waiters--;
                    if (_waiters == 0 && linked.IsCancellationRequested && _snapshot.Status == AuthorizationStatus.SigningIn)
                    {
                        MarkSignInRequiredLocked();
                        changed = true;
                    }
                }
            }
            if (changed) { Publish(); }
        }
    }

    private void StartLocked(bool interactive)
    {
        CancellationTokenSource? previousRequest = _request;
        CancellationTokenSource? previousRenewal = _renewal;
        _renewal = null;
        if (_ready.Task.IsCompleted) { _ready = NewCompletion(); }
        _snapshot = _snapshot with
        {
            Status = interactive ? AuthorizationStatus.SigningIn : AuthorizationStatus.Refreshing,
            ErrorMessage = null,
        };
        var request = CancellationTokenSource.CreateLinkedTokenSource(_context.Token);
        request.CancelAfter(_requestTimeout);
        _request = request;
        ConnectionProfile profile = _profile;
        _ = Task.Run(() => RunRequestAsync(profile, request, interactive));
        previousRequest?.Cancel();
        previousRenewal?.Cancel();
    }

    private async Task RunRequestAsync(ConnectionProfile profile, CancellationTokenSource request, bool interactive)
    {
        try
        {
            AuthorizationMetadata? previousMetadata = await _provider.GetMetadataAsync(profile, request.Token)
                .WaitAsync(request.Token).ConfigureAwait(false);
            lock (_gate)
            {
                if (_request != request) { return; }
                request.Token.ThrowIfCancellationRequested();
                _snapshot = _snapshot with { Metadata = previousMetadata };
            }
            AwsCredentials credentials = await (interactive
                ? _provider.SignInAsync(profile, request.Token)
                : _provider.RefreshAsync(profile, request.Token)).WaitAsync(request.Token).ConfigureAwait(false);
            AuthorizationMetadata? metadata = await _provider.GetMetadataAsync(profile, request.Token)
                .WaitAsync(request.Token).ConfigureAwait(false);
            TaskCompletionSource<AwsCredentials> completion;
            lock (_gate)
            {
                if (_request != request) { return; }
                request.Token.ThrowIfCancellationRequested();
                if (credentials.Expiration <= _clock.UtcNow) { throw new SignInRequiredException(); }
                _request = null;
                _credentials = credentials;
                _snapshot = new(AuthorizationStatus.Ready, credentials.Expiration, metadata, null);
                completion = _ready;
                if (metadata is { CanRefresh: false } && metadata.AccessTokenExpiry <= _clock.UtcNow + _leadTime)
                {
                    _ready = NewCompletion();
                    MarkSignInRequiredLocked();
                }
                else { ScheduleLocked(); }
            }
            Publish();
            completion.TrySetResult(credentials);
            return;
        }
        catch (Exception error)
        {
            lock (_gate)
            {
                if (_request != request) { return; }
                _request = null;
                if (error is SignInRequiredException or ExpiredCredentialsException)
                {
                    MarkSignInRequiredLocked();
                }
                else
                {
                    ConnectionException safe = error is AuthorizationAccessDeniedException
                        ? new AuthorizationAccessDeniedException() : new AuthorizationUnavailableException();
                    _snapshot = _snapshot with
                    {
                        Status = safe is AuthorizationAccessDeniedException
                            ? AuthorizationStatus.AccessDenied : AuthorizationStatus.Unavailable,
                        ErrorMessage = safe.Message,
                    };
                    _ready.TrySetException(safe);
                }
            }
        }
        finally { request.Dispose(); }
        Publish();
    }

    private void ScheduleLocked()
    {
        DateTimeOffset? deadline = _snapshot.RoleCredentialsExpiry;
        if (_snapshot.Metadata is { } metadata && (deadline is null || metadata.AccessTokenExpiry < deadline))
        {
            deadline = metadata.AccessTokenExpiry;
        }
        if (deadline is null) { return; }
        TimeSpan wait = deadline.Value - _clock.UtcNow - _leadTime;
        if (wait < TimeSpan.FromSeconds(30)) { wait = TimeSpan.FromSeconds(30); }
        var source = CancellationTokenSource.CreateLinkedTokenSource(_context.Token);
        _renewal = source;
        _ = RenewAfterAsync(wait, source);
    }

    private async Task RenewAfterAsync(TimeSpan wait, CancellationTokenSource source)
    {
        try
        {
            await _delay.WaitAsync(wait, source.Token).ConfigureAwait(false);
            source.Token.ThrowIfCancellationRequested();
            lock (_gate) { if (_renewal != source) { return; } }
            CheckFreshness();
        }
        catch (OperationCanceledException) { }
        catch (Exception)
        {
            lock (_gate)
            {
                if (_renewal != source) { return; }
                _snapshot = _snapshot with
                {
                    Status = AuthorizationStatus.Unavailable,
                    ErrorMessage = "Authorization renewal could not be scheduled. Retry authorization.",
                };
            }
            Publish();
        }
        finally
        {
            lock (_gate) { if (_renewal == source) { _renewal = null; } }
            source.Dispose();
        }
    }

    private void RequireSignIn(ConnectionProfile profile, long generation, CancellationToken cancellationToken)
    {
        lock (_gate)
        {
            CheckGeneration(generation, cancellationToken);
            CheckContext(profile, cancellationToken);
            MarkSignInRequiredLocked();
        }
        Publish();
    }

    private void MarkSignInRequiredLocked()
    {
        CancellationTokenSource? previousRequest = _request;
        CancellationTokenSource? previousRenewal = _renewal;
        _request = null;
        _credentials = null;
        _renewal = null;
        if (_ready.Task.IsCompleted) { _ready = NewCompletion(); }
        _snapshot = _snapshot with { Status = AuthorizationStatus.SignInRequired, ErrorMessage = new SignInRequiredException().Message };
        previousRequest?.Cancel();
        previousRenewal?.Cancel();
    }

    private void InvalidateLocked()
    {
        CancellationTokenSource previousContext = _context;
        TaskCompletionSource<AwsCredentials> previousReady = _ready;
        _generation++;
        _context = new();
        _request = null;
        _renewal = null;
        _ready = NewCompletion();
        _waiters = 0;
        _credentials = null;
        _snapshot = new(AuthorizationStatus.Idle, null, null, null);
        // Cancel can run provider/awaiter callbacks inline. Retire all old state before invoking it.
        previousReady.TrySetCanceled(previousContext.Token);
        previousContext.Cancel();
        previousContext.Dispose();
    }

    private ConnectionProfile CurrentProfile() { lock (_gate) { return _profile; } }
    private void CheckGeneration(long generation, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (_generation != generation) { throw new OperationCanceledException("The authorization context changed."); }
    }

    private void CheckContext(ConnectionProfile profile, CancellationToken cancellationToken)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        cancellationToken.ThrowIfCancellationRequested();
        if (profile != _profile) { throw new OperationCanceledException("The authorization profile changed."); }
    }
    private void Publish()
    {
        AuthorizationSnapshot snapshot = Snapshot;
        foreach (Delegate handler in Changed?.GetInvocationList() ?? [])
        {
            // A failing UI subscriber must not turn a successful renewal into an auth failure.
            try { ((Action<AuthorizationSnapshot>)handler)(snapshot); }
            catch (Exception) { }
        }
    }
    private static TaskCompletionSource<AwsCredentials> NewCompletion() => new(TaskCreationOptions.RunContinuationsAsynchronously);
    private sealed class SystemClock : IClock { public DateTimeOffset UtcNow => DateTimeOffset.UtcNow; }
    private sealed class SystemDelay : IDelay
    {
        public Task WaitAsync(TimeSpan duration, CancellationToken cancellationToken) => Task.Delay(duration, cancellationToken);
    }
}
