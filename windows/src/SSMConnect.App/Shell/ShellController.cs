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

    const string SignInRequiredBody =
        "Your SSO session has ended. Choose Sign In with SSO in the SSM Connect menu; what you started continues after you sign in.";

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

    CancellationTokenSource? connecting;

    /// <summary>
    /// Sends an action's command and reports a failure to the user. The helper refuses a second
    /// desktop command while Connect runs, so Disconnect then cancels the Connect, as Disconnect while
    /// connecting does on macOS: the helper's cancel ends what the Connect started.
    /// </summary>
    public async Task<HelperResult> RunAsync(ShellAction action, CancellationToken cancellationToken = default)
    {
        if (action.Command == "disconnect" && Volatile.Read(ref connecting) is { } running)
        {
            running.Cancel();
            return new HelperResult(HelperOutcome.Completed, null, null, Empty);
        }
        using var linked = action.Command == "connect" ? CancellationTokenSource.CreateLinkedTokenSource(cancellationToken) : null;
        if (linked is not null) Volatile.Write(ref connecting, linked);
        try
        {
            var result = await host.SendAsync(action.Command, action.Arguments, linked?.Token ?? cancellationToken);
            if (result.Outcome is HelperOutcome.Failed or HelperOutcome.Rejected or HelperOutcome.CoreStopped)
                platform.ShowError(action.Label, result.Message ?? HelperHost.UnavailableMessage);
            return result;
        }
        finally
        {
            if (linked is not null) Interlocked.CompareExchange(ref connecting, null, linked);
        }
    }

    /// <summary>
    /// Saves a profile. An attached file needs consent to its canonical formatting once, and is never
    /// saved over changes made outside SSM Connect: the user can load the file's version instead.
    /// </summary>
    public async Task<HelperResult> SaveProfileAsync(string profileJson)
    {
        var arguments = new Dictionary<string, string> { ["profile"] = profileJson };
        var result = await host.SendAsync("saveProfile", arguments, CancellationToken.None);
        if (result.Code == "formattingConsentRequired")
        {
            if (!platform.Confirm("Save Profile", result.Message ?? "")) return result;
            arguments["acceptFormatting"] = "true";
            result = await host.SendAsync("saveProfile", arguments, CancellationToken.None);
        }
        if (result.Code == "fileConflict")
        {
            if (platform.Confirm("Save Profile", (result.Message ?? "") + " Load the file's version now? Your edits are not saved.")
                && JsonNode.Parse(profileJson)?["id"]?.GetValue<string>() is { } id)
                return await RunAsync(new("Load File Changes", "applyFileChanges", new Dictionary<string, string> { ["id"] = id }));
            return result;
        }
        if (result.Outcome is HelperOutcome.Failed or HelperOutcome.Rejected or HelperOutcome.CoreStopped)
            platform.ShowError("Save Profile", result.Message ?? HelperHost.UnavailableMessage);
        return result;
    }

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
            string? previous;
            lock (states)
            {
                previous = states.GetValueOrDefault(workflow);
                states[workflow] = state;
            }
            // An action waits for an explicit sign-in once the SSO session can no longer be renewed:
            // say so once, and name the menu item, since the tray only shows the action's state.
            if (workflow == "authorization" && state == "signInRequired" && previous != state)
                platform.Notify("Sign in required", SignInRequiredBody);
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
            // The core picks the browser and builds its command line, routing included.
            case "browser" when (string?)fields["path"] is { } browser:
                platform.Start(browser, ((string?)fields["arguments"] ?? "").Split('\u001F', StringSplitOptions.RemoveEmptyEntries));
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
    void SetClipboard(string text);
    void Notify(string title, string body);
    void ShowError(string action, string message);
    /// <summary>Asks the user a yes-or-no question; true for yes.</summary>
    bool Confirm(string title, string message);
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

    public bool Confirm(string title, string message) =>
        System.Windows.MessageBox.Show(message, title, System.Windows.MessageBoxButton.YesNo, System.Windows.MessageBoxImage.Question)
            == System.Windows.MessageBoxResult.Yes;
}
