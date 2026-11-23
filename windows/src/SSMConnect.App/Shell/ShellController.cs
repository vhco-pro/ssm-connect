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
        host.StatusChanged += OnHelperStatus;
        if (host.Status == HelperHostStatus.Ready) _ = ReloadProfilesAsync(quiet: true);
    }

    /// <summary>
    /// A helper sends its details only after a first command, so a helper that becomes ready is
    /// asked for its profiles. A helper that stops takes its connections with it, and its
    /// replacement starts with none: what the stopped helper reported no longer describes anything.
    /// </summary>
    void OnHelperStatus()
    {
        if (host.Status == HelperHostStatus.Ready)
        {
            _ = ReloadProfilesAsync(quiet: true);
            return;
        }
        bool hadDetails;
        lock (details)
        {
            hadDetails = details.Count > 0;
            details.Clear();
        }
        if (hadDetails) DetailsChanged?.Invoke();
        lock (states)
        {
            if (states.Count == 0) return;
            states.Clear();
        }
        StateChanged?.Invoke();
    }

    readonly Dictionary<string, string> details = [];

    /// <summary>The macOS controls this shell offers, by inventory id.</summary>
    public static IReadOnlyList<ShellControl> Controls => ParityControls.All;
    public static ShellControl? Control(string id) => Controls.FirstOrDefault(c => c.Id == id);

    /// <summary>The helper's latest details: what the macOS menu reads from the workflows.</summary>
    public IReadOnlyDictionary<string, string> Details { get { lock (details) return new Dictionary<string, string>(details); } }

    /// <summary>Raised when the helper's details change.</summary>
    public event Action? DetailsChanged;

    /// <summary>Whether macOS would show the control in this state; <paramref name="context"/> adds the shell's own state.</summary>
    public bool IsOffered(string id, IReadOnlyDictionary<string, string>? context = null)
    {
        if (Control(id) is not { } control) return false;
        // Until the helper has sent its details, only the controls the shell serves itself are offered.
        var needsHelper = control.Command.Length > 0 || control.Commands.Count > 0 || control.CancelWorkflow.Length > 0;
        bool noDetails;
        lock (details) noDetails = details.Count == 0;
        return !(needsHelper && noDetails) && Evaluate(control.OfferedWhen, Merged(context));
    }

    /// <summary>Whether macOS would let the user operate the control in this state.</summary>
    public bool IsEnabled(string id, IReadOnlyDictionary<string, string>? context = null) =>
        Control(id) is { } control && IsOffered(id, context) && Evaluate(control.EnabledWhen, Merged(context));

    /// <summary>
    /// Evaluates an inventory rule: alternatives separated by " or ", clauses by " &amp; ". A clause is
    /// <c>key</c>, <c>!key</c>, <c>key=a|b</c>, <c>key!=a|b</c> or <c>key&gt;N</c>; an empty rule holds.
    /// </summary>
    public static bool Evaluate(string rule, IReadOnlyDictionary<string, string> values) =>
        string.IsNullOrWhiteSpace(rule) || rule.Split(" or ").Any(alternative => alternative.Split(" & ").All(part => Clause(part, values)));

    static bool Truthy(string? value) => !string.IsNullOrEmpty(value) && value != "false" && value != "0";

    static bool Clause(string text, IReadOnlyDictionary<string, string> values)
    {
        var c = text.Trim();
        string Value(string key) => values.TryGetValue(key, out var v) ? v : "";
        if (c.StartsWith('!') && !c.Contains('=')) return !Truthy(Value(c[1..]));
        if (c.Contains("!=")) { var p = c.Split("!=", 2); return !p[1].Split('|').Contains(Value(p[0])); }
        if (c.Contains('>')) { var p = c.Split('>', 2); return int.TryParse(Value(p[0]), out var n) && int.TryParse(p[1], out var limit) && n > limit; }
        if (c.Contains('=')) { var p = c.Split('=', 2); return p[1].Split('|').Contains(Value(p[0])); }
        return Truthy(Value(c));
    }

    Dictionary<string, string> Merged(IReadOnlyDictionary<string, string>? context)
    {
        Dictionary<string, string> values;
        lock (details) values = new Dictionary<string, string>(details);
        if (context is not null) foreach (var (key, value) in context) values[key] = value;
        return values;
    }

    string Detail(string key) { lock (details) return details.GetValueOrDefault(key, ""); }

    /// <summary>The control's label in the current state, as the macOS menu words it.</summary>
    public string LabelFor(string id)
    {
        if (Control(id) is not { } c) return "";
        var desktop = Detail("desktop.state");
        if (c.Command == "connect")
            return desktop switch { "connected" => "Connected", "error" => "Retry Connect", "" or "disconnected" => "Connect", _ => "Connecting…" };
        if (c.Commands.Count > 0) return Detail("web.state") is "On" or "Starting" ? "Turn Off Web Forwards" : "Turn On Web Forwards";
        var editor = Detail("editor.state");
        if (c.Command == "openEditor" && editor == "opening") return "Opening VS Code";
        if (c.Command == "reconnectWorkspace" && editor == "recovering") return "Recovering Existing Workspace";
        if (c.Command == "renewEditorAccess" && editor == "renewing") return "Renewing Editor Access";
        if (c.Command == "openBrowser" && Detail("web.openingBrowser") == "true") return "Opening Browser";
        return c.Label;
    }

    // Which workflow a command belongs to, for the cancel controls (the helper runs one per workflow).
    static readonly Dictionary<string, string> Workflows = new()
    {
        ["connect"] = "desktop", ["reconnect"] = "desktop", ["disconnect"] = "desktop", ["stopWorkstation"] = "desktop",
        ["openEditor"] = "editor", ["reconnectWorkspace"] = "editor", ["renewEditorAccess"] = "editor", ["approveReplacement"] = "editor",
        ["cancelEditorRecovery"] = "editor", ["stopRemoteAccess"] = "editor", ["restoreEditorSetup"] = "editor", ["installEditorSetup"] = "editor",
        ["startWebForwards"] = "web", ["stopWebForwards"] = "web", ["approveForwardingReplacement"] = "web", ["applyWebChanges"] = "web",
        ["cancelForwardingRecovery"] = "web",
    };

    // A cancel control whose no-command form is itself the cancellation; Stop Remote Access and
    // Restore Editor Setup instead run as their own command once the cancelled one has ended.
    static bool CancelsOnly(string otherwise) => otherwise is "cancelEditorRecovery" or "cancelForwardingRecovery" or "disconnect";

    readonly Dictionary<string, (Task<HelperResult> Task, CancellationTokenSource Cancel)> running = [];

    /// <summary>Sends a helper command directly and reports a failure; a workflow's command can be cancelled by its cancel controls.</summary>
    public Task<HelperResult> RunCommandAsync(string command, IReadOnlyDictionary<string, string>? arguments = null) =>
        RunCommandAsync(command, command, arguments);

    Task<HelperResult> RunCommandAsync(string label, string command, IReadOnlyDictionary<string, string>? arguments)
    {
        if (!Workflows.TryGetValue(command, out var workflow)) return RunAsync(new(label, command, arguments ?? Empty));
        var cancel = new CancellationTokenSource();
        var task = RunAsync(new(label, command, arguments ?? Empty), cancel.Token);
        lock (running) running[workflow] = (task, cancel);
        return task;
    }

    JsonArray profiles = [];
    JsonArray files = [];
    JsonObject appSettings = [];
    string activeProfileId = "";

    /// <summary>The profiles, the active one, the app settings and the attached files, from the helper's listProfiles.</summary>
    public JsonArray Profiles => profiles;
    public string ActiveProfileId => activeProfileId;
    public JsonObject AppSettings => appSettings;
    public JsonArray Files => files;

    /// <summary>Raised when the profiles were reloaded, with the profile to select or null.</summary>
    public event Action<string?>? ProfilesChanged;
    public event Action? ShowSettingsRequested;
    public event Action? ShowAboutRequested;
    public event Action? QuitRequested;
    /// <summary>Open the log window with its entries.</summary>
    public event Action<IReadOnlyList<JsonObject>>? ShowLogRequested;
    /// <summary>Open the profile editor with a draft, null for a blank profile.</summary>
    public event Action<JsonObject?>? EditProfileRequested;
    /// <summary>The ~/.aws/config profiles that can be imported.</summary>
    public event Action<IReadOnlyList<JsonObject>>? ImportableProfilesChanged;

    /// <summary>Reloads the profiles from the helper; the reload a ready helper gets is quiet, as the tray shows a helper that stops again.</summary>
    public async Task ReloadProfilesAsync(string? select = null, bool quiet = false)
    {
        var result = quiet ? await host.SendAsync("listProfiles", Empty, CancellationToken.None) : await RunAsync(new("Profiles", "listProfiles", Empty));
        if (result.Outcome != HelperOutcome.Completed) return;
        profiles = Parse(result.Value.GetValueOrDefault("profiles")) as JsonArray ?? [];
        files = Parse(result.Value.GetValueOrDefault("files")) as JsonArray ?? [];
        appSettings = Parse(result.Value.GetValueOrDefault("settings")) as JsonObject ?? [];
        activeProfileId = result.Value.GetValueOrDefault("active") ?? "";
        ProfilesChanged?.Invoke(select);
    }

    static JsonNode? Parse(string? json)
    {
        if (string.IsNullOrEmpty(json)) return null;
        try { return JsonNode.Parse(json); } catch (System.Text.Json.JsonException) { return null; }
    }

    /// <summary>A folder the user picks, for the profile editor's browser profile.</summary>
    public string? ChooseFolder(string title) => platform.ChooseFolder(title);

    JsonObject ActiveProfile() =>
        (profiles.OfType<JsonObject>().FirstOrDefault(p => (string?)p["id"] == activeProfileId) ?? profiles.OfType<JsonObject>().FirstOrDefault())
            ?.DeepClone().AsObject() ?? [];

    /// <summary>Fills <c>{key}</c> placeholders with values; <c>{editor.replacement.user}</c> reads a field of the JSON a value holds.</summary>
    static string Format(string text, IReadOnlyDictionary<string, string> values) =>
        System.Text.RegularExpressions.Regex.Replace(text, @"\{([a-zA-Z.]+)\}", match =>
        {
            var key = match.Groups[1].Value;
            var value = values.GetValueOrDefault(key, "");
            var parts = key.Split('.');
            if (value.Length == 0 && parts.Length >= 3 && Parse(values.GetValueOrDefault(parts[0] + "." + parts[1])) is JsonObject holder)
                value = holder[string.Join('.', parts[2..])]?.ToString() ?? "";
            return value;
        });

    /// <summary>
    /// Operates a control as macOS does: nothing when macOS would not offer or enable it, macOS's
    /// confirmation first, then its helper command. A cancel control cancels its workflow's running
    /// command. Returns the command's result, or null when nothing was sent.
    /// </summary>
    public async Task<HelperResult?> TriggerAsync(string id, IReadOnlyDictionary<string, string>? arguments = null,
                                                  IReadOnlyDictionary<string, string>? context = null)
    {
        if (Control(id) is not { } c || !IsEnabled(id, context)) return null;
        var values = Merged(context);
        var args = new Dictionary<string, string>(arguments ?? Empty);
        var asks = c.ConfirmTitle.Length > 0 && Evaluate(c.ConfirmWhen, values);
        bool Confirmed() => !asks || platform.Confirm(Format(c.ConfirmTitle, values), Format(c.ConfirmText, values));

        if (c.CancelWorkflow.Length > 0)
        {
            if (!Confirmed()) return null;
            (Task<HelperResult> Task, CancellationTokenSource Cancel) work;
            bool found;
            lock (running) found = running.TryGetValue(c.CancelWorkflow, out work);
            if (found && !work.Task.IsCompleted) return await CancelRunningAsync(work, c, args);
            return await RunCommandAsync(c.Label, c.Otherwise, args);
        }
        if (c.Command.Length == 0 && c.Commands.Count == 0)
        {
            PerformShell(c, args);
            return null;
        }
        if (c.Field.Length > 0) return await EditFieldAsync(c, args);

        var command = c.Commands.Count > 0 ? (values.GetValueOrDefault("web.state") is "On" or "Starting" ? c.Commands[1] : c.Commands[0]) : c.Command;
        switch (command)
        {
            case "importProfile":
                return await OpenProfileFileAsync(c);
            case "saveProfile":
                return await SaveProfileAsync(args.GetValueOrDefault("profile") ?? ActiveProfile().ToJsonString());
            case "exportProfile":
                if (platform.ChooseSaveFile("Export Profile") is not { } exportPath) return null;
                args["path"] = exportPath;
                break;
            case "locateProfileFile":
                if (platform.ChooseProfileFile() is not { } locatedPath) return null;
                args["path"] = locatedPath;
                break;
            case "openBrowser" when asks:
            {
                // macOS asks for a browser mode when the profile has none, and saves it first.
                var choice = platform.Choose(Format(c.ConfirmTitle, values), Format(c.ConfirmText, values), c.Choices);
                if (choice is < 0 or >= 2) return null;
                var profile = ActiveProfile();
                var web = profile["webForwards"] as JsonObject ?? [];
                web["browserMode"] = choice == 0 ? "separate" : "existing";
                profile["webForwards"] = web.DeepClone();
                await SaveProfileAsync(profile.ToJsonString());
                return await RunCommandAsync(c.Label, command, args);
            }
            case "openEditor" when asks:
            {
                // First use: consent to the SSH Include, then open.
                if (!Confirmed()) return null;
                var setup = await RunCommandAsync("Set Up VS Code", "installEditorSetup", new Dictionary<string, string> { ["consent"] = "true" });
                return setup.Outcome == HelperOutcome.Completed ? await RunCommandAsync(c.Label, command, args) : setup;
            }
        }
        if (!Confirmed()) return null;
        var result = await RunCommandAsync(c.Label, command, args);
        if (c.Shell.Length > 0 && command == "getLog")
            ShowLogRequested?.Invoke((Parse(result.Value.GetValueOrDefault("entries")) as JsonArray ?? []).OfType<JsonObject>().ToList());
        if (command == "listAWSConfigProfiles")
            ImportableProfilesChanged?.Invoke((Parse(result.Value.GetValueOrDefault("profiles")) as JsonArray ?? []).OfType<JsonObject>().ToList());
        if (command.Contains("Profile", StringComparison.Ordinal) || command is "saveLocalCopy" or "applyFileChanges" or "saveSettings" or "reviewFileChanges")
            await ReloadProfilesAsync(args.GetValueOrDefault("id"));
        // Outside changes to an attached file are shown, as macOS shows them, and stay pending until applied.
        if (command == "reviewFileChanges" && result.Value.GetValueOrDefault("pending") == "true")
            platform.Choose("Review external profile changes", ReviewMessage(result.Value.GetValueOrDefault("document")), ["Keep Pending"]);
        return result;
    }

    const string ReviewText =
        "The stored configuration and existing connections have not changed. Apply replaces the stored configuration only; existing transport-specific pending-Apply and ownership checks still apply.";

    static string ReviewMessage(string? document)
    {
        var d = Parse(document) as JsonObject ?? [];
        string F(string key) => d[key]?.ToString() ?? "";
        return $"{ReviewText}\nAccount: {F("accountId")}, role: {F("roleName")}\nRegion: {F("resourceRegion")}, target: {F("instanceTagKey")}={F("instanceTagValue")}";
    }

    /// <summary>
    /// Cancels the running command of the control's workflow. When the helper had already finished it,
    /// the result is not "cancelled": a pure cancel control then sends its no-command form once, which
    /// ends what the finished command left (such as a replacement waiting for review). Stop Remote
    /// Access and Restore Editor Setup run as their own command once the cancelled one has ended. The
    /// cancelled command itself is never sent again.
    /// </summary>
    async Task<HelperResult> CancelRunningAsync((Task<HelperResult> Task, CancellationTokenSource Cancel) work, ShellControl c,
                                                IReadOnlyDictionary<string, string> arguments)
    {
        work.Cancel.Cancel();
        var result = await work.Task;
        if (!CancelsOnly(c.Otherwise) || result.Outcome != HelperOutcome.Cancelled)
            return await RunCommandAsync(c.Label, c.Otherwise, arguments);
        return result;
    }

    void PerformShell(ShellControl c, IReadOnlyDictionary<string, string> arguments)
    {
        var what = c.Shell;
        if (what.StartsWith("open the settings window", StringComparison.Ordinal)) ShowSettingsRequested?.Invoke();
        else if (what.StartsWith("open the About window", StringComparison.Ordinal)) ShowAboutRequested?.Invoke();
        else if (what.StartsWith("quit", StringComparison.Ordinal)) QuitRequested?.Invoke();
        else if (what.StartsWith("open the documentation URL", StringComparison.Ordinal))
            platform.OpenUrl("https://code.visualstudio.com/docs/remote/troubleshooting");
        else if (what.StartsWith("open the license URL", StringComparison.Ordinal))
            platform.OpenUrl("https://github.com/vhco-pro/ssm-connect/blob/main/LICENSE");
        else if (what.StartsWith("open the project URL", StringComparison.Ordinal)) platform.OpenUrl("https://github.com/vhco-pro/ssm-connect");
        else if (what.StartsWith("open the release notes URL", StringComparison.Ordinal))
            platform.OpenUrl("https://github.com/vhco-pro/ssm-connect/releases");
        else if (what.StartsWith("open the profile editor with a blank", StringComparison.Ordinal)) EditProfileRequested?.Invoke(null);
        else if (what.StartsWith("open the profile editor", StringComparison.Ordinal))
            EditProfileRequested?.Invoke(Parse(arguments.GetValueOrDefault("profile")) as JsonObject ?? ActiveProfile());
    }

    /// <summary>Edits one field of the profile the window passes (or the active one) and saves it, or one app setting.</summary>
    async Task<HelperResult?> EditFieldAsync(ShellControl c, IReadOnlyDictionary<string, string> arguments)
    {
        if (c.Command == "saveSettings")
        {
            var result = await RunCommandAsync(c.Label, "saveSettings", new Dictionary<string, string> { [c.Field] = arguments.GetValueOrDefault("value", "") });
            await ReloadProfilesAsync();
            return result;
        }
        var profile = Parse(arguments.GetValueOrDefault("profile")) as JsonObject ?? ActiveProfile();
        if (arguments.TryGetValue("value", out var value) && !c.Field.Contains("[]", StringComparison.Ordinal) && !c.Field.Contains(' '))
        {
            JsonNode node = int.TryParse(value, out var number) && c.Field.EndsWith("Port", StringComparison.Ordinal) ? JsonValue.Create(number)
                : value is "true" or "false" ? JsonValue.Create(value == "true") : JsonValue.Create(value);
            var path = c.Field.Split('.');
            if (path.Length == 1) profile[path[0]] = node;
            else
            {
                var section = profile[path[0]] as JsonObject ?? [];
                section[path[1]] = node;
                profile[path[0]] = section.DeepClone();
            }
        }
        return await SaveProfileAsync(profile.ToJsonString());
    }

    /// <summary>Open Profile File: macOS previews the file before anything is stored, then attaches it or imports a local copy.</summary>
    async Task<HelperResult?> OpenProfileFileAsync(ShellControl c)
    {
        if (platform.ChooseProfileFile() is not { } path) return null;
        var preview = await RunCommandAsync("Open Profile File", "previewProfileFile", new Dictionary<string, string> { ["path"] = path });
        if (preview.Outcome != HelperOutcome.Completed) return preview;
        var values = Merged(null);
        if (Parse(preview.Value.GetValueOrDefault("profile")) is JsonObject previewed)
            foreach (var (key, node) in previewed) values["preview." + key] = node?.ToString() ?? "";
        var choice = platform.Choose(Format(c.ConfirmTitle, values), Format(c.ConfirmText, values), c.Choices);
        if (choice is < 0 or >= 2) return preview;
        var imported = await RunCommandAsync(c.Label, "importProfile",
                                             new Dictionary<string, string> { ["path"] = path, ["attach"] = choice == 0 ? "true" : "false" });
        await ReloadProfilesAsync();
        return imported;
    }

    /// <summary>Latest state per workflow (desktop, web, editor), from the helper's events.</summary>
    public IReadOnlyDictionary<string, string> States { get { lock (states) return new Dictionary<string, string>(states); } }

    /// <summary>Raised when a workflow's state changes.</summary>
    public event Action? StateChanged;

    static readonly IReadOnlyDictionary<string, string> Empty = new Dictionary<string, string>();

    const string SignInRequiredBody =
        "Your SSO session has ended. Choose Sign In with SSO in the SSM Connect menu; what you started continues after you sign in.";

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
        // A new profile gets its id here, as the macOS editor gives one.
        if (JsonNode.Parse(profileJson) is JsonObject draft && string.IsNullOrEmpty((string?)draft["id"]))
        {
            draft["id"] = Guid.NewGuid().ToString().ToUpperInvariant();
            profileJson = draft.ToJsonString();
        }
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
        // Reloading keeps the saved profile selected, so Use acts on it.
        await ReloadProfilesAsync(JsonNode.Parse(profileJson)?["id"]?.GetValue<string>());
        return result;
    }

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
                case "reveal" when Field("path") is { } path: platform.Reveal(path); break;
                case "notify": platform.Notify(Field("title") ?? "SSM Connect", Field("body") ?? ""); break;
            }
            return;
        }
        if (workflow == "details" && name == "details")
        {
            lock (details)
            {
                details.Clear();
                foreach (var (key, value) in fields) details[key] = value?.ToString() ?? "";
            }
            DetailsChanged?.Invoke();
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
    /// <summary>One of <paramref name="options"/> the user picks, by index, or -1 when they cancel.</summary>
    int Choose(string title, string message, IReadOnlyList<string> options) => -1;
    /// <summary>A profile file the user picks, or null when they cancel.</summary>
    string? ChooseProfileFile() => null;
    /// <summary>A folder the user picks, or null when they cancel.</summary>
    string? ChooseFolder(string title) => null;
    /// <summary>A file to write the user picks, or null when they cancel.</summary>
    string? ChooseSaveFile(string title) => null;
    /// <summary>Shows a file in Explorer.</summary>
    void Reveal(string path) { }
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

    /// <summary>
    /// Whether the shell opens this URL: the sign-in page and documentation (https) and a local
    /// forward's page (http to a loopback address).
    /// </summary>
    internal static bool Opens(string url) =>
        Uri.TryCreate(url, UriKind.Absolute, out var uri)
        && (uri.Scheme == Uri.UriSchemeHttps || (uri.Scheme == Uri.UriSchemeHttp && uri.IsLoopback));

    public void OpenUrl(string url)
    {
        if (!Opens(url)) return;
        Process.Start(new ProcessStartInfo(new Uri(url).AbsoluteUri) { UseShellExecute = true })?.Dispose();
    }

    public void Start(string path, IReadOnlyList<string> arguments) => UserApplications.Start(path, arguments).Dispose();

    /// <summary>
    /// Sets the clipboard on the UI thread: the helper's requests arrive on the host's reader thread,
    /// and the WPF clipboard works only on the UI thread.
    /// </summary>
    public void SetClipboard(string text)
    {
        var dispatcher = System.Windows.Application.Current?.Dispatcher;
        if (dispatcher is null) return;
        dispatcher.Invoke(() => System.Windows.Clipboard.SetText(text));
        var seconds = clipboardClearSeconds();
        if (seconds <= 0) return;
        _ = Task.Delay(TimeSpan.FromSeconds(seconds)).ContinueWith(_ => dispatcher.Invoke(() =>
        {
            if (System.Windows.Clipboard.ContainsText() && System.Windows.Clipboard.GetText() == text) System.Windows.Clipboard.Clear();
        }), TaskScheduler.Default);
    }

    public void Notify(string title, string body) => notify(title, body);
    public void ShowError(string action, string message) => showError(action, message);

    public bool Confirm(string title, string message) =>
        System.Windows.MessageBox.Show(message, title, System.Windows.MessageBoxButton.YesNo, System.Windows.MessageBoxImage.Question)
            == System.Windows.MessageBoxResult.Yes;

    /// <summary>A dialog with one button per option, as macOS's alerts offer them; closing it cancels.</summary>
    public int Choose(string title, string message, IReadOnlyList<string> options)
    {
        var choice = -1;
        var dialog = new System.Windows.Window
        {
            Title = title, SizeToContent = System.Windows.SizeToContent.WidthAndHeight, ResizeMode = System.Windows.ResizeMode.NoResize,
            WindowStartupLocation = System.Windows.WindowStartupLocation.CenterScreen, MaxWidth = 520,
        };
        var panel = new System.Windows.Controls.StackPanel { Margin = new System.Windows.Thickness(16) };
        panel.Children.Add(new System.Windows.Controls.TextBlock { Text = message, TextWrapping = System.Windows.TextWrapping.Wrap, MaxWidth = 480 });
        var buttons = new System.Windows.Controls.StackPanel
        {
            Orientation = System.Windows.Controls.Orientation.Horizontal, HorizontalAlignment = System.Windows.HorizontalAlignment.Right,
            Margin = new System.Windows.Thickness(0, 16, 0, 0),
        };
        for (var i = 0; i < options.Count; i++)
        {
            var index = i;
            var button = new System.Windows.Controls.Button
            {
                Content = options[i], Margin = new System.Windows.Thickness(8, 0, 0, 0), Padding = new System.Windows.Thickness(12, 4, 12, 4),
                IsDefault = i == 0, IsCancel = options[i] == "Cancel",
            };
            button.Click += (_, _) => { choice = index; dialog.Close(); };
            buttons.Children.Add(button);
        }
        panel.Children.Add(buttons);
        dialog.Content = panel;
        dialog.ShowDialog();
        return choice;
    }

    /// <summary>The profile file dialogs' filters; the helper reads and writes .json, .yaml and .yml, as macOS offers.</summary>
    internal const string OpenProfileFilter = "SSM Connect profiles|*.yaml;*.yml;*.json";
    internal const string SaveProfileFilter = "Profile (YAML)|*.yaml;*.yml|Profile (JSON)|*.json";
    internal const string SaveProfileExtension = ".yaml";

    public string? ChooseProfileFile()
    {
        var dialog = new Microsoft.Win32.OpenFileDialog { Filter = OpenProfileFilter };
        return dialog.ShowDialog() == true ? dialog.FileName : null;
    }

    public string? ChooseFolder(string title)
    {
        var dialog = new Microsoft.Win32.OpenFolderDialog { Title = title };
        return dialog.ShowDialog() == true ? dialog.FolderName : null;
    }

    public string? ChooseSaveFile(string title)
    {
        var dialog = new Microsoft.Win32.SaveFileDialog { Title = title, Filter = SaveProfileFilter, DefaultExt = SaveProfileExtension, FileName = "workstation" + SaveProfileExtension };
        return dialog.ShowDialog() == true ? dialog.FileName : null;
    }

    /// <summary>Explorer's arguments that select a file: the path quoted after /select, with Windows separators.</summary>
    internal static string ExplorerSelectArguments(string path) => $"/select,\"{path.Replace('/', '\\')}\"";

    /// <summary>Opens Explorer with the file selected.</summary>
    public void Reveal(string path)
    {
        if (!File.Exists(path)) return;
        Process.Start(new ProcessStartInfo("explorer.exe", ExplorerSelectArguments(path)) { UseShellExecute = false })?.Dispose();
    }
}
