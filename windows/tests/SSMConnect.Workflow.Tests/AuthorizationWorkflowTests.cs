using System.Collections.Concurrent;
using System.Text.Json;
using SSMConnect.Domain;
using SSMConnect.Workflow.Tests.Fixtures;
using static SSMConnect.Workflow.Tests.AuthorizationSessionTests;

#pragma warning disable xUnit1051 // Tests explicitly own authorization cancellation and fake time.

namespace SSMConnect.Workflow.Tests;

public sealed class AuthorizationWorkflowTests
{
    [Theory]
    [InlineData(ConnectMode.SingleUser)]
    [InlineData(ConnectMode.MultiUser)]
    public async Task TunnelOnlyGatesOnTcpAndNeverCallsDcvOrDesktopProvisioning(ConnectMode mode)
    {
        var rig = new Rig(Profile() with { ConnectAction = ConnectAction.TunnelOnly, ConnectMode = mode, SecretId = "secret-id" });
        rig.Workflow.Connect();
        await rig.Workflow.WaitForQuiescenceAsync();
        Assert.Equal(ConnectionState.Connected, rig.Workflow.State);
        Assert.True(rig.Workflow.TunnelActive);
        Assert.Equal(1, rig.Recorder.CountOf("ReadinessProbe", "isListening"));
        Assert.Equal(0, rig.Recorder.CountOf("ReadinessProbe", "waitUntilReady"));
        Assert.Equal(0, rig.Recorder.CountOf("SecretsProvider", "fetchSecret"));
        Assert.Equal(0, rig.Recorder.CountOf("IdentityProvider", "resolveIdentity"));
        Assert.Equal(0, rig.Recorder.CountOf("IdentityProvider", "presignedIdentityToken"));
        Assert.Equal(0, rig.Recorder.CountOf("AgentClient", "ensureSession"));
        Assert.Equal(0, rig.Recorder.CountOf("DCVLauncher", "launch"));
        Assert.Null(rig.Workflow.Password);
        await rig.Workflow.ShutdownAsync();
    }

    [Fact]
    public async Task TunnelOnlyListenerFailureIsHardGateAndTearsDownTunnel()
    {
        var rig = new Rig(Profile() with { ConnectAction = ConnectAction.TunnelOnly }, listening: false);
        rig.Workflow.Connect();
        await rig.Workflow.WaitForQuiescenceAsync();
        Assert.Equal(ConnectionState.Error, rig.Workflow.State);
        Assert.False(rig.Workflow.TunnelActive);
        Assert.Equal(ErrorCategory.Readiness, rig.Workflow.ErrorCategory);
        Assert.Equal(0, rig.Recorder.CountOf("ReadinessProbe", "waitUntilReady"));
        Assert.All(rig.Tunnels.Handles, handle => Assert.True(handle.Terminated));
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task EnabledUnsupportedAdaptersAreRejectedBeforeAnyAwsOrAuthCall(bool web)
    {
        var profile = Profile() with
        {
            WebForwards = new() { Enabled = web },
            RemoteDevelopment = new() { Enabled = !web },
        };
        var rig = new Rig(profile);
        rig.Workflow.Connect();
        await rig.Workflow.WaitForQuiescenceAsync();
        Assert.Equal(ErrorCategory.Configuration, rig.Workflow.ErrorCategory);
        Assert.DoesNotContain(rig.Recorder.Calls, call =>
            call.Port is "AuthProvider" or "EC2Provider" or "SSMProvider" or "SecretsProvider" or "IdentityProvider");
    }

    [Fact]
    public async Task DefaultActionStillUsesDcvReadinessAndLaunchesViewer()
    {
        var rig = new Rig(Profile() with { SecretId = "secret-id" });
        rig.Workflow.Connect();
        await rig.Workflow.WaitForQuiescenceAsync();
        Assert.Equal(ConnectionState.Connected, rig.Workflow.State);
        Assert.Equal(1, rig.Recorder.CountOf("ReadinessProbe", "waitUntilReady"));
        Assert.Equal(1, rig.Recorder.CountOf("SecretsProvider", "fetchSecret"));
        Assert.Equal(1, rig.Recorder.CountOf("DCVLauncher", "launch"));
        await rig.Workflow.ShutdownAsync();
    }

    [Fact] // AUTH-03: exercises the actual workflow, not only the wrapper.
    public async Task PendingWorkflowResumesAfterSignInWithoutSecondConnect()
    {
        var profile = Profile();
        var provider = new TestAuth { Silent = _ => Task.FromException<AwsCredentials>(new SignInRequiredException()) };
        using var session = NewSession(profile, provider);
        var rig = new Rig(profile, session);
        Task required = UntilStatus(session, AuthorizationStatus.SignInRequired);
        rig.Workflow.Connect();
        await required;
        Assert.Equal(ConnectionState.Authenticating, rig.Workflow.State);
        Assert.Equal(0, rig.Recorder.CountOf("EC2Provider", "resolveInstance"));
        await session.SignInAsync();
        await rig.Workflow.WaitForQuiescenceAsync();
        Assert.Equal(ConnectionState.Connected, rig.Workflow.State);
        Assert.Equal(1, provider.InteractiveCalls);
        Assert.Equal(1, rig.Recorder.CountOf("EC2Provider", "resolveInstance"));
        await rig.Workflow.ShutdownAsync();
    }

    [Theory] // AUTH-05
    [InlineData(false)]
    [InlineData(true)]
    public async Task StopOrApplyDuringLoginCancelsWorkflowAndNeverReplays(bool apply)
    {
        var profile = Profile();
        var response = Completion<AwsCredentials>();
        var provider = new TestAuth
        {
            Silent = _ => Task.FromException<AwsCredentials>(new SignInRequiredException()),
            Interactive = _ => response.Task,
        };
        using var session = NewSession(profile, provider);
        var rig = new Rig(profile, session);
        Task required = UntilStatus(session, AuthorizationStatus.SignInRequired);
        rig.Workflow.Connect();
        await required;
        Task<AwsCredentials> login = session.SignInAsync();
        await provider.InteractiveStarted.Task;
        ConnectionProfile next = profile with { InstanceTagValue = "different-target" };
        if (apply) { rig.Workflow.Apply(next, AppSettings.Default); }
        else { rig.Workflow.StopWorkstation(); }
        response.SetResult(Credentials("late"));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => login);
        await rig.Workflow.WaitForQuiescenceAsync();
        Assert.Equal(ConnectionState.Disconnected, rig.Workflow.State);
        Assert.Equal(0, rig.Recorder.CountOf("EC2Provider", "resolveInstance"));
        Assert.Equal(0, rig.Recorder.CountOf("SSMProvider", "startSession"));
        if (apply) { Assert.Equal(next, rig.Workflow.Profile); }
    }

    [Fact] // AUTH-06
    public async Task ProactiveSignInRequirementKeepsHealthyTransportAndPassword()
    {
        var profile = Profile() with { SecretId = "secret-id" };
        var clock = new TestClock();
        var provider = new TestAuth { Metadata = new(Start.AddMinutes(10), false) };
        using var session = new AuthorizationSession(profile, provider, clock, new ControlledDelay());
        var rig = new Rig(profile, session);
        rig.Workflow.Connect();
        await rig.Workflow.WaitForQuiescenceAsync();
        Assert.Equal(ConnectionState.Connected, rig.Workflow.State);
        string? password = rig.Workflow.Password;
        clock.UtcNow = Start.AddMinutes(5);
        session.CheckFreshness();
        Assert.Equal(AuthorizationStatus.SignInRequired, session.Status);
        Assert.Equal(ConnectionState.Connected, rig.Workflow.State);
        Assert.Equal(password, rig.Workflow.Password);
        Assert.True(rig.Workflow.TunnelActive);
        Assert.False(Assert.Single(rig.Tunnels.Handles).Terminated);
        Assert.Equal(0, provider.InteractiveCalls);
        await rig.Workflow.ShutdownAsync();
    }

    [Theory] // AUTH-05, AUTH-06
    [InlineData(false)]
    [InlineData(true)]
    public async Task ChangedApplyRetainsHealthyTransportAndCancelsPendingRecovery(bool reselectOriginal)
    {
        var profile = Profile() with { SecretId = "secret-id" };
        var provider = new TestAuth();
        using var session = NewSession(profile, provider);
        var rig = new Rig(profile, session);
        rig.Workflow.Connect();
        await rig.Workflow.WaitForQuiescenceAsync();
        FakeTunnelHandle handle = Assert.Single(rig.Tunnels.Handles);
        string? password = rig.Workflow.Password;
        int recordedCalls = rig.Recorder.Calls.Count;

        provider.Silent = _ => Task.FromException<AwsCredentials>(new SignInRequiredException());
        var lateLogin = Completion<AwsCredentials>();
        provider.Interactive = _ => lateLogin.Task;
        int operationAttempts = 0;
        Task required = UntilStatus(session, AuthorizationStatus.SignInRequired);
        Task<int> operation = session.ExecuteAsync<int>(profile, _ =>
        {
            if (++operationAttempts == 1) { throw new ExpiredCredentialsException(); }
            return Task.FromResult(operationAttempts);
        });
        await required;
        Task<AwsCredentials> login = session.SignInAsync();
        await provider.InteractiveStarted.Task;

        ConnectionProfile selected = profile with { InstanceTagValue = "next-target", ResourceRegion = "us-east-1" };
        var settings = AppSettings.Default with { AutoReconnect = false, ClipboardAutoClearSeconds = 60 };
        rig.Workflow.Apply(selected, settings);
        if (reselectOriginal)
        {
            rig.Workflow.Apply(profile, settings);
            selected = profile;
        }
        lateLogin.SetResult(Credentials("stale"));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => operation);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => login);
        await rig.Workflow.WaitForQuiescenceAsync();

        Assert.Equal(ConnectionState.Connected, rig.Workflow.State);
        Assert.Equal(profile, rig.Workflow.Profile);
        Assert.Equal(selected, rig.Workflow.SelectedProfile);
        Assert.Equal(settings, rig.Workflow.Settings);
        Assert.True(rig.Workflow.TunnelActive);
        Assert.Same(handle, Assert.Single(rig.Tunnels.Handles));
        Assert.False(handle.Terminated);
        Assert.Equal(password, rig.Workflow.Password);
        Assert.Equal(recordedCalls, rig.Recorder.Calls.Count);
        Assert.Equal(1, operationAttempts);

        provider.Interactive = _ => Task.FromResult(Credentials("new-selection"));
        await session.SignInAsync();
        Assert.Equal(1, operationAttempts);
        Assert.False(handle.Terminated);
        Assert.Equal(recordedCalls, rig.Recorder.Calls.Count);
        if (!reselectOriginal)
        {
            await Assert.ThrowsAnyAsync<OperationCanceledException>(() => session.AuthenticateAsync(profile, default));
        }
        await rig.Workflow.ShutdownAsync();
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public async Task StagedSelectionIsAdoptedOnlyAfterExplicitDisconnectOrReconnect(bool reconnect)
    {
        var profile = Profile();
        var rig = new Rig(profile);
        rig.Workflow.Connect();
        await rig.Workflow.WaitForQuiescenceAsync();
        FakeTunnelHandle original = Assert.Single(rig.Tunnels.Handles);
        ConnectionProfile selected = profile with { InstanceTagValue = "next-target", ResourceRegion = "us-east-1" };
        rig.Workflow.Apply(selected, AppSettings.Default);
        await rig.Workflow.WaitForQuiescenceAsync();
        Assert.False(original.Terminated);
        Assert.Equal(profile, rig.Workflow.Profile);

        if (reconnect)
        {
            rig.Workflow.Reconnect();
        }
        else
        {
            rig.Workflow.Disconnect();
            await rig.Workflow.WaitForQuiescenceAsync();
            Assert.Equal(ConnectionState.Disconnected, rig.Workflow.State);
            Assert.Equal(selected, rig.Workflow.Profile);
            rig.Workflow.Connect();
        }
        await rig.Workflow.WaitForQuiescenceAsync();

        Assert.True(original.Terminated);
        Assert.Equal(ConnectionState.Connected, rig.Workflow.State);
        Assert.Equal(selected, rig.Workflow.Profile);
        Assert.Equal(selected, rig.Workflow.SelectedProfile);
        Assert.Equal(2, rig.Tunnels.Handles.Count);
        Assert.False(rig.Tunnels.Handles[1].Terminated);
        RecordedCall resolve = rig.Recorder.Calls.Last(call => call.Port == "EC2Provider" && call.Method == "resolveInstance");
        Assert.Equal("next-target", resolve.Arguments["tagValue"]);
        Assert.Equal("us-east-1", resolve.Arguments["region"]);
        RecordedCall cleanup = rig.Recorder.Calls.First(call => call.Port == "SSMProvider" && call.Method == "terminateSession");
        Assert.Equal(profile.ResourceRegion, cleanup.Arguments["region"]);
        await rig.Workflow.ShutdownAsync();
    }

    [Fact]
    public async Task SettingsOnlyApplyKeepsHealthyTransportAndAuthorization()
    {
        var profile = Profile();
        var provider = new TestAuth();
        using var session = NewSession(profile, provider);
        var rig = new Rig(profile, session);
        rig.Workflow.Connect();
        await rig.Workflow.WaitForQuiescenceAsync();
        FakeTunnelHandle handle = Assert.Single(rig.Tunnels.Handles);
        var settings = AppSettings.Default with { AutoReconnect = false };
        rig.Workflow.Apply(profile, settings);
        await rig.Workflow.WaitForQuiescenceAsync();
        Assert.Equal(settings, rig.Workflow.Settings);
        Assert.Equal(AuthorizationStatus.Ready, session.Status);
        Assert.Equal(ConnectionState.Connected, rig.Workflow.State);
        Assert.False(handle.Terminated);
        Assert.Equal(1, provider.SilentCalls);
        await rig.Workflow.ShutdownAsync();
    }

    [Fact]
    public async Task WakeRecoveryCannotAutomaticallyAdoptStagedSelection()
    {
        var profile = Profile();
        var rig = new Rig(profile, readyAfterWake: false);
        rig.Workflow.Connect();
        await rig.Workflow.WaitForQuiescenceAsync();
        FakeTunnelHandle handle = Assert.Single(rig.Tunnels.Handles);
        rig.Workflow.Apply(profile with { InstanceTagValue = "next-target" }, AppSettings.Default);
        await rig.Workflow.HandleSystemWakeAsync();
        await rig.Workflow.WaitForQuiescenceAsync();
        Assert.Equal(profile, rig.Workflow.Profile);
        Assert.Equal(ConnectionState.Connected, rig.Workflow.State);
        Assert.True(rig.Workflow.TunnelActive);
        Assert.False(handle.Terminated);
        Assert.NotNull(rig.Workflow.WarningMessage);
        Assert.Equal(1, rig.Recorder.CountOf("EC2Provider", "resolveInstance"));
        Assert.Equal(0, rig.Recorder.CountOf("SSMProvider", "terminateSession"));
        await rig.Workflow.ShutdownAsync();
    }

    [Fact] // AUTH-04
    public async Task WorkflowReplaysRejectedAwsOperationOnceWithFreshCredentials()
    {
        var profile = Profile();
        var provider = new TestAuth();
        using var session = NewSession(profile, provider);
        var rig = new Rig(profile, session, resolveRejectedOnce: true);
        rig.Workflow.Connect();
        await rig.Workflow.WaitForQuiescenceAsync();
        Assert.Equal(ConnectionState.Connected, rig.Workflow.State);
        Assert.Equal(2, rig.Recorder.CountOf("EC2Provider", "resolveInstance"));
        Assert.Equal(2, provider.SilentCalls);
        Assert.Equal(0, provider.InteractiveCalls);
        await rig.Workflow.ShutdownAsync();
    }

    [Fact]
    public async Task TunnelOnlyWakeChecksListenerNotDcv()
    {
        var rig = new Rig(Profile() with { ConnectAction = ConnectAction.TunnelOnly });
        rig.Workflow.Connect();
        await rig.Workflow.WaitForQuiescenceAsync();
        await rig.Workflow.HandleSystemWakeAsync();
        Assert.Equal(2, rig.Recorder.CountOf("ReadinessProbe", "isListening"));
        Assert.Equal(0, rig.Recorder.CountOf("ReadinessProbe", "waitUntilReady"));
        await rig.Workflow.ShutdownAsync();
    }

    private sealed class Rig
    {
        public PortRecorder Recorder { get; }
        public FakeTunnelProvider Tunnels { get; }
        public ConnectionWorkflow Workflow { get; }
        public Rig(ConnectionProfile profile, IAuthProvider? auth = null, bool listening = true,
            bool resolveRejectedOnce = false, bool readyAfterWake = true)
        {
            var given = new Given();
            given.Ports["ReadinessProbe"] = new()
            {
                ["isListening"] = [new Outcome { Result = JsonSerializer.SerializeToElement(listening) }],
                ["waitUntilReady"] =
                [
                    new Outcome { Result = JsonSerializer.SerializeToElement(true) },
                    new Outcome { Result = JsonSerializer.SerializeToElement(readyAfterWake) },
                ],
            };
            if (resolveRejectedOnce)
            {
                given.Ports["EC2Provider"] = new()
                {
                    ["resolveInstance"] =
                    [
                        new Outcome { Error = new OutcomeError { Kind = "expiredCredentials" } },
                        new Outcome { Result = JsonSerializer.SerializeToElement(new { id = "i-target", state = "running" }) },
                    ],
                };
            }
            Recorder = new(given);
            Tunnels = new(Recorder);
            Workflow = new(
                auth ?? new FakeAuthProvider(Recorder), new FakeEc2Provider(Recorder), new FakeSsmProvider(Recorder),
                new FakeSecretsProvider(Recorder), new FakeIdentityProvider(Recorder), new FakeAgentClient(Recorder),
                Tunnels, new FakeReadinessProbe(Recorder), new FakeDcvLauncher(Recorder, true),
                new FakeInstanceIdStore(Recorder, null), new InstantDelay(), new Sink(), profile, AppSettings.Default,
                ConnectionTimeouts.Default with { EstablishRetryAttempts = 0 });
        }
    }
    private sealed class Sink : IEventSink
    {
        public ConcurrentQueue<string> Logs { get; } = new();
        public void StateChanged(ConnectionState state) { }
        public void Log(string category, string message) => Logs.Enqueue(message);
        public void Notify(ConnectionNotification notification) { }
        public void PasswordAvailable(string password) { }
    }
}
