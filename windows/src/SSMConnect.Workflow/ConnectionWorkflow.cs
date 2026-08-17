using SSMConnect.Domain;

namespace SSMConnect.Workflow;

/// <summary>
/// Orchestrates the connection lifecycle against injected ports. This is the portable half of the
/// client: it holds the ordered algorithm and the state transitions, and nothing else.
/// </summary>
/// <remarks>
/// It must not open browsers, touch the clipboard, post notifications, or signal the operating
/// system. Those are shell policy, driven by <see cref="IEventSink"/> events. The project targets
/// plain <c>net10.0</c> so a UI or SDK reference cannot compile here by accident.
/// <para>
/// The behavior encoded here is fixed by <c>contracts/fixtures/workflows</c>, which the macOS
/// client runs against its own implementation. Changing an order or a transition here without
/// changing a fixture means the two clients have drifted.
/// </para>
/// </remarks>
public sealed class ConnectionWorkflow
{
    private readonly IAuthProvider _auth;
    private readonly IEc2Provider _ec2;
    private readonly ISsmProvider _ssm;
    private readonly ISecretsProvider _secrets;
    private readonly IIdentityProvider _identity;
    private readonly IAgentClient _agent;
    private readonly ITunnelProvider _tunnel;
    private readonly IReadinessProbe _readiness;
    private readonly IDcvLauncher _dcv;
    private readonly IInstanceIdStore _instanceIds;
    private readonly IDelay _delay;
    private readonly IEventSink _events;
    private readonly ConnectionTimeouts _timeouts;

    private readonly Lock _gate = new();
    private readonly List<Task> _pending = [];

    private AwsCredentials? _credentials;
    private ITunnelHandle? _handle;
    private CancellationTokenSource? _cancellation;
    private ConnectionState _state = ConnectionState.Disconnected;

    public ConnectionWorkflow(
        IAuthProvider auth,
        IEc2Provider ec2,
        ISsmProvider ssm,
        ISecretsProvider secrets,
        IIdentityProvider identity,
        IAgentClient agent,
        ITunnelProvider tunnel,
        IReadinessProbe readiness,
        IDcvLauncher dcv,
        IInstanceIdStore instanceIds,
        IDelay delay,
        IEventSink events,
        ConnectionProfile profile,
        AppSettings settings,
        ConnectionTimeouts? timeouts = null)
    {
        _auth = auth;
        _ec2 = ec2;
        _ssm = ssm;
        _secrets = secrets;
        _identity = identity;
        _agent = agent;
        _tunnel = tunnel;
        _readiness = readiness;
        _dcv = dcv;
        _instanceIds = instanceIds;
        _delay = delay;
        _events = events;
        Profile = profile;
        Settings = settings;
        _timeouts = timeouts ?? ConnectionTimeouts.Default;
    }

    public ConnectionProfile Profile { get; private set; }

    public AppSettings Settings { get; private set; }

    public ConnectionState State
    {
        get => _state;
        private set
        {
            if (_state == value)
            {
                return;
            }

            _state = value;
            _events.StateChanged(value);
        }
    }

    public string? ErrorMessage { get; private set; }

    public ErrorCategory ErrorCategory { get; private set; } = ErrorCategory.None;

    /// <summary>A non-fatal note shown while still connected, such as the viewer being absent.</summary>
    public string? WarningMessage { get; private set; }

    public string? InstanceId { get; private set; }

    public int? LocalPort { get; private set; }

    /// <summary>The DCV password, in memory only, for the shell's masked display and copy action.</summary>
    public string? Password { get; private set; }

    public bool TunnelActive => _handle is not null;

    // MARK: Public API

    /// <summary>
    /// Applies a new profile or settings. Ignored while a connection is in flight so the target is
    /// never swapped out from under an active tunnel; settings that are safe to change live do.
    /// </summary>
    public void Apply(ConnectionProfile profile, AppSettings settings)
    {
        Settings = settings;
        if (State == ConnectionState.Disconnected)
        {
            Profile = profile;
        }
    }

    /// <summary>Sweeps stale connection files and auto-connects a configured profile.</summary>
    public void OnLaunch()
    {
        _dcv.SweepOrphanedFiles();
        if (Settings.AutoConnect && State == ConnectionState.Disconnected && Profile.IsConfigured)
        {
            Connect();
        }
    }

    /// <summary>Runs the full connection flow. A no-op if already connecting or connected.</summary>
    public void Connect()
    {
        if (State == ConnectionState.Connected)
        {
            return;
        }

        Launch(RunConnectAsync);
    }

    /// <summary>Tears any tunnel down and returns to disconnected.</summary>
    public void Disconnect()
    {
        Task? previous = CancelCurrent();
        Launch(async _ =>
        {
            await AwaitQuietlyAsync(previous).ConfigureAwait(false);
            await TeardownTunnelAsync().ConfigureAwait(false);
            ResetToDisconnected();
        });
    }

    /// <summary>Tears down and re-runs the full flow, re-resolving the instance.</summary>
    public void Reconnect()
    {
        Task? previous = CancelCurrent();
        Launch(async token =>
        {
            await AwaitQuietlyAsync(previous).ConfigureAwait(false);
            await TeardownTunnelAsync().ConfigureAwait(false);
            await RunConnectAsync(token).ConfigureAwait(false);
        });
    }

    /// <summary>Stops the workstation instance and disconnects.</summary>
    public void StopWorkstation()
    {
        string? instanceId = InstanceId;
        AwsCredentials? credentials = _credentials;
        if (instanceId is null || credentials is null)
        {
            return;
        }

        Task? previous = CancelCurrent();
        Launch(async token =>
        {
            await AwaitQuietlyAsync(previous).ConfigureAwait(false);
            await TeardownTunnelAsync().ConfigureAwait(false);
            try
            {
                _events.Log("ec2", $"Stopping instance {instanceId}…");
                await _ec2.StopInstanceAsync(instanceId, Profile.ResourceRegion, credentials, token)
                    .ConfigureAwait(false);
                ResetToDisconnected();
                _events.Notify(ConnectionNotification.Stopped);
            }
            catch (Exception error) when (error is not OperationCanceledException)
            {
                Fail(error);
            }
        });
    }

    /// <summary>
    /// Health-checks an apparently connected tunnel after the machine wakes. The plugin process
    /// survives sleep but its data channel does not, so the client can show connected while the
    /// viewer has already dropped. A failed check reconnects.
    /// </summary>
    public async Task HandleSystemWakeAsync(CancellationToken cancellationToken = default)
    {
        if (State != ConnectionState.Connected || LocalPort is not int port)
        {
            return;
        }

        bool healthy = await _readiness
            .WaitUntilReadyAsync(port, TimeSpan.FromSeconds(8), TimeSpan.FromSeconds(2), cancellationToken)
            .ConfigureAwait(false);
        if (healthy)
        {
            return;
        }

        _events.Log("tunnel", "Workstation not responding after wake from sleep; reconnecting…");
        Reconnect();
    }

    /// <summary>
    /// Best-effort teardown for application termination. Shutdown paths cannot always await, so the
    /// adapter's process containment is the backstop; this is the graceful attempt that runs first.
    /// </summary>
    public async Task ShutdownAsync()
    {
        // The cancelled work is not awaited: shutdown must not block on a stage that may be
        // mid-timeout. Terminating the tunnel is what actually matters here.
        _ = CancelCurrent();
        await TeardownTunnelAsync().ConfigureAwait(false);
    }

    /// <summary>
    /// Awaits every in-flight operation, including work a tunnel monitor started after the caller
    /// began waiting, such as an auto-reconnect. Used by tests and by orderly shutdown.
    /// </summary>
    public async Task WaitForQuiescenceAsync()
    {
        while (true)
        {
            Task[] snapshot;
            lock (_gate)
            {
                _pending.RemoveAll(task => task.IsCompleted);
                snapshot = [.. _pending];
            }

            if (snapshot.Length == 0)
            {
                return;
            }

            await Task.WhenAll(snapshot.Select(AwaitQuietlyAsync)).ConfigureAwait(false);
        }
    }

    // MARK: Connection flow

    private async Task RunConnectAsync(CancellationToken cancellationToken)
    {
        ErrorMessage = null;
        ErrorCategory = ErrorCategory.None;
        WarningMessage = null;
        _events.Log("ui", $"Connecting to {Profile.Name} ({Profile.ResourceRegion})…");

        try
        {
            // 0. Pre-flight. A malformed region would otherwise reach the SDK's endpoint resolver
            //    and surface as an opaque client error, so both regions are validated here, before
            //    any state transition or network call.
            if (!AwsRegion.IsValid(Profile.SsoRegion))
            {
                throw new ProfileConfigurationException("SSO region", Profile.SsoRegion);
            }

            if (!AwsRegion.IsValid(Profile.ResourceRegion))
            {
                throw new ProfileConfigurationException("resource region", Profile.ResourceRegion);
            }

            // 1. Authenticate.
            State = ConnectionState.Authenticating;
            AwsCredentials credentials = await WithStageTimeoutAsync(
                "Sign-in",
                _timeouts.Authenticate,
                token => _auth.AuthenticateAsync(Profile, token),
                cancellationToken).ConfigureAwait(false);
            _credentials = credentials;
            _events.Log("auth", "Authenticated; SSO session valid.");

            // 2. Resolve the workstation by tag.
            State = ConnectionState.Resolving;
            Ec2Instance instance = await WithReauthAsync(
                creds => WithStageTimeoutAsync(
                    "Finding instance",
                    _timeouts.Resolve,
                    token => _ec2.ResolveInstanceAsync(
                        Profile.InstanceTagKey, Profile.InstanceTagValue, Profile.ResourceRegion, creds, token),
                    cancellationToken),
                cancellationToken).ConfigureAwait(false);

            InstanceId = instance.Id;
            _events.Log("ec2", $"Resolved instance {instance.Id} ({instance.State.Wire()}).");
            if (instance.State.IsTerminal())
            {
                throw new InstanceTerminatedException(instance.Id);
            }

            // Instance replacement: a rebuilt workstation has a new ID, so any tunnel, handle, or
            // port bound to the old one is stale and must never be reused.
            string? previousId = _instanceIds.LastInstanceId(Profile.Id);
            if (previousId is not null && previousId != instance.Id)
            {
                _events.Log("ec2", $"Workstation instance changed ({previousId} → {instance.Id}); resetting stale tunnel state.");
                await TeardownTunnelAsync().ConfigureAwait(false);
                LocalPort = null;
            }

            _instanceIds.SetLastInstanceId(Profile.Id, instance.Id);

            // 3. Auto-start anything not already running.
            if (instance.State != Ec2InstanceState.Running)
            {
                State = ConnectionState.Starting;
                _events.Log("ec2", $"Instance is {instance.State.Wire()}; starting it…");
                instance = await WithReauthAsync(
                    async creds =>
                    {
                        await _ec2.StartInstanceAsync(instance.Id, Profile.ResourceRegion, creds, cancellationToken)
                            .ConfigureAwait(false);
                        return await _ec2.PollUntilRunningAsync(
                            instance.Id, Profile.ResourceRegion, creds,
                            _timeouts.Start, _timeouts.StartPollInterval, cancellationToken).ConfigureAwait(false);
                    },
                    cancellationToken).ConfigureAwait(false);
                _events.Log("ec2", "Instance is now running.");
            }

            // 4. Wait for the SSM agent.
            State = ConnectionState.WaitingForSsm;
            _events.Log("ssm", "Waiting for the SSM agent to come online…");
            await WithReauthAsync(
                async creds =>
                {
                    await _ssm.WaitForSsmOnlineAsync(
                        instance.Id, Profile.ResourceRegion, creds,
                        _timeouts.Ssm, _timeouts.SsmPollInterval, cancellationToken).ConfigureAwait(false);
                    return true;
                },
                cancellationToken).ConfigureAwait(false);
            _events.Log("ssm", "SSM agent is online.");

            // 5. Open the tunnel and hard-gate on endpoint readiness. The viewer is never launched
            //    into an endpoint that has not answered.
            State = ConnectionState.Tunneling;
            ITunnelHandle handle = await EstablishReadyTunnelAsync(instance.Id, cancellationToken)
                .ConfigureAwait(false);

            // 6. Auto-login. Failures here are non-fatal: the tunnel stays up and the user is warned.
            if (Profile.ResolvedConnectMode == ConnectMode.SingleUser)
            {
                await FetchSecretAndLaunchAsync(cancellationToken).ConfigureAwait(false);
            }
            else
            {
                await EnsureSessionAndLaunchMultiUserAsync(instance.Id, cancellationToken).ConfigureAwait(false);
            }

            // 7. Connected.
            State = ConnectionState.Connected;
            _events.Log("tunnel", $"Connected: 127.0.0.1:{Profile.LocalPort} → {instance.Id}:{Profile.RemotePort}.");
            StartTunnelMonitor(handle);
            _events.Notify(ConnectionNotification.Connected);
        }
        catch (OperationCanceledException)
        {
            // Disconnect or reconnect cancelled us; whichever it was owns the resulting state.
        }
        catch (Exception error)
        {
            await TeardownTunnelAsync().ConfigureAwait(false);
            Fail(error);
        }
    }

    private async Task<ITunnelHandle> EstablishTunnelAsync(string instanceId, CancellationToken cancellationToken)
    {
        SsmSession session = await WithReauthAsync(
            creds => _ssm.StartSessionAsync(
                instanceId, Profile.ResourceRegion, creds, Profile.LocalPort, Profile.RemotePort, cancellationToken),
            cancellationToken).ConfigureAwait(false);

        ITunnelHandle handle = await WithStageTimeoutAsync(
            "Opening tunnel",
            _timeouts.Tunnel,
            token => _tunnel.StartTunnelAsync(
                session, Profile.ResourceRegion, instanceId, Profile.LocalPort, Profile.RemotePort, token),
            cancellationToken).ConfigureAwait(false);

        _handle = handle;
        LocalPort = Profile.LocalPort;
        return handle;
    }

    /// <summary>
    /// Opens the tunnel and confirms the endpoint is genuinely usable before returning. A readiness
    /// miss tears the tunnel down and re-establishes, up to a bounded number of attempts, then
    /// rethrows.
    /// </summary>
    private async Task<ITunnelHandle> EstablishReadyTunnelAsync(string instanceId, CancellationToken cancellationToken)
    {
        int attempt = 0;
        while (true)
        {
            attempt++;
            ITunnelHandle handle = await EstablishTunnelAsync(instanceId, cancellationToken).ConfigureAwait(false);
            try
            {
                await AssertEndpointReadyAsync(Profile.LocalPort, cancellationToken).ConfigureAwait(false);
                return handle;
            }
            catch (DcvReadinessException error)
            {
                await TeardownTunnelAsync().ConfigureAwait(false);
                if (attempt > _timeouts.EstablishRetryAttempts)
                {
                    throw;
                }

                _events.Log("tunnel", $"Endpoint not ready ({error.Message}); re-establishing (attempt {attempt})…");
                await _delay.WaitAsync(_timeouts.EstablishRetryBackoff * attempt, cancellationToken)
                    .ConfigureAwait(false);
            }
        }
    }

    /// <summary>
    /// Polls the DCV server over the tunnel until it answers. A successful probe connects to the
    /// loopback port, so it also proves the tunnel is listening; only on failure is a separate TCP
    /// check run, and only to classify why, so the user gets an accurate message.
    /// </summary>
    private async Task AssertEndpointReadyAsync(int port, CancellationToken cancellationToken)
    {
        if (await _readiness.WaitUntilReadyAsync(port, _timeouts.DcvReady, _timeouts.DcvReadyPollInterval, cancellationToken)
                .ConfigureAwait(false))
        {
            return;
        }

        bool listening = await _readiness.IsListeningAsync(port, _timeouts.TunnelListen, cancellationToken)
            .ConfigureAwait(false);
        throw listening
            ? DcvReadinessException.DcvServerNotReady(port)
            : DcvReadinessException.TunnelNotEstablished(port);
    }

    private async Task FetchSecretAndLaunchAsync(CancellationToken cancellationToken)
    {
        if (Profile.SecretId is not string secretId)
        {
            return;
        }

        try
        {
            string password = await WithReauthAsync(
                creds => _secrets.FetchSecretAsync(secretId, Profile.ResourceRegion, creds, cancellationToken),
                cancellationToken).ConfigureAwait(false);

            Password = password;
            _events.PasswordAvailable(password);

            if (!_dcv.IsViewerInstalled())
            {
                WarningMessage = "Amazon DCV Viewer is not installed.";
                return;
            }

            await _dcv.LaunchAsync(DcvConnectionFile.SingleUser(Profile.LocalPort, password), cancellationToken)
                .ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception error)
        {
            WarningMessage = error.Message;
        }
    }

    /// <summary>
    /// Multi-user auto-login: resolve the caller's identity, have the on-box agent ensure that
    /// user's session over a transient tunnel, then launch with a freshly minted token.
    /// </summary>
    private async Task EnsureSessionAndLaunchMultiUserAsync(string instanceId, CancellationToken cancellationToken)
    {
        try
        {
            AwsCredentials credentials = _credentials ?? throw new SignInRequiredException();

            string username = await _identity
                .ResolveIdentityAsync(Profile.ResourceRegion, credentials, cancellationToken).ConfigureAwait(false);
            _events.Log("auth", $"Multi-user identity resolved to '{username}'.");

            // The agent tunnel is needed for this one call only — DCV reaches the verifier locally
            // on the instance, not through the client — so it is always torn down straight after,
            // including on failure, or a rejected call leaks a plugin holding the agent port.
            int agentPort = Profile.ResolvedAgentRemotePort;
            ITunnelHandle agentHandle = await OpenAgentTunnelAsync(instanceId, agentPort, cancellationToken)
                .ConfigureAwait(false);

            EnsureSessionResult provisioned;
            try
            {
                provisioned = await EnsureSessionWithRetryAsync(agentPort, credentials, cancellationToken)
                    .ConfigureAwait(false);
            }
            finally
            {
                await agentHandle.TerminateAsync().ConfigureAwait(false);
            }

            _events.Log("tunnel", $"Agent ensured session '{provisioned.SessionId}' for '{provisioned.User}'.");

            if (!_dcv.IsViewerInstalled())
            {
                WarningMessage = "Amazon DCV Viewer is not installed.";
                return;
            }

            // Minted last, immediately before launch, so it is as fresh as possible.
            string token = _identity.PresignedIdentityToken(Profile.ResourceRegion, credentials);
            await _dcv.LaunchAsync(
                DcvConnectionFile.MultiUser(Profile.LocalPort, provisioned.User, provisioned.SessionId, token),
                cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception error)
        {
            WarningMessage = error.Message;
            _events.Log("tunnel", $"Multi-user connect issue: {error.Message}");
        }
    }

    /// <summary>
    /// Calls the agent, retrying transport failures while the freshly opened tunnel becomes ready.
    /// The call is idempotent so retrying is safe, but a real response from the agent is not
    /// transient and propagates immediately. A fresh token is minted per attempt to avoid expiry.
    /// </summary>
    private async Task<EnsureSessionResult> EnsureSessionWithRetryAsync(
        int agentPort, AwsCredentials credentials, CancellationToken cancellationToken)
    {
        Exception last = new SignInRequiredException();
        for (int attempt = 1; attempt <= _timeouts.EnsureSessionAttempts; attempt++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                string token = _identity.PresignedIdentityToken(Profile.ResourceRegion, credentials);
                return await _agent.EnsureSessionAsync(agentPort, token, cancellationToken).ConfigureAwait(false);
            }
            catch (AgentException agentError) when (agentError.Responded)
            {
                throw;
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (Exception error)
            {
                last = error;
                await _delay.WaitAsync(_timeouts.EnsureSessionRetryDelay, cancellationToken).ConfigureAwait(false);
            }
        }

        throw last;
    }

    /// <summary>
    /// Opens a transient tunnel to the on-box agent. Never stored as the monitored handle: the
    /// caller owns it and terminates it as soon as the agent call returns.
    /// </summary>
    private async Task<ITunnelHandle> OpenAgentTunnelAsync(string instanceId, int port, CancellationToken cancellationToken)
    {
        SsmSession session = await WithReauthAsync(
            creds => _ssm.StartSessionAsync(instanceId, Profile.ResourceRegion, creds, port, port, cancellationToken),
            cancellationToken).ConfigureAwait(false);

        return await WithStageTimeoutAsync(
            "Opening agent tunnel",
            _timeouts.Tunnel,
            token => _tunnel.StartTunnelAsync(session, Profile.ResourceRegion, instanceId, port, port, token),
            cancellationToken).ConfigureAwait(false);
    }

    // MARK: Auto-reconnect

    /// <summary>
    /// Watches a tunnel for an unexpected exit. The wait itself is deliberately untracked: it lives
    /// as long as the tunnel does, so counting it as in-flight work would mean an orderly wait for
    /// quiescence could never complete. The response to a drop is tracked.
    /// </summary>
    private void StartTunnelMonitor(ITunnelHandle handle)
    {
        _ = Task.Run(async () =>
        {
            TunnelDropReason reason;
            try
            {
                reason = await handle.Dropped.ConfigureAwait(false);
            }
            catch (Exception)
            {
                return;
            }

            if (reason is TunnelDropReason.ProcessExited exited)
            {
                Launch(token => HandleTunnelDropAsync(exited, token));
            }
        });
    }

    private async Task HandleTunnelDropAsync(TunnelDropReason.ProcessExited exited, CancellationToken cancellationToken)
    {
        _handle = null;
        string detail = string.IsNullOrEmpty(exited.StandardError)
            ? $"exit code {exited.ExitCode}"
            : exited.StandardError;

        if (!Settings.AutoReconnect)
        {
            Fail(new TunnelException($"The SSM tunnel dropped (exit code {exited.ExitCode})."));
            return;
        }

        if (InstanceId is not string instanceId)
        {
            Fail(new TunnelException($"The SSM tunnel dropped ({detail})."));
            return;
        }

        _events.Log("tunnel", $"Tunnel dropped ({detail}); reconnecting…");
        _events.Notify(ConnectionNotification.Reconnecting);

        for (int attempt = 1; attempt <= _timeouts.MaxReconnectAttempts; attempt++)
        {
            try
            {
                await _delay.WaitAsync(_timeouts.ReconnectBackoff, cancellationToken).ConfigureAwait(false);
                State = ConnectionState.Tunneling;
                ITunnelHandle handle = await EstablishTunnelAsync(instanceId, cancellationToken).ConfigureAwait(false);
                State = ConnectionState.Connected;
                StartTunnelMonitor(handle);
                _events.Log("tunnel", $"Reconnected after {attempt} attempt(s).");
                _events.Notify(ConnectionNotification.Connected);
                return;
            }
            catch (OperationCanceledException)
            {
                return;
            }
            catch (Exception error)
            {
                if (attempt == _timeouts.MaxReconnectAttempts)
                {
                    // Never leave a half-open plugin process behind.
                    await TeardownTunnelAsync().ConfigureAwait(false);
                    Fail(new TunnelException(
                        $"Auto-reconnect failed after {_timeouts.MaxReconnectAttempts} attempts ({detail}): {error.Message}",
                        error));
                }
            }
        }
    }

    // MARK: Credential expiry recovery

    /// <summary>
    /// Runs an operation with the current credentials. On an expiry failure it re-authenticates
    /// once and retries, deliberately without tearing down an active tunnel and without returning
    /// to the authenticating state.
    /// </summary>
    private async Task<T> WithReauthAsync<T>(
        Func<AwsCredentials, Task<T>> operation, CancellationToken cancellationToken)
    {
        AwsCredentials credentials = _credentials ?? throw new SignInRequiredException();
        try
        {
            return await operation(credentials).ConfigureAwait(false);
        }
        catch (ExpiredCredentialsException)
        {
            _events.Log("auth", "SSO session expired; re-authenticating…");
            _events.Notify(ConnectionNotification.SignInRequired);
            AwsCredentials fresh = await _auth.AuthenticateAsync(Profile, cancellationToken).ConfigureAwait(false);
            _credentials = fresh;
            return await operation(fresh).ConfigureAwait(false);
        }
    }

    private static async Task<T> WithStageTimeoutAsync<T>(
        string stage, TimeSpan budget, Func<CancellationToken, Task<T>> operation, CancellationToken cancellationToken)
    {
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(budget);
        try
        {
            return await operation(timeout.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
        {
            throw new StageTimeoutException(stage);
        }
    }

    // MARK: Helpers

    private void Launch(Func<CancellationToken, Task> body)
    {
        CancellationTokenSource source;
        lock (_gate)
        {
            _cancellation ??= new CancellationTokenSource();
            source = _cancellation;
        }

        Task task = Task.Run(async () =>
        {
            try
            {
                await body(source.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                // Cancellation is an ordinary outcome; whoever cancelled owns the resulting state.
            }
        });

        lock (_gate)
        {
            _pending.Add(task);
        }
    }

    /// <summary>Cancels in-flight work and returns the task to await, if any.</summary>
    private Task? CancelCurrent()
    {
        CancellationTokenSource? source;
        Task? previous;
        lock (_gate)
        {
            source = _cancellation;
            _cancellation = null;
            _pending.RemoveAll(task => task.IsCompleted);
            previous = _pending.Count == 0 ? null : Task.WhenAll([.. _pending]);
        }

        source?.Cancel();
        source?.Dispose();
        return previous;
    }

    private static async Task AwaitQuietlyAsync(Task? task)
    {
        if (task is null)
        {
            return;
        }

        try
        {
            await task.ConfigureAwait(false);
        }
        catch (Exception)
        {
            // The originating operation already recorded its own outcome.
        }
    }

    private async Task TeardownTunnelAsync()
    {
        ITunnelHandle? handle = _handle;
        _handle = null;
        if (handle is not null)
        {
            await handle.TerminateAsync().ConfigureAwait(false);
        }
    }

    private void ResetToDisconnected()
    {
        State = ConnectionState.Disconnected;
        ErrorMessage = null;
        ErrorCategory = ErrorCategory.None;
        WarningMessage = null;
        InstanceId = null;
        LocalPort = null;
        Password = null;
    }

    private void Fail(Exception error)
    {
        ErrorMessage = error.Message;
        ErrorCategory = ErrorCategories.Classify(error);
        _events.Log("ui", $"Error: {error.Message}");
        State = ConnectionState.Error;
    }
}
