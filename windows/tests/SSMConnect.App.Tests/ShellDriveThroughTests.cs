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
        public void SetClipboard(string text) { lock (Calls) Calls.Add("clipboard " + text); }
        public void Reveal(string path) { lock (Calls) Calls.Add("reveal " + path); }
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
    public void TrayAndSettingsControlsReachTheHelper()
    {
        HelperHostTests.FakeHelper? helper = null;
        var platform = new RecordingPlatform();
        RunOnSta(async () =>
        {
            var spawner = new HelperHostTests.FakeSpawner(() => helper = new HelperHostTests.FakeHelper { OnCommand = Completed });
            var host = new HelperHost(spawner, "build-1", HelperHostLimits.Default, TimeProvider.System);
            await host.StartAsync();
            var controller = new ShellController(host, platform);
            helper!.Emit("details", "details", new() { ["profiles"] = "1", ["desktop.state"] = "disconnected" });
            await Eventually(() => controller.Details.GetValueOrDefault("desktop.state") == "disconnected");

            // The tray: its items are the macOS menu's controls, shown and enabled as macOS shows them.
            var aboutShown = false;
            controller.ShowAboutRequested += () => aboutShown = true;
            var menu = TrayMenu.Build(controller, () => { }, () => { }, () => { });
            MenuItem Item(string id) => menu.Items.OfType<MenuItem>().First(i => (string?)i.Tag == id);
            var connect = Item("menucontent-button-machine-actiontitle");
            Assert.True(connect.Visibility == Visibility.Visible && connect.IsEnabled);
            Assert.Equal("Connect", connect.Header);
            Assert.Equal(Visibility.Collapsed, Item("menucontent-button-disconnect").Visibility);
            connect.RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));
            await Eventually(() => Commands(helper!).Contains("connect"));
            Item("menucontent-button-show-log").RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));
            await Eventually(() => Commands(helper!).Contains("getLog"));
            Item("menucontent-button-about").RaiseEvent(new RoutedEventArgs(MenuItem.ClickEvent));
            await Eventually(() => aboutShown);

            // The settings window: select the profile, duplicate it, edit it, and change a setting.
            await controller.ReloadProfilesAsync();
            var settings = new SettingsWindow(controller, platform);
            var list = FindAll<ListBox>(settings).Single();
            list.SelectedIndex = 0;
            Button Button(string id) => FindAll<Button>(settings).Single(b => System.Windows.Automation.AutomationProperties.GetAutomationId(b) == id);
            Assert.False(Button("settings-button-delete-the-selected-profile").IsEnabled); // the last profile cannot be deleted, as on macOS
            var duplicate = Button("settings-button-duplicate-the-selected-profile");
            Assert.True(duplicate.IsEnabled);
            Invoke(duplicate);
            await Eventually(() => Commands(helper!).Contains("duplicateProfile"));
            JsonObject? edited = null;
            controller.EditProfileRequested += profile => edited = profile;
            Invoke(Button("settings-button-edit"));
            await Eventually(() => (string?)edited?["id"] == "55555555-5555-4555-8555-555555555555");
            var reconnect = FindAll<CheckBox>(settings).Single(c => System.Windows.Automation.AutomationProperties.GetAutomationId(c)
                                                                    == "settings-toggle-reconnect-automatically-if-the-tunnel-drops");
            ((IToggleProvider)new CheckBoxAutomationPeer(reconnect).GetPattern(PatternInterface.Toggle)!).Toggle();
            await Eventually(() => Commands(helper!).Contains("saveSettings"));
        });

        List<JsonObject> frames;
        lock (helper!.Received) frames = [.. helper.Received];
        Assert.Equal("55555555-5555-4555-8555-555555555555",
                     (string?)frames.Single(f => (string?)f["name"] == "duplicateProfile")["arguments"]?["id"]);
        Assert.True(frames.Single(f => (string?)f["name"] == "saveSettings")["arguments"]!.AsObject().ContainsKey("autoReconnect"));
        Assert.DoesNotContain(platform.Calls, c => c.StartsWith("error", StringComparison.Ordinal));
    }

    static void Invoke(Button button) => ((IInvokeProvider)new ButtonAutomationPeer(button).GetPattern(PatternInterface.Invoke)!).Invoke();

    [Fact]
    public void ADisconnectDuringConnectCancelsTheConnect()
    {
        // The helper refuses a second desktop command while Connect runs, so Disconnect then cancels
        // the Connect; the helper's cancel ends what the Connect started.
        HelperHostTests.FakeHelper? helper = null;
        var platform = new RecordingPlatform();
        HelperResult? connected = null;
        RunOnSta(async () =>
        {
            var spawner = new HelperHostTests.FakeSpawner(() => helper = new HelperHostTests.FakeHelper
            {
                OnCommand = name => name == "connect" ? null : Completed(name),
            });
            var host = new HelperHost(spawner, "build-1", HelperHostLimits.Default, TimeProvider.System);
            await host.StartAsync();
            var controller = new ShellController(host, platform);
            var connecting = controller.RunCommandAsync("connect");
            await Eventually(() => Commands(helper!).Contains("connect"));
            await controller.RunAsync(new ShellAction("Disconnect", "disconnect", new Dictionary<string, string>()));
            connected = await connecting;
            Assert.DoesNotContain("disconnect", Commands(helper!));

            // With no Connect running, Disconnect is the helper's disconnect command.
            await controller.RunAsync(new ShellAction("Disconnect", "disconnect", new Dictionary<string, string>()));
            Assert.Contains("disconnect", Commands(helper!));
        });

        Assert.Equal(HelperOutcome.Cancelled, connected!.Outcome);
        List<JsonObject> frames;
        lock (helper!.Received) frames = [.. helper.Received];
        var connectID = (string?)frames.Single(f => (string?)f["type"] == "command" && (string?)f["name"] == "connect")["id"];
        Assert.Equal([connectID], frames.Where(f => (string?)f["type"] == "cancel").Select(f => (string?)f["id"]));
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
            helper.Emit("shell", "launchApplication", new() { ["kind"] = "browser", ["path"] = @"C:\Chrome\chrome.exe", ["arguments"] = "--user-data-dir=C:\\P\u001F--proxy-pac-url=data:x" });
            helper.Emit("shell", "setClipboard", new() { ["text"] = "hunter2" });
            helper.Emit("shell", "notify", new() { ["title"] = "Connected to workstation", ["body"] = "b" });
            helper.Emit("shell", "reveal", new() { ["path"] = @"C:\Users\m\AppData\Local\SSM Connect\proxy.pac" });
            helper.Emit("desktop", "state", new() { ["state"] = "Connected" });
            await Eventually(() => platform.Calls.Count >= 7 && controller.States.ContainsKey("desktop"));
            Assert.Equal("Connected", controller.States["desktop"]);
        });
        Assert.Contains("open https://device.sso.eu-west-1.amazonaws.com/?user_code=ABCD", platform.Calls);
        Assert.Contains("start code.cmd --new-window --remote ssh-remote+alias", platform.Calls);
        Assert.Contains(@"start dcvviewer.exe C:\Temp\ssm-connect-1.dcv", platform.Calls);
        // The core builds the browser's command line; the shell only starts it.
        Assert.Contains(@"start chrome.exe --user-data-dir=C:\P --proxy-pac-url=data:x", platform.Calls);
        Assert.Contains("clipboard hunter2", platform.Calls);
        Assert.Contains("notify Connected to workstation", platform.Calls);
        Assert.Contains(@"reveal C:\Users\m\AppData\Local\SSM Connect\proxy.pac", platform.Calls);
    }

    static List<string> Commands(HelperHostTests.FakeHelper helper)
    {
        lock (helper.Received) return helper.Received.Where(f => (string?)f["type"] == "command").Select(f => (string)f["name"]!).ToList();
    }

    static IEnumerable<T> FindAll<T>(DependencyObject root) where T : DependencyObject
    {
        if (root is T match) yield return match;
        foreach (var child in LogicalTreeHelper.GetChildren(root).OfType<DependencyObject>())
            foreach (var found in FindAll<T>(child)) yield return found;
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

/// <summary>
/// The sign-in page and documentation are https; Open &lt;forward&gt; opens the forward's local page over
/// http on the loopback address. Nothing else is opened.
/// </summary>
public sealed class OpenUrlTests
{
    [Theory]
    [InlineData("https://device.sso.eu-west-1.amazonaws.com/?user_code=ABCD", true)]
    [InlineData("http://127.0.0.1:4466/", true)]
    [InlineData("http://localhost:8080/dashboard", true)]
    [InlineData("http://[::1]:4466/", true)]
    [InlineData("http://example.com/", false)]
    [InlineData("http://127.0.0.1.example.com/", false)]
    [InlineData("file:///C:/Windows/win.ini", false)]
    [InlineData("javascript:alert(1)", false)]
    public void TheShellOpensHttpsAndLocalForwardPagesOnly(string url, bool opens) => Assert.Equal(opens, WindowsShellPlatform.Opens(url));
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
