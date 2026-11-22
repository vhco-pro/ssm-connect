using System.IO;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Automation.Peers;
using System.Windows.Automation.Provider;
using System.Windows.Controls;
using SSMConnect.App.Helper;
using SSMConnect.App.Shell;
using Xunit;

namespace SSMConnect.App.Tests;

/// <summary>
/// A UI drive-through of the WPF shell (T20, AC-11, AC-14): every tray menu item and settings
/// button reaches the helper as its command, and the helper's requests reach Windows through the
/// shell (the sign-in page, VS Code, DCV Viewer, the clipboard and notifications).
/// </summary>
public sealed class ShellDriveThroughTests
{
    sealed class RecordingPlatform : IShellPlatform
    {
        public readonly List<string> Calls = [];
        public string? DcvViewerPath => @"C:\Program Files\NICE\DCV\Client\bin\dcvviewer.exe";
        public void OpenUrl(string url) { lock (Calls) Calls.Add("open " + url); }
        public void Start(string path, IReadOnlyList<string> arguments) { lock (Calls) Calls.Add($"start {Path.GetFileName(path)} {string.Join(' ', arguments)}"); }
        public void StartBrowser(string browser, string mode, string profile, int socksPort) { lock (Calls) Calls.Add($"browser {browser} {mode} {socksPort}"); }
        public void SetClipboard(string text) { lock (Calls) Calls.Add("clipboard " + text); }
        public void Notify(string title, string body) { lock (Calls) Calls.Add("notify " + title); }
        public void ShowError(string action, string message) { lock (Calls) Calls.Add($"error {action}: {message}"); }
        public bool Confirm(string title, string message) { lock (Calls) Calls.Add("confirm " + title); return false; }
    }

    static JsonObject Completed(string name) => name switch
    {
        "listProfiles" => new JsonObject { ["type"] = "result", ["outcome"] = "completed",
            ["value"] = new JsonObject { ["profiles"] = """[{"id":"55555555-5555-4555-8555-555555555555","name":"Workstation"}]""", ["active"] = "" } },
        _ => new JsonObject { ["type"] = "result", ["outcome"] = "completed", ["value"] = new JsonObject() },
    };

    static void RunOnSta(Func<Task> body)
    {
        Exception? failure = null;
        var thread = new Thread(() =>
        {
            var context = new System.Windows.Threading.DispatcherSynchronizationContext();
            SynchronizationContext.SetSynchronizationContext(context);
            var frame = new System.Windows.Threading.DispatcherFrame();
            _ = Task.Run(async () => { }).ContinueWith(_ => { }, TaskScheduler.Default);
            System.Windows.Threading.Dispatcher.CurrentDispatcher.InvokeAsync(async () =>
            {
                try { await body(); } catch (Exception error) { failure = error; } finally { frame.Continue = false; }
            });
            System.Windows.Threading.Dispatcher.PushFrame(frame);
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        Assert.True(thread.Join(TimeSpan.FromSeconds(60)), "the drive-through timed out");
        if (failure is not null) throw new Xunit.Sdk.XunitException(failure.ToString());
    }

    static async Task Eventually(Func<bool> condition)
    {
        var deadline = DateTime.UtcNow.AddSeconds(10);
        while (!condition())
        {
            if (DateTime.UtcNow > deadline) throw new TimeoutException("condition not reached");
            await Task.Delay(10);
        }
    }

    [Fact]
    public void EveryTrayAndSettingsActionReachesTheHelperAsItsCommand()
    {
        HelperHostTests.FakeHelper? helper = null;
        var platform = new RecordingPlatform();
        RunOnSta(async () =>
        {
            var spawner = new HelperHostTests.FakeSpawner(() => helper = new HelperHostTests.FakeHelper { OnCommand = Completed });
            var host = new HelperHost(spawner, "build-1", HelperHostLimits.Default, TimeProvider.System);
            await host.StartAsync();
            var controller = new ShellController(host, platform);

            // The tray menu: click every action item.
            var menu = TrayMenu.Build(controller, () => { }, () => { }, () => { });
            foreach (var item in menu.Items.OfType<MenuItem>().Where(i => i.Tag is string tag && ShellController.MenuActions.Any(a => a.Command == tag)))
                item.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));

            // The settings window: load profiles, select one, edit and save, use it, import a file, set up VS Code.
            var settings = new SettingsWindow(controller, () => @"C:\Profiles\workstation.ssmconnect");
            await settings.ReloadAsync();
            var list = FindAll<ListBox>(settings).Single();
            list.SelectedIndex = 0;
            // Each button's command reaches the helper before the next is pressed; saving reloads the
            // list and keeps the saved profile selected, so Use acts on it.
            foreach (var (name, command) in new[] { ("save", "saveProfile"), ("use", "setActiveProfile"),
                                                    ("import", "importProfile"), ("editorSetup", "installEditorSetup") })
            {
                var listed = Commands(helper!).Count(c => c == "listProfiles");
                var button = FindAll<Button>(settings).Single(b => b.Name == name);
                ((IInvokeProvider)new ButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke)!).Invoke();
                await Eventually(() => Commands(helper!).Contains(command));
                if (name is "save" or "import") await Eventually(() => Commands(helper!).Count(c => c == "listProfiles") > listed);
                await Task.Delay(50);
                if (name == "save") Assert.Equal("Workstation", (list.SelectedItem as SettingsWindow.ProfileRow)?.Name);
            }
            var menuCommands = ShellController.MenuActions.Select(a => a.Command).ToList();
            await Eventually(() => menuCommands.All(Commands(helper!).Contains));
        });

        var commands = Commands(helper!);
        foreach (var expected in new[] { "signIn", "connect", "disconnect", "stopWorkstation", "openEditor", "startWebForwards",
                                         "stopWebForwards", "openBrowser", "listProfiles", "saveProfile", "setActiveProfile",
                                         "importProfile", "installEditorSetup" })
            Assert.Contains(expected, commands);
        Assert.DoesNotContain(platform.Calls, c => c.StartsWith("error", StringComparison.Ordinal));
    }

    [Fact]
    public void HelperRequestsReachWindowsThroughTheShell()
    {
        HelperHostTests.FakeHelper? helper = null;
        var platform = new RecordingPlatform();
        RunOnSta(async () =>
        {
            var spawner = new HelperHostTests.FakeSpawner(() => helper = new HelperHostTests.FakeHelper());
            var host = new HelperHost(spawner, "build-1", HelperHostLimits.Default, TimeProvider.System);
            await host.StartAsync();
            var controller = new ShellController(host, platform);
            helper!.Emit("shell", "openURL", new() { ["url"] = "https://device.sso.eu-west-1.amazonaws.com/?user_code=ABCD" });
            helper.Emit("shell", "launchApplication", new() { ["kind"] = "vsCode", ["path"] = @"C:\VSCode\bin\code.cmd", ["arguments"] = "--new-window\u001F--remote\u001Fssh-remote+alias" });
            helper.Emit("shell", "launchApplication", new() { ["kind"] = "dcvViewer", ["file"] = @"C:\Temp\ssm-connect-1.dcv" });
            helper.Emit("shell", "setClipboard", new() { ["text"] = "hunter2" });
            helper.Emit("shell", "notify", new() { ["title"] = "Connected to workstation", ["body"] = "b" });
            helper.Emit("desktop", "state", new() { ["state"] = "Connected" });
            await Eventually(() => platform.Calls.Count >= 5 && controller.States.ContainsKey("desktop"));
            Assert.Equal("Connected", controller.States["desktop"]);
        });
        Assert.Contains("open https://device.sso.eu-west-1.amazonaws.com/?user_code=ABCD", platform.Calls);
        Assert.Contains("start code.cmd --new-window --remote ssh-remote+alias", platform.Calls);
        Assert.Contains(@"start dcvviewer.exe C:\Temp\ssm-connect-1.dcv", platform.Calls);
        Assert.Contains("clipboard hunter2", platform.Calls);
        Assert.Contains("notify Connected to workstation", platform.Calls);
    }

    static List<string> Commands(HelperHostTests.FakeHelper helper)
    {
        lock (helper.Received) return helper.Received.Where(f => (string?)f["type"] == "command").Select(f => (string)f["name"]!).ToList();
    }

    static IEnumerable<T> FindAll<T>(DependencyObject root) where T : DependencyObject
    {
        if (root is ContentControl { Content: DependencyObject content }) foreach (var found in FindAll<T>(content)) yield return found;
        if (root is Panel panel)
            foreach (var child in panel.Children.OfType<DependencyObject>())
            {
                if (child is T match) yield return match;
                foreach (var found in FindAll<T>(child)) yield return found;
            }
    }
}

/// <summary>Start at sign-in through the current user's Run key (T20).</summary>
public sealed class StartupRegistrationTests
{
    [Fact]
    public void StartingAtSignInIsAPerUserRunValue()
    {
        var key = @"Software\SSMConnectTests\Run-" + Guid.NewGuid();
        var startup = new StartupRegistration("SSM Connect", key);
        try
        {
            Assert.False(startup.IsEnabled);
            startup.SetEnabled(true, @"C:\Program Files\SSM Connect\SSMConnect.exe");
            Assert.True(startup.IsEnabled);
            using (var run = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(key))
                Assert.Equal("\"C:\\Program Files\\SSM Connect\\SSMConnect.exe\"", run?.GetValue("SSM Connect"));
            startup.SetEnabled(false, "");
            Assert.False(startup.IsEnabled);
        }
        finally { Microsoft.Win32.Registry.CurrentUser.DeleteSubKeyTree(@"Software\SSMConnectTests", throwOnMissingSubKey: false); }
    }
}

/// <summary>Restart Manager's close request reaches the shell (T21).</summary>
public sealed partial class SessionEndWindowTests
{
    [System.Runtime.InteropServices.LibraryImport("user32.dll", EntryPoint = "SendMessageW")]
    private static partial IntPtr SendMessage(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam);

    [System.Runtime.InteropServices.LibraryImport("user32.dll")]
    private static partial IntPtr GetAncestor(IntPtr hwnd, uint flags);

    [Fact]
    public void TheCloseRequestIsAgreedAndClosesTheShellOnceTheSessionEnds()
    {
        var closed = 0;
        Exception? failure = null;
        var thread = new Thread(() =>
        {
            try
            {
                using var window = new SessionEndWindow(() => closed++);
                // Top-level, so Restart Manager's broadcast reaches it: its root is itself.
                Assert.Equal(window.Handle, GetAncestor(window.Handle, 2));
                const int EndSessionCloseApp = 0x1;
                Assert.Equal(1, (int)SendMessage(window.Handle, 0x0011, IntPtr.Zero, EndSessionCloseApp));
                Assert.Equal(0, closed);
                SendMessage(window.Handle, 0x0016, IntPtr.Zero, EndSessionCloseApp); // session not ending
                Assert.Equal(0, closed);
                SendMessage(window.Handle, 0x0016, 1, EndSessionCloseApp);
                Assert.Equal(1, closed);
            }
            catch (Exception error) { failure = error; }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        thread.Join();
        if (failure is not null) throw failure;
    }
}

/// DCV Viewer's MSI installs under Program Files (x86); the shell finds it there or under Program Files.
public sealed class DcvViewerLocationTests
{
    [Fact]
    public void DcvViewerIsFoundUnderEitherProgramFilesFolder()
    {
        var root = Directory.CreateTempSubdirectory("ssm-dcv-").FullName;
        try
        {
            string x64 = Path.Combine(root, "PF"), x86 = Path.Combine(root, "PF86");
            Assert.Null(WindowsShellPlatform.FindDcvViewer([x64, x86]));
            var viewer = Path.Combine(x86, "NICE", "DCV", "Client", "bin", "dcvviewer.exe");
            Directory.CreateDirectory(Path.GetDirectoryName(viewer)!);
            File.WriteAllText(viewer, "");
            Assert.Equal(viewer, WindowsShellPlatform.FindDcvViewer([x64, x86]));
        }
        finally { Directory.Delete(root, recursive: true); }
    }
}

/// <summary>A second launch brings the open settings window forward instead of opening another.</summary>
public sealed class SingleWindowTests
{
    [Fact]
    public void ShowingAgainReusesTheOpenWindowAndAClosedOneIsReplaced()
    {
        Exception? failure = null;
        var thread = new Thread(() =>
        {
            try
            {
                var single = new SingleWindow<Window>();
                var created = 0;
                Window Create() { created++; return new Window { Width = 100, Height = 100, ShowActivated = false }; }
                var first = single.Show(Create);
                first.WindowState = WindowState.Minimized;
                var again = single.Show(Create);
                Assert.Same(first, again);
                Assert.Equal(1, created);
                Assert.Equal(WindowState.Normal, again.WindowState);
                first.Close();
                Assert.Null(single.Current);
                var replacement = single.Show(Create);
                Assert.NotSame(first, replacement);
                Assert.Equal(2, created);
                replacement.Close();
            }
            catch (Exception error) { failure = error; }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        thread.Join();
        if (failure is not null) throw failure;
    }
}
