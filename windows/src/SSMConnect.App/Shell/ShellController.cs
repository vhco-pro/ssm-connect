using System.Diagnostics;
using System.IO;
using System.Text.Json.Nodes;
using SSMConnect.App.Helper;

namespace SSMConnect.App.Shell;

/// <summary>One shell action: its label, the helper command it sends and its arguments.</summary>
public sealed record ShellAction(string Label, string Command, IReadOnlyDictionary<string, string> Arguments);

/// <summary>
/// The Windows shell's behaviour without connection rules: every user action becomes one helper
/// command, and the helper's events drive the tray state and the requests only the shell can
/// serve (the sign-in page, VS Code, DCV Viewer, browsers, the clipboard and notifications).
/// Applications start from the shell's own process, outside the helper's job.
/// </summary>
public sealed class ShellController
{
    readonly HelperHost host;
    readonly IShellPlatform platform;
    readonly Dictionary<string, string> states = [];

    public ShellController(HelperHost host, IShellPlatform platform)
    {
        this.host = host;
        this.platform = platform;
        host.EventReceived += Handle;
        host.StatusChanged += ClearStatesWhenStopped;
    }

    /// <summary>
    /// A helper that stops takes its connections with it, and its replacement starts with none:
    /// what the stopped helper reported no longer describes anything.
    /// </summary>
    void ClearStatesWhenStopped()
    {
        if (host.Status == HelperHostStatus.Ready) return;
        lock (states)
        {
            if (states.Count == 0) return;
            states.Clear();
        }
        StateChanged?.Invoke();
    }

    /// <summary>Latest state per workflow (desktop, web, editor), from the helper's events.</summary>
    public IReadOnlyDictionary<string, string> States { get { lock (states) return new Dictionary<string, string>(states); } }

    /// <summary>Raised when a workflow's state changes.</summary>
    public event Action? StateChanged;

    static readonly IReadOnlyDictionary<string, string> Empty = new Dictionary<string, string>();

    /// <summary>The actions the tray menu offers, in order.</summary>
    public static IReadOnlyList<ShellAction> MenuActions { get; } =
    [
        new("Sign In with SSO", "signIn", Empty),
        new("Connect", "connect", Empty),
        new("Disconnect", "disconnect", Empty),
        new("Stop Workstation", "stopWorkstation", Empty),
        new("Open VS Code", "openEditor", Empty),
        new("Start Web Forwards", "startWebForwards", Empty),
        new("Stop Web Forwards", "stopWebForwards", Empty),
        new("Open Browser", "openBrowser", Empty),
    ];

    /// <summary>Sends an action's command and reports a failure to the user.</summary>
    public async Task<HelperResult> RunAsync(ShellAction action, CancellationToken cancellationToken = default)
    {
        var result = await host.SendAsync(action.Command, action.Arguments, cancellationToken);
        if (result.Outcome is HelperOutcome.Failed or HelperOutcome.Rejected or HelperOutcome.CoreStopped)
            platform.ShowError(action.Label, result.Message ?? HelperHost.UnavailableMessage);
        return result;
    }

    public Task<HelperResult> SaveProfileAsync(string profileJson) =>
        RunAsync(new("Save Profile", "saveProfile", new Dictionary<string, string> { ["profile"] = profileJson }));

    public Task<HelperResult> SetActiveProfileAsync(string id) =>
        RunAsync(new("Use Profile", "setActiveProfile", new Dictionary<string, string> { ["id"] = id }));

    public Task<HelperResult> ImportProfileAsync(string path, bool attach) =>
        RunAsync(new("Import Profile", "importProfile", new Dictionary<string, string> { ["path"] = path, ["attach"] = attach ? "true" : "false" }));

    public Task<HelperResult> ListProfilesAsync() => RunAsync(new("Profiles", "listProfiles", Empty));

    public Task<HelperResult> InstallEditorSetupAsync() =>
        RunAsync(new("Set Up VS Code", "installEditorSetup", new Dictionary<string, string> { ["consent"] = "true" }));

    void Handle(JsonObject frame)
    {
        var workflow = (string?)frame["workflow"];
        var name = (string?)frame["name"];
        var fields = frame["fields"] as JsonObject ?? [];
        string? Field(string key) => (string?)fields[key];
        if (workflow == "shell")
        {
            switch (name)
            {
                case "openURL" when Field("url") is { } url: platform.OpenUrl(url); break;
                case "launchApplication": Launch(Field("kind"), fields); break;
                case "setClipboard" when Field("text") is { } text: platform.SetClipboard(text); break;
                case "notify": platform.Notify(Field("title") ?? "SSM Connect", Field("body") ?? ""); break;
            }
            return;
        }
        if (name == "state" && workflow is not null && Field("state") is { } state)
        {
            lock (states) states[workflow] = state;
            StateChanged?.Invoke();
        }
    }

    void Launch(string? kind, JsonObject fields)
    {
        switch (kind)
        {
            case "vsCode" when (string?)fields["path"] is { } path:
                var arguments = ((string?)fields["arguments"] ?? "").Split('\u001F', StringSplitOptions.RemoveEmptyEntries);
                platform.Start(path, arguments);
                break;
            case "dcvViewer" when (string?)fields["file"] is { } file:
                if (platform.DcvViewerPath is { } viewer) platform.Start(viewer, [file]);
                else platform.ShowError("DCV Viewer", "Install Amazon DCV Viewer to open the desktop. The tunnel stays connected.");
                break;
            case "browser":
                platform.StartBrowser((string?)fields["browser"] ?? "", (string?)fields["mode"] ?? "",
                                      (string?)fields["profile"] ?? "", int.TryParse((string?)fields["socksPort"], out var port) ? port : 1080);
                break;
        }
    }
}

/// <summary>What the controller needs from Windows; the WPF shell and tests each supply one.</summary>
public interface IShellPlatform
{
    string? DcvViewerPath { get; }
    void OpenUrl(string url);
    void Start(string path, IReadOnlyList<string> arguments);
    void StartBrowser(string browser, string mode, string profile, int socksPort);
    void SetClipboard(string text);
    void Notify(string title, string body);
    void ShowError(string action, string message);
}

/// <summary>The real Windows platform for the shell.</summary>
public sealed class WindowsShellPlatform(Action<string, string> notify, Action<string, string> showError, Func<int> clipboardClearSeconds) : IShellPlatform
{
    public string? DcvViewerPath => FindDcvViewer([
        Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
        Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),
    ]);

    /// <summary>
    /// DCV Viewer under the first Program Files folder that has it. AWS's Windows MSI installs it
    /// under Program Files (x86).
    /// </summary>
    internal static string? FindDcvViewer(IEnumerable<string> programFiles) =>
        programFiles.Where(root => !string.IsNullOrEmpty(root))
            .Select(root => Path.Combine(root, "NICE", "DCV", "Client", "bin", "dcvviewer.exe"))
            .FirstOrDefault(File.Exists);

    public void OpenUrl(string url)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri) || uri.Scheme != Uri.UriSchemeHttps) return;
        Process.Start(new ProcessStartInfo(uri.AbsoluteUri) { UseShellExecute = true })?.Dispose();
    }

    public void Start(string path, IReadOnlyList<string> arguments) => UserApplications.Start(path, arguments).Dispose();

    public void StartBrowser(string browser, string mode, string profile, int socksPort)
    {
        var profiles = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SSM Connect", "Browsers", profile);
        Directory.CreateDirectory(profiles);
        var chrome = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Google", "Chrome", "Application", "chrome.exe");
        if (browser == "chrome" && File.Exists(chrome))
            Start(chrome, [$"--user-data-dir={profiles}", $"--proxy-server=socks5://127.0.0.1:{socksPort}", "--new-window", "about:blank"]);
        else
            showError("Open Browser", "The managed browser could not be started.");
    }

    public void SetClipboard(string text)
    {
        System.Windows.Clipboard.SetText(text);
        var seconds = clipboardClearSeconds();
        if (seconds <= 0) return;
        _ = Task.Delay(TimeSpan.FromSeconds(seconds)).ContinueWith(_ => System.Windows.Application.Current?.Dispatcher.Invoke(() =>
        {
            if (System.Windows.Clipboard.ContainsText() && System.Windows.Clipboard.GetText() == text) System.Windows.Clipboard.Clear();
        }), TaskScheduler.Default);
    }

    public void Notify(string title, string body) => notify(title, body);
    public void ShowError(string action, string message) => showError(action, message);
}
