using System.IO;
using System.Diagnostics;
using System.IO.Pipes;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Microsoft.Extensions.Time.Testing;
using SSMConnect.App.Helper;
using Xunit;

namespace SSMConnect.App.Tests;

/// <summary>
/// The Windows shell's helper host (T18, AC-18, AC-27, AC-21): a job object per helper, terminate
/// and wait empty before a replacement, one automatic restart, the handshake, heartbeat and cancel
/// limits with the re-arm, "core unavailable" with Retry, single instance, user apps outside the
/// job, and the "updated; restart it" message on a build mismatch.
/// </summary>
public sealed class HelperHostTests
{
    const string Build = "build-1";
    static readonly HelperHostLimits Limits = new(
        Handshake: TimeSpan.FromSeconds(10), Heartbeat: TimeSpan.FromSeconds(15),
        CancelConfirmation: TimeSpan.FromSeconds(10), HealthyRearm: TimeSpan.FromMinutes(10));

    /// <summary>An in-process helper that speaks the protocol over anonymous pipes.</summary>
    internal sealed class FakeHelper : IHelperConnection
    {
        readonly AnonymousPipeServerStream toHelper = new(PipeDirection.Out);
        readonly AnonymousPipeClientStream helperIn;
        readonly AnonymousPipeServerStream fromHelper = new(PipeDirection.In);
        readonly AnonymousPipeClientStream helperOut;
        readonly TaskCompletionSource exited = new(TaskCreationOptions.RunContinuationsAsynchronously);
        public readonly List<JsonObject> Received = [];
        public string HelperBuild = Build;
        public bool Handshakes = true;
        public bool AnswersHeartbeats = true;
        public bool ConfirmsCancel = true;
        public Func<string, JsonObject?> OnCommand = _ => null; // null: never answers

        public FakeHelper()
        {
            helperIn = new AnonymousPipeClientStream(PipeDirection.In, toHelper.ClientSafePipeHandle);
            helperOut = new AnonymousPipeClientStream(PipeDirection.Out, fromHelper.ClientSafePipeHandle);
            _ = Task.Run(Serve);
        }

        public Stream Input => toHelper;
        public Stream Output => fromHelper;
        public Task Exited => exited.Task;

        int sequence;

        /// <summary>Sends an event frame to the shell, as the helper does, with the next sequence number.</summary>
        public void Emit(string workflow, string name, Dictionary<string, string> fields) =>
            Send(new { type = "event", sequence = Interlocked.Increment(ref sequence), workflow, name, fields });

        /// <summary>Sends a command's terminal result, for a command the helper did not answer at once.</summary>
        public void Respond(string id, string outcome) => Send(new { type = "result", id, outcome, value = new { } });

        public void Exit()
        {
            try { helperOut.Dispose(); } catch { }
            exited.TrySetResult();
        }

        void Send(object frame)
        {
            var line = JsonSerializer.Serialize(frame) + "\n";
            var bytes = Encoding.UTF8.GetBytes(line);
            try { lock (helperOut) { helperOut.Write(bytes); helperOut.Flush(); } } catch { }
        }

        async Task Serve()
        {
            using var reader = new StreamReader(helperIn, Encoding.UTF8);
            string? line;
            while ((line = await reader.ReadLineAsync()) is not null)
            {
                var frame = JsonNode.Parse(line)!.AsObject();
                lock (Received) Received.Add(frame);
                switch ((string)frame["type"]!)
                {
                    case "hello":
                        if (!Handshakes) break;
                        if ((string)frame["build"]! == HelperBuild) Send(new { type = "welcome", build = HelperBuild });
                        else
                        {
                            Send(new { type = "refused", reason = "differentBuild", detail = $"helper {HelperBuild}, shell {frame["build"]}" });
                            Exit();
                        }
                        break;
                    case "heartbeat":
                        if (AnswersHeartbeats) Send(new { type = "heartbeat", sequence = (int)frame["sequence"]! });
                        break;
                    case "command":
                        var id = (string)frame["id"]!;
                        Send(new { type = "accepted", id });
                        if (OnCommand((string)frame["name"]!) is { } result) { result["id"] = id; Send(result); }
                        break;
                    case "cancel":
                        if (ConfirmsCancel) Send(new { type = "result", id = (string)frame["id"]!, outcome = "cancelled" });
                        break;
                    case "shutdown":
                        Exit();
                        return;
                }
            }
            exited.TrySetResult();
        }

        public ValueTask DisposeAsync() { Exit(); return ValueTask.CompletedTask; }
    }

    /// <summary>Starts fake helpers and records container operations in order.</summary>
    internal sealed class FakeSpawner(Func<FakeHelper> make) : IHelperSpawner
    {
        public readonly List<string> Log = [];
        public readonly List<FakeHelper> Started = [];

        public Task<IHelperConnection> StartAsync(CancellationToken cancellationToken)
        {
            var helper = make();
            lock (Log) { Started.Add(helper); Log.Add($"start {Started.Count}"); }
            return Task.FromResult<IHelperConnection>(helper);
        }

        public async Task TerminateAndWaitEmptyAsync(IHelperConnection connection, CancellationToken cancellationToken)
        {
            lock (Log) Log.Add($"terminate {Started.IndexOf((FakeHelper)connection) + 1}");
            ((FakeHelper)connection).Exit();
            await connection.Exited;
            lock (Log) Log.Add($"empty {Started.IndexOf((FakeHelper)connection) + 1}");
        }
    }

    static async Task Eventually(Func<bool> condition, FakeTimeProvider? time = null, TimeSpan? step = null)
    {
        var deadline = DateTime.UtcNow.AddSeconds(10);
        while (!condition())
        {
            if (DateTime.UtcNow > deadline) throw new TimeoutException("condition not reached");
            if (time is not null && step is not null) time.Advance(step.Value);
            await Task.Delay(10, TestContext.Current.CancellationToken);
        }
    }

    static HelperHost Host(FakeSpawner spawner, FakeTimeProvider time) => new(spawner, Build, Limits, time);

    [Fact]
    public async Task HandshakeCompletesAndCommandsGetOneTerminalResult()
    {
        var time = new FakeTimeProvider();
        var spawner = new FakeSpawner(() => new FakeHelper { OnCommand = _ => new JsonObject { ["type"] = "result", ["outcome"] = "completed", ["value"] = new JsonObject { ["state"] = "connected" } } });
        var host = Host(spawner, time);
        await host.StartAsync();
        Assert.Equal(HelperHostStatus.Ready, host.Status);
        var result = await host.SendAsync("connect", new Dictionary<string, string>(), TestContext.Current.CancellationToken);
        Assert.Equal(HelperOutcome.Completed, result.Outcome);
        Assert.Equal("connected", result.Value["state"]);
        var hello = spawner.Started[0].Received.First();
        Assert.Equal("hello", (string)hello["type"]!);
        Assert.Equal(Build, (string)hello["build"]!);
    }

    [Fact]
    public async Task ShutdownAsksTheHelperToEndThenEmptiesItsJobAndStartsNoReplacement()
    {
        var time = new FakeTimeProvider();
        var spawner = new FakeSpawner(() => new FakeHelper());
        var host = Host(spawner, time);
        await host.StartAsync();
        await host.ShutdownAsync(TimeSpan.FromSeconds(5));
        Assert.Contains(spawner.Started[0].Received, frame => (string)frame["type"]! == "shutdown");
        Assert.Equal(HelperHostStatus.Stopped, host.Status);
        await host.RetryAsync();
        await Task.Delay(100, TestContext.Current.CancellationToken);
        Assert.Equal(["start 1", "terminate 1", "empty 1"], spawner.Log);
    }

    [Fact]
    public async Task ABuildMismatchShowsTheUpdatedMessageAndStartsNoReplacement()
    {
        var time = new FakeTimeProvider();
        var spawner = new FakeSpawner(() => new FakeHelper { HelperBuild = "build-2" });
        var host = Host(spawner, time);
        await host.StartAsync();
        Assert.Equal(HelperHostStatus.Updated, host.Status);
        Assert.Equal("SSM Connect was updated; restart it.", host.StatusMessage);
        await Task.Delay(100, TestContext.Current.CancellationToken);
        Assert.Single(spawner.Started);
    }

    [Fact]
    public async Task AFirstHelperThatNeverHandshakesLeadsToUnavailableWithoutARestart()
    {
        var time = new FakeTimeProvider();
        var spawner = new FakeSpawner(() => new FakeHelper { Handshakes = false });
        var host = Host(spawner, time);
        var start = host.StartAsync();
        await Eventually(() => spawner.Started.Count == 1 && spawner.Started[0].Received.Count > 0);
        time.Advance(TimeSpan.FromSeconds(11));
        await start;
        Assert.Equal(HelperHostStatus.Unavailable, host.Status);
        Assert.Equal("SSM Connect core unavailable", host.StatusMessage);
        Assert.Single(spawner.Started);
        Assert.Equal(["start 1", "terminate 1", "empty 1"], spawner.Log);
    }

    [Fact]
    public async Task OneAutomaticRestartTerminatesAndEmptiesTheOldJobFirstThenRetryStartsAnother()
    {
        var time = new FakeTimeProvider();
        var spawner = new FakeSpawner(() => new FakeHelper());
        var host = Host(spawner, time);
        await host.StartAsync();
        spawner.Started[0].Exit();
        await Eventually(() => spawner.Started.Count == 2 && host.Status == HelperHostStatus.Ready);
        Assert.Equal(["start 1", "terminate 1", "empty 1", "start 2"], spawner.Log);
        spawner.Started[1].Exit();
        await Eventually(() => host.Status == HelperHostStatus.Unavailable);
        Assert.Equal(2, spawner.Started.Count);
        Assert.Equal("SSM Connect core unavailable", host.StatusMessage);
        await host.RetryAsync();
        Assert.Equal(HelperHostStatus.Ready, host.Status);
        Assert.Equal(3, spawner.Started.Count);
    }

    [Fact]
    public async Task AStoppedHelperClearsTheWorkflowStatesTheShellShows()
    {
        var spawner = new FakeSpawner(() => new FakeHelper());
        var host = Host(spawner, new FakeTimeProvider());
        await host.StartAsync();
        var controller = new SSMConnect.App.Shell.ShellController(host, new SilentPlatform());
        var changes = 0;
        controller.StateChanged += () => Interlocked.Increment(ref changes);
        spawner.Started[0].Emit("desktop", "state", new() { ["state"] = "tunneling" });
        await Eventually(() => controller.States.GetValueOrDefault("desktop") == "tunneling");
        var before = changes;
        spawner.Started[0].Exit();
        await Eventually(() => spawner.Started.Count == 2 && host.Status == HelperHostStatus.Ready);
        // The replacement helper holds no connection, so nothing the old one reported is shown.
        Assert.Empty(controller.States);
        Assert.True(changes > before);
    }

    [Fact]
    public async Task SignInRequiredNotifiesOnceAndNamesTheMenuItem()
    {
        var spawner = new FakeSpawner(() => new FakeHelper());
        var host = Host(spawner, new FakeTimeProvider());
        await host.StartAsync();
        var platform = new NotifyingPlatform();
        var controller = new SSMConnect.App.Shell.ShellController(host, platform);
        var helper = spawner.Started[0];
        helper.Emit("authorization", "state", new() { ["state"] = "refreshing" });
        helper.Emit("authorization", "state", new() { ["state"] = "signInRequired" });
        helper.Emit("authorization", "state", new() { ["state"] = "signInRequired" });
        await Eventually(() => controller.States.GetValueOrDefault("authorization") == "signInRequired");
        helper.Emit("authorization", "state", new() { ["state"] = "ready" });
        await Eventually(() => controller.States.GetValueOrDefault("authorization") == "ready");
        lock (platform.Notifications)
        {
            var notification = Assert.Single(platform.Notifications);
            Assert.Equal("Sign in required", notification.Title);
            Assert.Contains("Sign In with SSO", notification.Body);
        }
    }

    static JsonObject Failed(string code, string message) =>
        new() { ["type"] = "result", ["outcome"] = "failed", ["error"] = new JsonObject { ["code"] = code, ["message"] = message } };
    static JsonObject Done() => new() { ["type"] = "result", ["outcome"] = "completed", ["value"] = new JsonObject() };

    [Fact]
    public async Task SavingAnAttachedFileAsksForConsentAndOffersTheFilesVersionOnAConflict()
    {
        var saves = 0;
        var spawner = new FakeSpawner(() => new FakeHelper
        {
            OnCommand = name => name switch
            {
                "saveProfile" => ++saves switch
                {
                    1 => Failed("formattingConsentRequired", "Saving this attached file uses canonical formatting."),
                    2 => Done(),
                    _ => Failed("fileConflict", "The profile file changed since it was loaded."),
                },
                _ => Done(),
            },
        });
        var host = Host(spawner, new FakeTimeProvider());
        await host.StartAsync();
        var platform = new NotifyingPlatform { ConfirmAnswer = true };
        var controller = new SSMConnect.App.Shell.ShellController(host, platform);
        const string profile = """{"id":"55555555-5555-4555-8555-555555555555","name":"Workstation"}""";

        var first = await controller.SaveProfileAsync(profile);
        Assert.Equal(HelperOutcome.Completed, first.Outcome);
        var conflict = await controller.SaveProfileAsync(profile);
        Assert.Equal(HelperOutcome.Completed, conflict.Outcome);

        List<JsonObject> frames;
        lock (spawner.Started[0].Received) frames = spawner.Started[0].Received.Where(f => (string?)f["type"] == "command").ToList();
        Assert.Equal(["saveProfile", "saveProfile", "saveProfile", "applyFileChanges"], frames.Select(f => (string)f["name"]!));
        Assert.Null(frames[0]["arguments"]?["acceptFormatting"]);
        Assert.Equal("true", (string?)frames[1]["arguments"]?["acceptFormatting"]);
        Assert.Equal("55555555-5555-4555-8555-555555555555", (string?)frames[3]["arguments"]?["id"]);
        Assert.Equal(2, platform.Confirmations.Count);
        Assert.Empty(platform.Errors);
    }

    sealed class NotifyingPlatform : SSMConnect.App.Shell.IShellPlatform
    {
        public readonly List<(string Title, string Body)> Notifications = [];
        public string? DcvViewerPath => null;
        public void OpenUrl(string url) { }
        public void Start(string path, IReadOnlyList<string> arguments) { }
        public void SetClipboard(string text) { }
        public void Notify(string title, string body) { lock (Notifications) Notifications.Add((title, body)); }
        public readonly List<string> Errors = [];
        public void ShowError(string action, string message) { lock (Errors) Errors.Add(message); }
        public bool ConfirmAnswer;
        public readonly List<string> Confirmations = [];
        public bool Confirm(string title, string message) { lock (Confirmations) Confirmations.Add(message); return ConfirmAnswer; }
    }

    sealed class SilentPlatform : SSMConnect.App.Shell.IShellPlatform
    {
        public string? DcvViewerPath => null;
        public void OpenUrl(string url) { }
        public void Start(string path, IReadOnlyList<string> arguments) { }
        public void SetClipboard(string text) { }
        public void Notify(string title, string body) { }
        public void ShowError(string action, string message) { }
        public bool Confirm(string title, string message) => false;
    }

    [Fact]
    public async Task TenHealthyMinutesReArmTheAutomaticRestart()
    {
        var time = new FakeTimeProvider();
        var spawner = new FakeSpawner(() => new FakeHelper());
        var host = Host(spawner, time);
        await host.StartAsync();
        spawner.Started[0].Exit();
        await Eventually(() => spawner.Started.Count == 2 && host.Status == HelperHostStatus.Ready);
        Assert.Equal(0, host.AutomaticRestartsAvailable);
        for (var i = 1; i <= 41; i++)
        {
            time.Advance(TimeSpan.FromSeconds(15));
            var expected = i;
            await Eventually(() => host.HeartbeatsAnswered >= expected);
        }
        await Eventually(() => host.AutomaticRestartsAvailable == 1);
        spawner.Started[1].Exit();
        await Eventually(() => spawner.Started.Count == 3 && host.Status == HelperHostStatus.Ready);
    }

    [Fact]
    public async Task AMissedHeartbeatCountsAsStopped()
    {
        var time = new FakeTimeProvider();
        var helpers = 0;
        var spawner = new FakeSpawner(() => new FakeHelper { AnswersHeartbeats = Interlocked.Increment(ref helpers) > 1 });
        var host = Host(spawner, time);
        await host.StartAsync();
        await Eventually(() => spawner.Started.Count == 2, time, TimeSpan.FromSeconds(5));
        Assert.StartsWith("start 1, terminate 1, empty 1, start 2", string.Join(", ", spawner.Log));
    }

    [Fact]
    public async Task AnInFlightCommandFailsWithCoreStoppedAndIsNeverResent()
    {
        var time = new FakeTimeProvider();
        var spawner = new FakeSpawner(() => new FakeHelper());
        var host = Host(spawner, time);
        await host.StartAsync();
        var pending = host.SendAsync("startSession", new Dictionary<string, string>(), TestContext.Current.CancellationToken);
        await Eventually(() => spawner.Started[0].Received.Any(f => (string)f["type"]! == "command"));
        spawner.Started[0].Exit();
        var result = await pending;
        Assert.Equal(HelperOutcome.CoreStopped, result.Outcome);
        Assert.Equal("core stopped", result.Message);
        await Eventually(() => spawner.Started.Count == 2 && host.Status == HelperHostStatus.Ready);
        Assert.DoesNotContain(spawner.Started[1].Received, f => (string)f["type"]! == "command");
    }

    [Fact]
    public async Task AConfirmedCancelEndsTheCommandAsCancelled()
    {
        var time = new FakeTimeProvider();
        var spawner = new FakeSpawner(() => new FakeHelper());
        var host = Host(spawner, time);
        await host.StartAsync();
        using var cancel = new CancellationTokenSource();
        var pending = host.SendAsync("signIn", new Dictionary<string, string>(), cancel.Token);
        await Eventually(() => spawner.Started[0].Received.Any(f => (string)f["type"]! == "command"));
        cancel.Cancel();
        Assert.Equal(HelperOutcome.Cancelled, (await pending).Outcome);
        Assert.Single(spawner.Started);
    }

    [Fact]
    public async Task ACancelNotConfirmedWithinTenSecondsReplacesTheHelper()
    {
        var time = new FakeTimeProvider();
        var helpers = 0;
        var spawner = new FakeSpawner(() => new FakeHelper { ConfirmsCancel = Interlocked.Increment(ref helpers) > 1 });
        var host = Host(spawner, time);
        await host.StartAsync();
        using var cancel = new CancellationTokenSource();
        var pending = host.SendAsync("signIn", new Dictionary<string, string>(), cancel.Token);
        await Eventually(() => spawner.Started[0].Received.Any(f => (string)f["type"]! == "command"));
        cancel.Cancel();
        await Eventually(() => spawner.Started[0].Received.Any(f => (string)f["type"]! == "cancel"));
        time.Advance(TimeSpan.FromSeconds(11));
        Assert.Equal(HelperOutcome.CoreStopped, (await pending).Outcome);
        await Eventually(() => spawner.Started.Count == 2);
    }

    [Fact]
    public async Task EachHelperRunsInItsOwnKillOnCloseJob()
    {
        using var job = new JobObject();
        var helper = Process.Start(new ProcessStartInfo(SystemExe("cmd.exe"), "/c ping -n 60 127.0.0.1") { CreateNoWindow = true, UseShellExecute = false })!;
        job.Assign(helper);
        var grandchild = Process.Start(new ProcessStartInfo(SystemExe("cmd.exe"), "/c ping -n 60 127.0.0.1") { CreateNoWindow = true, UseShellExecute = false })!;
        job.Assign(grandchild);
        Assert.True(job.Contains(helper) && job.Contains(grandchild));
        Assert.True(job.ActiveProcessCount >= 2); // cmd.exe's own ping child joins the job too
        await job.TerminateAndWaitEmptyAsync(TestContext.Current.CancellationToken);
        Assert.Equal(0, job.ActiveProcessCount);
        Assert.True(helper.HasExited && grandchild.HasExited);
    }

    [Fact]
    public void UserApplicationsStartOutsideTheHelpersJob()
    {
        using var job = new JobObject();
        using var app = UserApplications.Start(SystemExe("cmd.exe"), ["/c", "exit", "0"]);
        Assert.False(job.Contains(app));
        app.WaitForExit();
    }

    [Fact]
    public void ASecondLaunchSignalsTheFirstInstanceInsteadOfStarting()
    {
        var name = "SSMConnect-test-" + Guid.NewGuid();
        using var first = SingleInstance.TryAcquire(name);
        Assert.NotNull(first);
        var activated = new ManualResetEventSlim();
        first!.Activated += activated.Set;
        Assert.Null(SingleInstance.TryAcquire(name));
        Assert.True(activated.Wait(TimeSpan.FromSeconds(5), TestContext.Current.CancellationToken));
    }

    static string SystemExe(string name) => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), name);
}
