using System.IO;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using SSMConnect.App.Helper;
using SSMConnect.App.Shell;
using Xunit;

namespace SSMConnect.App.Tests;

/// <summary>
/// The Windows shell's macOS parity drive-through (T60, AC-29), driven by contracts/macos-parity.json:
/// every macOS control has its Windows control, sends its helper command after macOS's confirmation,
/// is offered and enabled when macOS offers and enables it, and a control that interrupts running
/// work cancels that command, following up once when the command finished first.
/// </summary>
public sealed class ParityTests
{
    sealed class RecordingPlatform : IShellPlatform
    {
        public readonly List<string> Calls = [];
        public bool Answer = true;
        public int Choice { get; set; }
        public string? DcvViewerPath => @"C:\Program Files\NICE\DCV\Client\bin\dcvviewer.exe";
        public void OpenUrl(string url) { lock (Calls) Calls.Add("open " + url); }
        public void Start(string path, IReadOnlyList<string> arguments) { lock (Calls) Calls.Add("start " + path); }
        public void SetClipboard(string text) { lock (Calls) Calls.Add("clipboard " + text); }
        public void Notify(string title, string body) { lock (Calls) Calls.Add("notify " + title); }
        public void ShowError(string action, string message) { lock (Calls) Calls.Add($"error {action}: {message}"); }
        public bool Confirm(string title, string message) { lock (Calls) Calls.Add("confirm " + title); return Answer; }
        public int Choose(string title, string message, IReadOnlyList<string> options) { lock (Calls) Calls.Add("choose " + title); return Answer ? Choice : -1; }
        public string? ChooseProfileFile() => @"C:\Profiles\workstation.json";
        public string? ChooseFolder(string title) => @"C:\Users\m\zen-profile";
        public string? ChooseSaveFile(string title) => @"C:\Users\m\export.yaml";
        public void Reveal(string path) { lock (Calls) Calls.Add("reveal " + path); }
    }

    sealed record Entry(string Id, string Surface, string? Command, IReadOnlyList<string> Commands, string? CancelWorkflow, string? Otherwise,
                        bool Confirmation, string ConfirmWhen, bool PartOf, string OfferedWhen, string EnabledWhen);

    static string InventoryPath()
    {
        for (var directory = new DirectoryInfo(AppContext.BaseDirectory); directory is not null; directory = directory.Parent)
        {
            var candidate = Path.Combine(directory.FullName, "contracts", "macos-parity.json");
            if (File.Exists(candidate)) return candidate;
        }
        throw new FileNotFoundException("contracts/macos-parity.json was not found above the test directory");
    }

    static List<Entry> Inventory() =>
        JsonNode.Parse(File.ReadAllText(InventoryPath()))!["entries"]!.AsArray().Select(node =>
        {
            var e = node!.AsObject();
            var helper = e["helper"]!.AsObject();
            return new Entry((string)e["id"]!, ((string)e["windows"]!).Split(':')[0], (string?)helper["command"],
                helper["commands"]?.AsArray().Select(c => (string)c!).ToList() ?? [], (string?)helper["cancel"]?["workflow"],
                (string?)helper["cancel"]?["otherwise"], e.ContainsKey("confirmation"), (string?)e["confirmation"]?["when"] ?? "",
                helper.ContainsKey("part_of"), (string?)e["offered_when"] ?? "", (string?)e["enabled_when"] ?? "");
        }).ToList();

    // The inventory's rule syntax, evaluated independently of the shell.
    static bool Truthy(string? value) => !string.IsNullOrEmpty(value) && value != "false" && value != "0";

    static bool Clause(string text, IReadOnlyDictionary<string, string> values)
    {
        var c = text.Trim();
        string Value(string key) => values.TryGetValue(key, out var v) ? v : "";
        if (c.StartsWith('!') && !c.Contains('=')) return !Truthy(Value(c[1..]));
        if (c.Contains("!=")) { var p = c.Split("!=", 2); return !p[1].Split('|').Contains(Value(p[0])); }
        if (c.Contains('>')) { var p = c.Split('>', 2); return int.TryParse(Value(p[0]), out var n) && n > int.Parse(p[1]); }
        if (c.Contains('=')) { var p = c.Split('=', 2); return p[1].Split('|').Contains(Value(p[0])); }
        return Truthy(Value(c));
    }

    static bool Rule(string text, IReadOnlyDictionary<string, string> values) =>
        string.IsNullOrWhiteSpace(text) || text.Split(" or ").Any(alternative => alternative.Split(" & ").All(part => Clause(part, values)));

    static List<(string Name, Dictionary<string, string> Values)> States()
    {
        var baseline = new Dictionary<string, string>
        {
            ["profiles"] = "2", ["authorization.status"] = "ready", ["desktop.state"] = "disconnected", ["desktop.maskedPassword"] = "",
            ["editor.enabled"] = "true", ["editor.active"] = "false", ["editor.state"] = "idle", ["editor.setupInstalled"] = "true",
            ["editor.replacement"] = "", ["web.enabled"] = "true", ["web.state"] = "Off", ["web.socks"] = "true", ["web.pac"] = "false",
            ["web.browserMode"] = "separate", ["web.openingBrowser"] = "false", ["web.pendingChanges"] = "false", ["web.replacement"] = "",
            ["selected"] = "true", ["selected.attached"] = "true", ["selected.pending"] = "false", ["item.active"] = "false",
            ["item.openPath"] = "/", ["item.attached"] = "true", ["item.browserMode"] = "existing",
        };
        var connecting = new Dictionary<string, string>(baseline) { ["desktop.state"] = "tunneling", ["authorization.status"] = "signInRequired" };
        var connected = new Dictionary<string, string>(baseline)
        {
            ["desktop.state"] = "connected", ["desktop.maskedPassword"] = "••••••", ["editor.active"] = "true", ["editor.state"] = "active",
            ["web.state"] = "On", ["web.pac"] = "true", ["selected.pending"] = "true", ["web.browserMode"] = "existing",
        };
        var recovering = new Dictionary<string, string>(connected)
        {
            ["editor.state"] = "recovering", ["editor.replacement"] = """{"id":"r1"}""", ["web.replacement"] = """{"id":"w1"}""",
            ["web.pendingChanges"] = "true", ["authorization.status"] = "unavailable", ["profiles"] = "0",
        };
        return [("disconnected", baseline), ("connecting", connecting), ("connected", connected), ("recovering", recovering)];
    }

    static JsonObject Done(string _) => new() { ["type"] = "result", ["outcome"] = "completed", ["value"] = new JsonObject() };

    static readonly Dictionary<string, string> Arguments = new()
    {
        ["id"] = "55555555-5555-4555-8555-555555555555", ["name"] = "Dashboard", ["path"] = @"C:\Profiles\workstation.json",
    };

    sealed class Rig
    {
        public HelperHostTests.FakeHelper Helper = null!;
        public readonly RecordingPlatform Platform = new();
        public ShellController Controller = null!;

        public static async Task<Rig> StartAsync(Func<string, JsonObject?>? onCommand = null)
        {
            var rig = new Rig();
            var spawner = new HelperHostTests.FakeSpawner(() => rig.Helper = new HelperHostTests.FakeHelper { OnCommand = onCommand ?? Done });
            var host = new HelperHost(spawner, "build-1", HelperHostLimits.Default, TimeProvider.System);
            await host.StartAsync();
            rig.Controller = new ShellController(host, rig.Platform);
            return rig;
        }

        public async Task DetailsAsync(Dictionary<string, string> values)
        {
            Helper.Emit("details", "details", values.Where(kv => !kv.Key.StartsWith("selected") && !kv.Key.StartsWith("item.")).ToDictionary());
            await Eventually(() => Controller.Details.TryGetValue("desktop.state", out var s) && s == values["desktop.state"]);
        }

        public List<string> CommandsAfter(int start)
        {
            lock (Helper.Received) return Helper.Received.Skip(start).Where(f => (string?)f["type"] == "command").Select(f => (string)f["name"]!).ToList();
        }

        public int Count { get { lock (Helper.Received) return Helper.Received.Count; } }
    }

    static async Task Eventually(Func<bool> condition, int seconds = 10)
    {
        var deadline = DateTime.UtcNow.AddSeconds(seconds);
        while (!condition())
        {
            if (DateTime.UtcNow > deadline) throw new TimeoutException("condition not reached");
            await Task.Delay(10);
        }
    }

    static void RunOnSta(Func<Task> body)
    {
        Exception? failure = null;
        var thread = new Thread(() =>
        {
            SynchronizationContext.SetSynchronizationContext(new System.Windows.Threading.DispatcherSynchronizationContext());
            var frame = new System.Windows.Threading.DispatcherFrame();
            System.Windows.Threading.Dispatcher.CurrentDispatcher.InvokeAsync(async () =>
            {
                try { await body(); } catch (Exception error) { failure = error; } finally { frame.Continue = false; }
            });
            System.Windows.Threading.Dispatcher.PushFrame(frame);
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        Assert.True(thread.Join(TimeSpan.FromMinutes(15)), "the parity drive-through timed out");
        if (failure is not null) throw new Xunit.Sdk.XunitException(failure.ToString());
    }

    static IEnumerable<DependencyObject> Tree(DependencyObject root)
    {
        yield return root;
        foreach (var child in LogicalTreeHelper.GetChildren(root).OfType<DependencyObject>())
            foreach (var found in Tree(child)) yield return found;
    }

    [Fact]
    public void EveryMacOSControlHasItsWindowsControl() => RunOnSta(async () =>
    {
        // Row controls exist once there are rows, as on macOS: a profile with Use, an importable
        // ~/.aws/config profile, and a draft with a proxy suffix, a local forward and every optional section.
        var rig = await Rig.StartAsync(name => name switch
        {
            "listProfiles" => new JsonObject { ["type"] = "result", ["outcome"] = "completed", ["value"] = new JsonObject
                { ["profiles"] = """[{"id":"55555555-5555-4555-8555-555555555555","name":"Workstation"}]""", ["active"] = "", ["files"] = "[]", ["settings"] = "{}" } },
            "listAWSConfigProfiles" => new JsonObject { ["type"] = "result", ["outcome"] = "completed", ["value"] = new JsonObject
                { ["profiles"] = """[{"name":"dev"}]""" } },
            _ => Done(name),
        });
        await rig.DetailsAsync(States()[0].Values);
        await rig.Controller.ReloadProfilesAsync();
        var menu = TrayMenu.Build(rig.Controller, () => { }, () => { }, () => { });
        var settings = new SettingsWindow(rig.Controller, rig.Platform);
        await rig.Controller.TriggerAsync("settings-menu-import-a-profile-from-aws-config");
        await Task.Delay(100);
        var draft = JsonNode.Parse("""
            {"name":"Workstation","connectMode":"multiUser","remoteDevelopment":{"enabled":true},
             "webForwards":{"enabled":true,"socksPort":1080,"browserMode":"existing","proxySuffixes":[".internal"],
                            "localForwards":[{"name":"Dashboard","localPort":8080,"remoteHost":"127.0.0.1","remotePort":80}]}}
            """)!.AsObject();
        var windows = new Window[] { settings, new ProfileEditorWindow(rig.Controller, draft, true),
                                     new LogWindow(rig.Controller, []), new AboutWindow(rig.Controller) };
        var automationIds = windows.SelectMany(Tree).Select(AutomationProperties.GetAutomationId).ToHashSet();
        foreach (var entry in Inventory().Where(e => !e.PartOf))
        {
            Assert.True(ShellController.Control(entry.Id) is not null, $"no Windows control {entry.Id}");
            if (entry.Surface == "Confirmation dialog") continue; // served by the platform's dialogs
            if (entry.Surface == "Tray menu")
                Assert.True(menu.Items.OfType<MenuItem>().Any(i => (string?)i.Tag == entry.Id), $"no tray item {entry.Id}");
            else
                Assert.True(automationIds.Contains(entry.Id), $"no window control {entry.Id}");
        }
        // About names the build the shell and helper share.
        Assert.Contains(Tree(windows[3]).OfType<TextBlock>(), t => t.Text == "Version " + HelperBuild.Current);
        foreach (var window in windows) window.Close();
    });

    [Fact]
    public void EveryCommandControlSendsItsCommandAfterMacOSConfirmation() => RunOnSta(async () =>
    {
        foreach (var entry in Inventory())
        {
            var expected = entry.Command ?? entry.Otherwise;
            if (expected is null && entry.Commands.Count == 0) continue;
            var state = States().FirstOrDefault(s => Rule(entry.OfferedWhen, s.Values) && Rule(entry.EnabledWhen, s.Values)).Values;
            Assert.True(state is not null, $"no state offers {entry.Id}");
            foreach (var answer in new[] { true, false })
            {
                var rig = await Rig.StartAsync();
                await rig.DetailsAsync(state);
                rig.Platform.Answer = answer;
                var start = rig.Count;
                _ = rig.Controller.TriggerAsync(entry.Id, Arguments, state);
                bool SentExpected(List<string> sent) => entry.Commands.Count == 0 ? sent.Contains(expected!) : entry.Commands.Any(sent.Contains);
                // A sent command is awaited; a declined one is given time to appear.
                if (answer) { try { await Eventually(() => SentExpected(rig.CommandsAfter(start)), 5); } catch (TimeoutException) { } }
                else await Task.Delay(300);
                var sent = rig.CommandsAfter(start);
                bool asked;
                lock (rig.Platform.Calls) asked = rig.Platform.Calls.Any(c => c.StartsWith("confirm ") || c.StartsWith("choose "));
                var sentExpected = SentExpected(sent);
                if (answer) Assert.True(sentExpected, $"{entry.Id} sent {string.Join(',', sent)}");
                if (entry.Confirmation && Rule(entry.ConfirmWhen, state))
                {
                    Assert.True(asked || !answer, $"{entry.Id} sent without macOS's confirmation");
                    if (!answer && asked) Assert.False(sentExpected, $"{entry.Id} sent after its confirmation was declined");
                }
            }
        }
    });

    [Fact]
    public void AvailabilityFollowsMacOS() => RunOnSta(async () =>
    {
        foreach (var (name, values) in States())
        {
            var rig = await Rig.StartAsync();
            await rig.DetailsAsync(values);
            foreach (var entry in Inventory().Where(e => !e.PartOf))
            {
                var offered = Rule(entry.OfferedWhen, values);
                var enabled = offered && Rule(entry.EnabledWhen, values);
                Assert.True(rig.Controller.IsOffered(entry.Id, values) == offered, $"{entry.Id} offered in {name}");
                Assert.True(rig.Controller.IsEnabled(entry.Id, values) == enabled, $"{entry.Id} enabled in {name}");
                if (!enabled && (entry.Command is not null || entry.Otherwise is not null || entry.Commands.Count > 0))
                {
                    var start = rig.Count;
                    _ = rig.Controller.TriggerAsync(entry.Id, Arguments, values);
                    await Task.Delay(20);
                    Assert.True(rig.CommandsAfter(start).Count == 0, $"{entry.Id} sent while unavailable in {name}");
                }
            }
        }
    });

    [Fact]
    public void CancelControlsCancelTheRunningCommandOfTheirWorkflow() => RunOnSta(async () =>
    {
        var running = new Dictionary<string, string> { ["desktop"] = "reconnect", ["editor"] = "reconnectWorkspace", ["web"] = "startWebForwards" };
        foreach (var entry in Inventory().Where(e => e.CancelWorkflow is not null))
        {
            var state = States().FirstOrDefault(s => Rule(entry.OfferedWhen, s.Values) && Rule(entry.EnabledWhen, s.Values)).Values;
            Assert.True(state is not null, $"no state offers {entry.Id}");
            var rig = await Rig.StartAsync(name => name is "reconnect" or "reconnectWorkspace" or "startWebForwards" ? null : Done(name));
            await rig.DetailsAsync(state);
            var work = rig.Controller.RunCommandAsync(running[entry.CancelWorkflow!]);
            await Task.Delay(50);
            Assert.False(work.IsCompleted);
            var start = rig.Count;
            _ = rig.Controller.TriggerAsync(entry.Id, Arguments, state);
            var result = await work.WaitAsync(TimeSpan.FromSeconds(10));
            Assert.Equal(HelperOutcome.Cancelled, result.Outcome);
            List<JsonObject> frames;
            lock (rig.Helper.Received) frames = rig.Helper.Received.Skip(start).ToList();
            Assert.Single(frames, f => (string?)f["type"] == "cancel");
            await Task.Delay(50);
            if (entry.Otherwise is "cancelEditorRecovery" or "cancelForwardingRecovery" or "disconnect")
                Assert.DoesNotContain(entry.Otherwise, rig.CommandsAfter(start));
        }
    });

    [Fact]
    public void ACancelThatArrivesAfterTheCommandFinishedIsFollowedOnce() => RunOnSta(async () =>
    {
        var rig = await Rig.StartAsync(name => name == "openEditor" ? null : Done(name));
        rig.Helper.ConfirmsCancel = false;
        var state = States()[3].Values; // a replacement waits for review
        await rig.DetailsAsync(state);
        var open = rig.Controller.RunCommandAsync("openEditor");
        await Eventually(() => rig.CommandsAfter(0).Contains("openEditor"));
        string openID;
        lock (rig.Helper.Received) openID = (string)rig.Helper.Received.Last(f => (string?)f["name"] == "openEditor")["id"]!;
        _ = rig.Controller.TriggerAsync("menucontent-button-cancel-replacement-recovery", null, state);
        await Eventually(() => { lock (rig.Helper.Received) return rig.Helper.Received.Any(f => (string?)f["type"] == "cancel"); });
        // The helper had already finished Open VS Code: its result arrives as completed.
        rig.Helper.Respond(openID, "completed");
        await open.WaitAsync(TimeSpan.FromSeconds(10));
        await Eventually(() => rig.CommandsAfter(0).Count(c => c == "cancelEditorRecovery") == 1);
        await Task.Delay(100);
        var commands = rig.CommandsAfter(0);
        Assert.Equal(1, commands.Count(c => c == "cancelEditorRecovery"));
        Assert.Equal(1, commands.Count(c => c == "openEditor"));
        Assert.DoesNotContain("connect", commands);
    });

}
