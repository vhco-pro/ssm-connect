using System.Diagnostics;
using SSMConnect.Aws;
using SSMConnect.Domain;
using SSMConnect.Windows;
using SSMConnect.Workflow;

namespace SSMConnect.DevHarness;

/// <summary>
/// Drives the real workflow against real AWS and real Windows, before any UI exists.
/// </summary>
/// <remarks>
/// The specification requires one end-to-end connection from a development harness before the tray
/// shell is written, so that a UI bug and an adapter bug can never be confused for one another.
/// <para>
/// Nothing here prints credentials, tokens, presigned URLs, account IDs, or agent-returned
/// usernames. Point it at approved test infrastructure only.
/// </para>
/// </remarks>
internal static class Program
{
    private static async Task<int> Main(string[] args)
    {
        if (args.Length == 0)
        {
            Console.Error.WriteLine(
                "Usage:\n" +
                "  connect <profile.json> [--keep]   full connection, then disconnect and check residue\n" +
                "  preflight <profile.json>          resolve the workstation without opening a tunnel\n" +
                "  orphan-check <profile.json>       does a hard-killed client leave an SSM session open (AC-07)");
            return 2;
        }

        try
        {
            return args[0] switch
            {
                "connect" when args.Length >= 2 => await ConnectAsync(args[1], args.Contains("--keep")),
                "preflight" when args.Length >= 2 => await PreflightAsync(args[1]),
                "orphan-check" when args.Length >= 2 => await OrphanCheckAsync(args[1]),
                _ => Fail($"Unknown command '{string.Join(' ', args)}'."),
            };
        }
        catch (Exception error)
        {
            return Fail($"{error.GetType().Name}: {error.Message}");
        }
    }

    private static ConnectionProfile LoadProfile(string path) =>
        ProfilePortability.ImportProfile(File.ReadAllText(path));

    private static ConnectionWorkflow BuildWorkflow(ConnectionProfile profile, ConsoleSink sink) =>
        new(
            new SsoAuthProvider(OpenBrowser),
            new Ec2Adapter(),
            new SsmAdapter(),
            new SecretsAdapter(),
            new StsIdentityAdapter(),
            new WorkstationAgentClient(),
            new PluginTunnelProvider(),
            new LoopbackReadinessProbe(),
            new DcvViewerLauncher(),
            new FileInstanceIdStore(),
            new RealDelay(),
            sink,
            profile,
            AppSettings.Default with { AutoReconnect = false });

    private static async Task<int> PreflightAsync(string profilePath)
    {
        ConnectionProfile profile = LoadProfile(profilePath);
        Console.WriteLine($"Profile '{profile.Name}' imported; mode {profile.ResolvedConnectMode}, region {profile.ResourceRegion}.");

        var auth = new SsoAuthProvider(OpenBrowser);
        AwsCredentials credentials = await auth.AuthenticateAsync(profile, CancellationToken.None);
        Console.WriteLine("Authenticated (credentials held in memory only).");

        Ec2Instance instance = await new Ec2Adapter().ResolveInstanceAsync(
            profile.InstanceTagKey, profile.InstanceTagValue, profile.ResourceRegion, credentials,
            CancellationToken.None);
        Console.WriteLine($"Resolved workstation {instance.Id}, state {instance.State.Wire()}.");

        var launcher = new DcvViewerLauncher();
        Console.WriteLine($"DCV viewer installed: {launcher.IsViewerInstalled()}.");
        Console.WriteLine($"Session Manager plugin available: {new PluginTunnelProvider().IsPluginAvailable}.");
        Console.WriteLine("PASS: preflight resolved real infrastructure without opening a tunnel.");
        return 0;
    }

    private static async Task<int> ConnectAsync(string profilePath, bool keepOpen)
    {
        ConnectionProfile profile = LoadProfile(profilePath);
        var sink = new ConsoleSink();
        ConnectionWorkflow workflow = BuildWorkflow(profile, sink);

        Console.WriteLine($"Connecting to '{profile.Name}' ({profile.ResolvedConnectMode})…");
        workflow.Connect();
        await WaitForSettleAsync(workflow, TimeSpan.FromMinutes(8));

        Console.WriteLine($"\nStates: {string.Join(" -> ", sink.States)}");
        Console.WriteLine($"Terminal state: {workflow.State.Wire()}");
        if (workflow.WarningMessage is not null)
        {
            Console.WriteLine($"Warning: {workflow.WarningMessage}");
        }

        if (workflow.State != ConnectionState.Connected)
        {
            return Fail($"Did not reach connected: {workflow.ErrorMessage ?? "<no message>"} " +
                        $"[{workflow.ErrorCategory.Wire()}]");
        }

        Console.WriteLine($"Connected on 127.0.0.1:{workflow.LocalPort}, tunnel active: {workflow.TunnelActive}.");

        if (keepOpen)
        {
            Console.WriteLine("Holding the connection open (--keep). Press Enter to disconnect.");
            Console.ReadLine();
        }

        workflow.Disconnect();
        await WaitForSettleAsync(workflow, TimeSpan.FromMinutes(1));

        Console.WriteLine($"After disconnect: state {workflow.State.Wire()}, tunnel active {workflow.TunnelActive}.");

        int leftovers = CountPluginProcesses();
        Console.WriteLine($"session-manager-plugin processes still running: {leftovers}.");
        int files = CountConnectionFiles();
        Console.WriteLine($"Connection files left on disk: {files}.");

        if (workflow.State != ConnectionState.Disconnected || workflow.TunnelActive || files != 0)
        {
            return Fail("Residue check failed after disconnect.");
        }

        Console.WriteLine("PASS: real end-to-end connection, disconnect, and local cleanup.");
        return 0;
    }

    /// <summary>
    /// Answers the AC-07 question the specification leaves open: local Job Object containment is
    /// proven, but nothing has shown whether the AWS-side session closes when the client dies.
    /// Opens a real session, kills the owning process tree the way a crash would, then asks AWS.
    /// </summary>
    private static async Task<int> OrphanCheckAsync(string profilePath)
    {
        ConnectionProfile profile = LoadProfile(profilePath);
        var auth = new SsoAuthProvider(OpenBrowser);
        AwsCredentials credentials = await auth.AuthenticateAsync(profile, CancellationToken.None);

        Ec2Instance instance = await new Ec2Adapter().ResolveInstanceAsync(
            profile.InstanceTagKey, profile.InstanceTagValue, profile.ResourceRegion, credentials,
            CancellationToken.None);

        if (instance.State != Ec2InstanceState.Running)
        {
            return Fail($"Workstation is {instance.State.Wire()}; run this check against a running workstation.");
        }

        var ssm = new SsmAdapter();
        SsmSession session = await ssm.StartSessionAsync(
            instance.Id, profile.ResourceRegion, credentials, profile.LocalPort, profile.RemotePort,
            CancellationToken.None);
        Console.WriteLine("Opened an SSM session.");

        ITunnelHandle handle = await new PluginTunnelProvider().StartTunnelAsync(
            session, profile.ResourceRegion, instance.Id, profile.LocalPort, profile.RemotePort,
            CancellationToken.None);
        Console.WriteLine($"Plugin running as pid {handle.ProcessId}.");

        bool listening = await new LoopbackReadinessProbe()
            .WaitUntilReadyAsync(profile.LocalPort, TimeSpan.FromSeconds(20), TimeSpan.FromSeconds(1),
                CancellationToken.None);
        Console.WriteLine($"Tunnel listening: {listening}.");

        // Simulate a crash: terminate the plugin outright, with no graceful teardown and without
        // telling AWS anything.
        using (Process plugin = Process.GetProcessById(handle.ProcessId))
        {
            plugin.Kill(entireProcessTree: true);
            await plugin.WaitForExitAsync();
        }

        Console.WriteLine("Killed the plugin without any graceful shutdown.");
        await Task.Delay(TimeSpan.FromSeconds(10));

        string state = await SsmAdapter.DescribeSessionStateAsync(
            session.SessionId, profile.ResourceRegion, credentials);
        Console.WriteLine($"AWS reports the session as: {state}");

        if (!string.Equals(state, "Terminated", StringComparison.OrdinalIgnoreCase))
        {
            Console.WriteLine(
                "\nRESULT: the AWS-side session SURVIVES an abnormal client exit. The client must " +
                "reap its own sessions on next start; local containment is not sufficient (AC-07).");
            await SsmAdapter.TerminateSessionAsync(session.SessionId, profile.ResourceRegion, credentials);
            Console.WriteLine("Cleaned up the session left behind by this test.");
            return 0;
        }

        Console.WriteLine("\nRESULT: the AWS-side session closes on its own when the client dies.");
        return 0;
    }

    private static async Task WaitForSettleAsync(ConnectionWorkflow workflow, TimeSpan budget)
    {
        DateTimeOffset deadline = DateTimeOffset.UtcNow + budget;
        while (DateTimeOffset.UtcNow < deadline)
        {
            await workflow.WaitForQuiescenceAsync();
            await Task.Delay(250);
            if (!workflow.State.IsTransitioning())
            {
                await workflow.WaitForQuiescenceAsync();
                return;
            }
        }
    }

    private static int CountPluginProcesses() =>
        Process.GetProcessesByName("session-manager-plugin").Length;

    private static int CountConnectionFiles() =>
        Directory.Exists(DcvViewerLauncher.ConnectionFileDirectory)
            ? Directory.GetFiles(DcvViewerLauncher.ConnectionFileDirectory,
                $"{DcvConnectionFile.TempFilePrefix}*.{DcvConnectionFile.FileExtension}").Length
            : 0;

    private static void OpenBrowser(string uri)
    {
        Console.WriteLine("Opening the IAM Identity Center verification page in the default browser…");
        Process.Start(new ProcessStartInfo { FileName = uri, UseShellExecute = true })?.Dispose();
    }

    private static int Fail(string message)
    {
        Console.Error.WriteLine($"FAIL: {message}");
        return 1;
    }

    /// <summary>Prints what the shell would act on, without ever printing the password itself.</summary>
    private sealed class ConsoleSink : IEventSink
    {
        private readonly List<string> _states = [];

        internal IReadOnlyList<string> States => _states;

        public void StateChanged(ConnectionState state)
        {
            _states.Add(state.Wire());
            Console.WriteLine($"  [state] {state.Wire()}");
        }

        public void Log(string category, string message) => Console.WriteLine($"  [{category}] {message}");

        public void Notify(ConnectionNotification notification) =>
            Console.WriteLine($"  [notify] {NotificationNames.Wire(notification)}");

        public void PasswordAvailable(string password) =>
            Console.WriteLine($"  [notify] password available ({password.Length} characters, not shown)");
    }
}
