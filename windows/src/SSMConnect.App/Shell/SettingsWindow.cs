using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;

namespace SSMConnect.App.Shell;

/// <summary>
/// The settings window, laid out as the macOS one: startup, connection and clipboard settings, the
/// profiles with Use, and the add, import, duplicate, delete, file and edit actions. It holds no
/// connection rules: each control is named by its contracts/macos-parity.json id and asks the shell
/// controller, which offers and enables it as macOS does and sends its helper command.
/// </summary>
public sealed class SettingsWindow : Window
{
    readonly ShellController controller;
    readonly ListBox list = new() { MinHeight = 160, Margin = new Thickness(0, 4, 0, 4) };
    readonly CheckBox connectOnLaunch, autoReconnect;
    readonly TextBox clipboardSeconds;
    readonly MenuItem importMenu = Item("settings-menu-import-a-profile-from-aws-config", "Import from ~/.aws/config");
    readonly List<(FrameworkElement Element, string Id, bool Hide)> gated = [];

    public SettingsWindow(ShellController controller, IShellPlatform platform, StartupRegistration? startup = null)
    {
        this.controller = controller;
        Title = "SSM Connect Settings";
        Width = 680;
        Height = 620;
        var panel = new StackPanel { Margin = new Thickness(16) };

        panel.Children.Add(Heading("Startup"));
        var registration = startup ?? new StartupRegistration();
        var atLogin = Check("settings-toggle-launch-at-login", "Launch at login");
        atLogin.IsChecked = registration.IsEnabled;
        // Checked and Unchecked, not Click: UI Automation's Toggle, which screen readers use, raises no Click.
        void AtLoginChanged(object sender, RoutedEventArgs e) => registration.SetEnabled(atLogin.IsChecked == true, Environment.ProcessPath ?? "SSMConnect.exe");
        atLogin.Checked += AtLoginChanged;
        atLogin.Unchecked += AtLoginChanged;
        panel.Children.Add(atLogin);
        connectOnLaunch = Check("settings-toggle-connect-automatically-on-launch", "Connect automatically on launch");
        Toggled(connectOnLaunch);
        panel.Children.Add(connectOnLaunch);
        panel.Children.Add(Heading("Connection"));
        autoReconnect = Check("settings-toggle-reconnect-automatically-if-the-tunnel-drops", "Reconnect automatically if the tunnel drops");
        Toggled(autoReconnect);
        panel.Children.Add(autoReconnect);
        panel.Children.Add(Heading("Clipboard"));
        var clipboardRow = new StackPanel { Orientation = Orientation.Horizontal };
        clipboardRow.Children.Add(new TextBlock { Text = "Clear copied password after ", VerticalAlignment = VerticalAlignment.Center });
        clipboardSeconds = new TextBox { Width = 60, Text = "30" };
        AutomationProperties.SetAutomationId(clipboardSeconds, "settings-clipboard-auto-clear");
        clipboardSeconds.LostFocus += (_, _) =>
        {
            if (int.TryParse(clipboardSeconds.Text, out var seconds) && seconds is >= 0 and <= 600) Setting(clipboardSeconds, seconds.ToString());
        };
        clipboardRow.Children.Add(clipboardSeconds);
        clipboardRow.Children.Add(new TextBlock { Text = " seconds (0 keeps it until you replace it)", VerticalAlignment = VerticalAlignment.Center });
        panel.Children.Add(clipboardRow);

        panel.Children.Add(Heading("Profiles"));
        AutomationProperties.SetAutomationId(list, "profiles");
        list.SelectionChanged += (_, _) => Refresh();
        panel.Children.Add(list);

        var actions = new DockPanel { LastChildFill = false };
        var left = new StackPanel { Orientation = Orientation.Horizontal };
        left.Children.Add(Button("settings-button-add-a-blank-profile", "+", "Add a blank profile", false));
        importMenu.Click += async (_, e) =>
        {
            if (e.OriginalSource != importMenu) return;
            await controller.TriggerAsync(importMenu.Tag as string ?? "");
        };
        left.Children.Add(new Menu { Items = { importMenu }, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(4, 0, 4, 0) });
        left.Children.Add(Button("settings-button-duplicate-the-selected-profile", "Duplicate", "Duplicate the selected profile", false));
        left.Children.Add(Button("settings-button-delete-the-selected-profile", "−", "Delete the selected profile", false));
        DockPanel.SetDock(left, Dock.Left);
        actions.Children.Add(left);
        var right = new StackPanel { Orientation = Orientation.Horizontal };
        var files = Item("settings-menu-files", "Files");
        foreach (var (id, label, hide) in new[]
                 {
                     ("settings-button-open-profile-file", "Open Profile File…", false), ("settings-button-export-profile", "Export Profile…", false),
                     ("settings-button-save-a-local-copy", "Save a Local Copy", false), ("settings-button-reload-review-changes", "Reload / Review Changes", true),
                     ("settings-button-apply-external-changes", "Apply External Changes", true), ("settings-button-locate-file", "Locate File…", true),
                     ("settings-button-detach-keep-local-profile", "Detach (Keep Local Profile)", true),
                 })
        {
            var item = Item(id, label);
            item.Click += async (_, _) => await controller.TriggerAsync(id, SelectedArguments(), Context());
            gated.Add((item, id, hide));
            files.Items.Add(item);
        }
        right.Children.Add(new Menu { Items = { files }, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 0, 8, 0) });
        right.Children.Add(Button("settings-button-edit", "Edit…", null, false));
        DockPanel.SetDock(right, Dock.Right);
        actions.Children.Add(right);
        panel.Children.Add(actions);
        Content = new ScrollViewer { Content = panel, VerticalScrollBarVisibility = ScrollBarVisibility.Auto };

        controller.ProfilesChanged += OnProfilesChanged;
        controller.ImportableProfilesChanged += OnImportable;
        controller.DetailsChanged += OnDetails;
        Closed += (_, _) =>
        {
            controller.ProfilesChanged -= OnProfilesChanged;
            controller.ImportableProfilesChanged -= OnImportable;
            controller.DetailsChanged -= OnDetails;
        };
        Fill(null);
        Loaded += async (_, _) => await controller.ReloadProfilesAsync();
    }

    void OnProfilesChanged(string? select) => Dispatcher.BeginInvoke(() => Fill(select));
    void OnDetails() => Dispatcher.BeginInvoke(Refresh);

    void OnImportable(IReadOnlyList<JsonObject> profiles) => Dispatcher.BeginInvoke(() =>
    {
        importMenu.Items.Clear();
        foreach (var profile in profiles)
        {
            var item = Item("settings-button-profile-name", (string?)profile["name"] ?? "");
            var json = profile.ToJsonString();
            item.Click += async (_, _) => await controller.TriggerAsync("settings-button-profile-name", new Dictionary<string, string> { ["profile"] = json });
            importMenu.Items.Add(item);
        }
        if (profiles.Count == 0) importMenu.Items.Add(new MenuItem { Header = "No SSO profiles found in ~/.aws/config", IsEnabled = false });
        importMenu.IsSubmenuOpen = IsVisible;
    });

    /// <summary>The selected profile, or null.</summary>
    public JsonObject? Selected => (list.SelectedItem as ListBoxItem)?.Tag as JsonObject;

    JsonObject? Attachment(string? id) => controller.Files.OfType<JsonObject>().FirstOrDefault(f => id is not null && (string?)f["id"] == id);

    // The shell context the inventory's rules read for the selected profile.
    Dictionary<string, string> Context()
    {
        var file = Attachment((string?)Selected?["id"]);
        return new()
        {
            ["selected"] = Selected is null ? "false" : "true", ["selected.attached"] = file is null ? "false" : "true",
            ["selected.pending"] = (string?)file?["pending"] == "true" ? "true" : "false", ["profiles"] = controller.Profiles.Count.ToString(),
        };
    }

    Dictionary<string, string> SelectedArguments() =>
        Selected is { } profile ? new() { ["id"] = (string?)profile["id"] ?? "", ["profile"] = profile.ToJsonString() } : [];

    /// <summary>Fills the profile rows from the controller's profiles, keeping the selection (or selecting <paramref name="select"/>).</summary>
    void Fill(string? select)
    {
        select ??= (string?)Selected?["id"];
        list.Items.Clear();
        foreach (var profile in controller.Profiles.OfType<JsonObject>())
        {
            var id = (string?)profile["id"] ?? "";
            var row = new DockPanel { LastChildFill = true };
            var use = new Button { Content = "Use", Padding = new Thickness(10, 2, 10, 2), Margin = new Thickness(8, 0, 0, 0) };
            AutomationProperties.SetAutomationId(use, "settings-button-use");
            var item = new Dictionary<string, string> { ["item.active"] = id == controller.ActiveProfileId ? "true" : "false" };
            use.Visibility = controller.IsOffered("settings-button-use", item) ? Visibility.Visible : Visibility.Collapsed;
            use.Click += async (_, _) => await controller.TriggerAsync("settings-button-use", new Dictionary<string, string> { ["id"] = id }, item);
            DockPanel.SetDock(use, Dock.Right);
            row.Children.Add(use);
            var attached = Attachment(id) is null ? "" : "  (attached to a profile file)";
            row.Children.Add(new TextBlock
            {
                Text = $"{(string?)profile["name"]}  ·  {(string?)profile["accountId"]} · {(string?)profile["resourceRegion"]}{attached}",
                VerticalAlignment = VerticalAlignment.Center,
            });
            var entry = new ListBoxItem { Content = row, Tag = profile, HorizontalContentAlignment = HorizontalAlignment.Stretch };
            list.Items.Add(entry);
            if (select is not null && string.Equals(id, select, StringComparison.OrdinalIgnoreCase)) list.SelectedItem = entry;
        }
        var settings = controller.AppSettings;
        filling = true;
        connectOnLaunch.IsChecked = (string?)settings["connectOnLaunch"] == "true";
        autoReconnect.IsChecked = (string?)settings["autoReconnect"] != "false";
        clipboardSeconds.Text = settings["clipboardAutoClearSeconds"]?.ToString() ?? "30";
        filling = false;
        Refresh();
    }

    // Shows and enables each control as macOS does for the selected profile.
    void Refresh()
    {
        var context = Context();
        foreach (var (element, id, hide) in gated)
        {
            if (hide) element.Visibility = controller.IsOffered(id, context) ? Visibility.Visible : Visibility.Collapsed;
            element.IsEnabled = controller.IsEnabled(id, context);
        }
    }

    bool filling;

    // A setting checkbox saves its value when the user toggles it, not when the window shows the stored value.
    void Toggled(CheckBox box)
    {
        void Changed(object sender, RoutedEventArgs e) { if (!filling) Setting(box, box.IsChecked == true ? "true" : "false"); }
        box.Checked += Changed;
        box.Unchecked += Changed;
    }

    void Setting(FrameworkElement control, string value) =>
        _ = controller.TriggerAsync(AutomationProperties.GetAutomationId(control), new Dictionary<string, string> { ["value"] = value });

    Button Button(string id, string label, string? tooltip, bool hide)
    {
        var button = new Button { Content = label, Margin = new Thickness(0, 0, 6, 0), Padding = new Thickness(10, 4, 10, 4), MinWidth = 32 };
        if (tooltip is not null) { button.ToolTip = tooltip; AutomationProperties.SetName(button, tooltip); }
        AutomationProperties.SetAutomationId(button, id);
        button.Click += async (_, _) => await controller.TriggerAsync(id, SelectedArguments(), Context());
        gated.Add((button, id, hide));
        return button;
    }

    static MenuItem Item(string id, string label)
    {
        var item = new MenuItem { Header = label, Tag = id };
        AutomationProperties.SetAutomationId(item, id);
        return item;
    }

    static CheckBox Check(string id, string label)
    {
        var box = new CheckBox { Content = label, Margin = new Thickness(0, 2, 0, 2) };
        AutomationProperties.SetAutomationId(box, id);
        return box;
    }

    static TextBlock Heading(string text) => new() { Text = text, FontWeight = FontWeights.Bold, Margin = new Thickness(0, 10, 0, 4) };
}
