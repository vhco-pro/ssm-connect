using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;

namespace SSMConnect.App.Shell;

/// <summary>
/// The profile editor, with the macOS editor's fields: general, SSO, workstation, tunnel, connect
/// mode, remote development and web forwards with their proxy suffixes and local forwards. It edits a
/// draft and saves it through the shell controller, which sends saveProfile (with the attached-file
/// consent and conflict handling) or saveLocalCopy. Each control is named by its parity inventory id.
/// </summary>
public sealed class ProfileEditorWindow : Window
{
    readonly ShellController controller;
    readonly bool attached;
    readonly StackPanel panel = new() { Margin = new Thickness(12) };
    JsonObject draft;

    public ProfileEditorWindow(ShellController controller, JsonObject draft, bool attached)
    {
        this.controller = controller;
        this.attached = attached;
        this.draft = Ensure(draft.DeepClone().AsObject());
        Title = (string?)this.draft["name"] is { Length: > 0 } name ? "Edit " + name : "New Profile";
        Width = 560;
        Height = 720;
        Content = new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };
        Build();
    }

    /// <summary>The draft as edited so far.</summary>
    public JsonObject Draft => draft;

    static JsonObject Ensure(JsonObject d)
    {
        if (d["webForwards"] is not JsonObject web) d["webForwards"] = web = new JsonObject { ["enabled"] = false };
        if (web["proxySuffixes"] is not JsonArray) web["proxySuffixes"] = new JsonArray();
        if (web["localForwards"] is not JsonArray) web["localForwards"] = new JsonArray();
        if (d["remoteDevelopment"] is not JsonObject) d["remoteDevelopment"] = new JsonObject { ["enabled"] = false };
        if (d["connectAction"] is not JsonObject) d["connectAction"] = new JsonObject { ["dcvViewer"] = new JsonObject() };
        if (d["connectMode"] is null) d["connectMode"] = "singleUser";
        return d;
    }

    string Text(string path)
    {
        var parts = path.Split('.');
        var node = parts.Length == 1 ? draft[parts[0]] : (draft[parts[0]] as JsonObject)?[parts[1]];
        return node?.ToString() ?? "";
    }

    void Set(string path, JsonNode? value)
    {
        var parts = path.Split('.');
        if (parts.Length == 1) draft[parts[0]] = value;
        else ((JsonObject)draft[parts[0]]!)[parts[1]] = value;
    }

    JsonObject Web => (JsonObject)draft["webForwards"]!;
    JsonArray Suffixes => (JsonArray)Web["proxySuffixes"]!;
    JsonArray Forwards => (JsonArray)Web["localForwards"]!;

    static JsonNode? Port(string text) => int.TryParse(text, out var port) && port is >= 1 and <= 65535 ? JsonValue.Create(port) : null;

    // Rebuilds the form from the draft, after a row was added or removed or a choice changed what shows.
    void Build()
    {
        panel.Children.Clear();
        Heading("General");
        Field("profileeditor-textfield-display-name", "Display name", "name");
        Heading("SSO");
        Field("profileeditor-textfield-sso-start-url", "SSO start URL", "ssoStartUrl");
        Field("profileeditor-textfield-sso-region", "SSO region", "ssoRegion");
        Field("profileeditor-textfield-account-id", "Account ID", "accountId");
        Field("profileeditor-textfield-role-name", "Role name", "roleName");
        Heading("Workstation");
        Field("profileeditor-textfield-resource-region", "Resource region", "resourceRegion");
        Field("profileeditor-textfield-instance-tag-key", "Instance tag key", "instanceTagKey");
        Field("profileeditor-textfield-instance-tag-value", "Instance tag value", "instanceTagValue");
        Field("profileeditor-textfield-dcv-password-secret-id-optional", "DCV password secret id (optional)", "secretId");
        Heading("Tunnel");
        var ports = Row();
        PortField(ports, "profileeditor-textfield-local-port", "Local port", "localPort");
        PortField(ports, "profileeditor-textfield-remote-port", "Remote port", "remotePort");
        var dcv = Check("profileeditor-toggle-open-dcv-viewer-automatically", "Open DCV Viewer automatically",
                        (draft["connectAction"] as JsonObject)?.ContainsKey("dcvViewer") == true);
        dcv.Click += (_, _) => draft["connectAction"] = dcv.IsChecked == true ? new JsonObject { ["dcvViewer"] = new JsonObject() }
                                                                              : new JsonObject { ["tunnelOnly"] = new JsonObject() };
        Heading("Connect mode");
        var mode = Picker("profileeditor-picker-mode", ["Single-user", "Multi-user"], Text("connectMode") == "multiUser" ? 1 : 0);
        mode.SelectionChanged += (_, _) => { Set("connectMode", mode.SelectedIndex == 1 ? "multiUser" : "singleUser"); Build(); };
        if (Text("connectMode") == "multiUser") PortField(Row(), "profileeditor-textfield-agent-port", "Agent port", "agentRemotePort");

        Heading("Remote Development");
        var native = Check("profileeditor-toggle-enable-native-vs-code-access", "Enable native VS Code access", Text("remoteDevelopment.enabled") == "true");
        native.Click += (_, _) => { Set("remoteDevelopment.enabled", native.IsChecked == true); Build(); };
        Field("profileeditor-textfield-remote-folder-optional", "Remote folder (optional), /home/user/code/project", "remoteDevelopment.folder")
            .IsEnabled = Text("remoteDevelopment.enabled") == "true";

        Heading("Web Forwards");
        var enabled = Text("webForwards.enabled") == "true";
        var webToggle = Check("profileeditor-toggle-enable-web-forwards", "Enable web forwards", enabled);
        webToggle.Click += (_, _) => { Set("webForwards.enabled", webToggle.IsChecked == true); Build(); };
        var web = new StackPanel { IsEnabled = enabled };
        panel.Children.Add(web);
        Field("profileeditor-textfield-ssh-user-optional", "SSH user (optional)", "webForwards.sshUser", web);
        var socksRow = Row(web);
        var socks = Check("profileeditor-toggle-socks-proxy", "SOCKS proxy", Text("webForwards.socksPort").Length > 0, socksRow);
        socks.Click += (_, _) => { Set("webForwards.socksPort", socks.IsChecked == true ? 1080 : null); Build(); };
        if (Text("webForwards.socksPort").Length > 0) PortField(socksRow, "profileeditor-textfield-socks-port", "SOCKS port", "webForwards.socksPort");
        var browsers = new[] { "automatic", "chrome", "zen" };
        var browserRow = Row(web);
        browserRow.Children.Add(Label("Browser"));
        var browser = Picker("profileeditor-picker-browser", browsers, Math.Max(0, Array.IndexOf(browsers, Text("webForwards.browser"))), browserRow);
        browser.SelectionChanged += (_, _) => Set("webForwards.browser", browsers[Math.Max(0, browser.SelectedIndex)]);
        browserRow.Children.Add(Label("Browser Mode"));
        var existing = Text("webForwards.browserMode") == "existing";
        var browserMode = Picker("profileeditor-picker-browser-mode", ["Separate Browser", "Use My Browser"], existing ? 1 : 0, browserRow);
        browserMode.SelectionChanged += (_, _) => { Set("webForwards.browserMode", browserMode.SelectedIndex == 1 ? "existing" : "separate"); Build(); };
        if (existing)
        {
            var profileRow = Row(web);
            profileRow.Children.Add(Label("Profile: " + (Text("webForwards.browserProfilePath") is { Length: > 0 } p ? p : "Not selected")));
            var choose = Button("profileeditor-button-choose-profile-folder", "Choose Profile Folder", profileRow);
            choose.Click += (_, _) =>
            {
                if (controller.ChooseFolder("Choose the Zen profile folder") is { } folder) { Set("webForwards.browserProfilePath", folder); Build(); }
            };
            web.Children.Add(new TextBlock { Text = "Zen only. Chrome requires a separately approved proxy extension and is unavailable in this mode.",
                                             FontSize = 11, TextWrapping = TextWrapping.Wrap });
        }
        for (var i = 0; i < Suffixes.Count; i++)
        {
            var index = i;
            var row = Row(web);
            var suffix = new TextBox { Text = Suffixes[index]?.ToString() ?? "", MinWidth = 300 };
            AutomationProperties.SetAutomationId(suffix, "profileeditor-textfield-domain-suffix");
            suffix.LostFocus += (_, _) => Suffixes[index] = suffix.Text;
            row.Children.Add(suffix);
            var remove = Button("profileeditor-button-remove-domain", "−", row);
            remove.ToolTip = "Remove domain";
            AutomationProperties.SetName(remove, "Remove domain");
            remove.Click += (_, _) => { Suffixes.RemoveAt(index); Build(); };
        }
        var addDomain = Button("profileeditor-button-add-a-proxy-domain-suffix", "Add Domain", web);
        addDomain.Click += (_, _) => { Suffixes.Add(""); Build(); };
        for (var i = 0; i < Forwards.Count; i++)
        {
            var forward = (JsonObject)Forwards[i]!;
            var index = i;
            var box = new StackPanel { Margin = new Thickness(0, 6, 0, 0) };
            web.Children.Add(box);
            var top = Row(box);
            ForwardField(top, forward, "profileeditor-textfield-name", "Name", "name");
            var remove = Button("profileeditor-button-remove-local-forward", "−", top);
            remove.ToolTip = "Remove local forward";
            AutomationProperties.SetName(remove, "Remove local forward");
            remove.Click += (_, _) => { Forwards.RemoveAt(index); Build(); };
            var portRow = Row(box);
            ForwardField(portRow, forward, "profileeditor-textfield-local-port-2", "Local port", "localPort");
            ForwardField(portRow, forward, "profileeditor-textfield-remote-port-2", "Remote port", "remotePort");
            ForwardField(Row(box), forward, "profileeditor-textfield-remote-host", "Remote host", "remoteHost");
            ForwardField(Row(box), forward, "profileeditor-textfield-open-path-optional", "Open path (optional)", "openPath");
        }
        var addForward = Button("profileeditor-button-add-local-forward", "Add Local Forward", web);
        addForward.Click += (_, _) =>
        {
            Forwards.Add(new JsonObject { ["name"] = "New Forward", ["localPort"] = 8080, ["remoteHost"] = "127.0.0.1", ["remotePort"] = 8080 });
            Build();
        };

        var buttons = Row();
        buttons.Margin = new Thickness(0, 12, 0, 0);
        Button("profileeditor-button-cancel", "Cancel", buttons).Click += (_, _) => Close();
        var context = new Dictionary<string, string> { ["item.attached"] = attached ? "true" : "false" };
        var localCopy = Button("profileeditor-button-save-a-local-copy", "Save a Local Copy", buttons);
        localCopy.Visibility = controller.IsOffered("profileeditor-button-save-a-local-copy", context) ? Visibility.Visible : Visibility.Collapsed;
        localCopy.Click += async (_, _) =>
        {
            await controller.TriggerAsync("profileeditor-button-save-a-local-copy",
                                          new Dictionary<string, string> { ["id"] = (string?)draft["id"] ?? "", ["profile"] = draft.ToJsonString() }, context);
            Close();
        };
        var save = Button("profileeditor-button-save", "Save", buttons);
        save.IsDefault = true;
        save.Click += async (_, _) => { await controller.SaveProfileAsync(draft.ToJsonString()); Close(); };
    }

    void Heading(string text) =>
        panel.Children.Add(new TextBlock { Text = text, FontWeight = FontWeights.Bold, Margin = new Thickness(0, 10, 0, 4) });

    StackPanel Row(Panel? parent = null)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 2, 0, 2) };
        (parent ?? panel).Children.Add(row);
        return row;
    }

    static TextBlock Label(string text) => new() { Text = text, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 6, 0) };

    TextBox Field(string id, string label, string path, Panel? parent = null)
    {
        var target = parent ?? panel;
        target.Children.Add(new TextBlock { Text = label, Margin = new Thickness(0, 4, 0, 0) });
        var box = new TextBox { Text = Text(path) };
        AutomationProperties.SetAutomationId(box, id);
        AutomationProperties.SetName(box, label);
        box.LostFocus += (_, _) => Set(path, box.Text);
        target.Children.Add(box);
        return box;
    }

    void PortField(Panel row, string id, string label, string path)
    {
        row.Children.Add(Label(label));
        var box = new TextBox { Text = Text(path), Width = 70, Margin = new Thickness(0, 0, 12, 0) };
        AutomationProperties.SetAutomationId(box, id);
        AutomationProperties.SetName(box, label);
        box.LostFocus += (_, _) => { if (Port(box.Text) is { } port) Set(path, port); };
        row.Children.Add(box);
    }

    static void ForwardField(Panel row, JsonObject forward, string id, string label, string key)
    {
        row.Children.Add(Label(label));
        var box = new TextBox { Text = forward[key]?.ToString() ?? "", MinWidth = key.EndsWith("Port", StringComparison.Ordinal) ? 70 : 200 };
        AutomationProperties.SetAutomationId(box, id);
        AutomationProperties.SetName(box, label);
        box.LostFocus += (_, _) => forward[key] = key.EndsWith("Port", StringComparison.Ordinal) ? Port(box.Text) : JsonValue.Create(box.Text);
        row.Children.Add(box);
    }

    CheckBox Check(string id, string label, bool value, Panel? parent = null)
    {
        var box = new CheckBox { Content = label, IsChecked = value, Margin = new Thickness(0, 2, 8, 2) };
        AutomationProperties.SetAutomationId(box, id);
        (parent ?? panel).Children.Add(box);
        return box;
    }

    ComboBox Picker(string id, IReadOnlyList<string> options, int selected, Panel? parent = null)
    {
        var box = new ComboBox { MinWidth = 140, Margin = new Thickness(0, 0, 12, 0) };
        foreach (var option in options) box.Items.Add(option);
        box.SelectedIndex = selected;
        AutomationProperties.SetAutomationId(box, id);
        (parent ?? panel).Children.Add(box);
        return box;
    }

    Button Button(string id, string label, Panel parent)
    {
        var button = new Button { Content = label, Padding = new Thickness(10, 4, 10, 4), Margin = new Thickness(0, 4, 6, 0), MinWidth = 32 };
        AutomationProperties.SetAutomationId(button, id);
        parent.Children.Add(button);
        return button;
    }
}

/// <summary>The connection log, as the macOS Log window shows it: the helper's entries, and Clear.</summary>
public sealed class LogWindow : Window
{
    public LogWindow(ShellController controller, IReadOnlyList<JsonObject> entries)
    {
        Title = "SSM Connect Log";
        Width = 640;
        Height = 420;
        var dock = new DockPanel { Margin = new Thickness(12) };
        var footer = new DockPanel { Margin = new Thickness(0, 8, 0, 0) };
        DockPanel.SetDock(footer, Dock.Bottom);
        var count = new TextBlock { Text = entries.Count + " entries", VerticalAlignment = VerticalAlignment.Center };
        footer.Children.Add(count);
        var clear = new Button { Content = "Clear", Padding = new Thickness(12, 4, 12, 4), HorizontalAlignment = HorizontalAlignment.Right };
        AutomationProperties.SetAutomationId(clear, "log-button-clear");
        footer.Children.Add(clear);
        dock.Children.Add(footer);
        var lines = new ListBox();
        foreach (var entry in entries)
            lines.Items.Add(new TextBlock { Text = $"{(string?)entry["time"]}  [{(string?)entry["category"]}]  {(string?)entry["message"]}", TextWrapping = TextWrapping.Wrap });
        if (entries.Count == 0) lines.Items.Add(new TextBlock { Text = "Connection events appear here as they happen." });
        dock.Children.Add(lines);
        clear.Click += async (_, _) =>
        {
            await controller.TriggerAsync("log-button-clear");
            lines.Items.Clear();
            count.Text = "0 entries";
        };
        Content = dock;
    }
}

/// <summary>About SSM Connect, as the macOS About window: version, licence, project and release notes links, and the connection states legend.</summary>
public sealed class AboutWindow : Window
{
    static readonly string[] States =
    [
        "Disconnected: idle, not connected", "Authenticating: SSO sign-in", "Resolving: finding the instance by its tag",
        "Starting: starting a stopped workstation", "Waiting for SSM: waiting for the SSM agent",
        "Tunneling: starting the session and the plugin", "Connected: the tunnel is up", "Error: something failed",
    ];

    public AboutWindow(ShellController controller)
    {
        Title = "About SSM Connect";
        Width = 460;
        SizeToContent = SizeToContent.Height;
        var panel = new StackPanel { Margin = new Thickness(16) };
        panel.Children.Add(new TextBlock { Text = "SSM Connect", FontWeight = FontWeights.Bold, FontSize = 18 });
        var version = typeof(AboutWindow).Assembly.GetName().Version?.ToString(3) ?? "";
        panel.Children.Add(new TextBlock { Text = "Version " + version, Margin = new Thickness(0, 4, 0, 8) });
        foreach (var (id, label) in new[] { ("about-link-apache-license-2-0", "Apache License 2.0"), ("about-link-project", "Project"),
                                            ("about-link-release-notes", "Release Notes") })
        {
            var link = new Button { Content = label, HorizontalAlignment = HorizontalAlignment.Left, Margin = new Thickness(0, 2, 0, 2),
                                    Padding = new Thickness(8, 2, 8, 2) };
            AutomationProperties.SetAutomationId(link, id);
            link.Click += async (_, _) => await controller.TriggerAsync(id);
            panel.Children.Add(link);
        }
        var legend = new StackPanel();
        foreach (var state in States) legend.Children.Add(new TextBlock { Text = state });
        var expander = new Expander { Header = "Connection States", Content = legend, Margin = new Thickness(0, 8, 0, 0) };
        AutomationProperties.SetAutomationId(expander, "about-disclosuregroup-connection-states");
        panel.Children.Add(expander);
        Content = panel;
    }
}
