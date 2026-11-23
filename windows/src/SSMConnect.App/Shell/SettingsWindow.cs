using System.Text.Json;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Controls;

namespace SSMConnect.App.Shell;

/// <summary>
/// Profiles: the list comes from the helper, and saving, choosing, importing a profile file and
/// setting up VS Code each send one helper command. The window holds no profile rules; the core
/// validates and stores.
/// </summary>
public sealed class SettingsWindow : Window
{
    readonly ShellController controller;
    readonly Func<string?> chooseProfileFile;
    readonly ListBox list = new() { MinHeight = 120, DisplayMemberPath = "Name" };
    readonly Dictionary<string, TextBox> fields = [];
    static readonly (string Key, string Label)[] Editable =
    [
        ("name", "Name"), ("ssoStartUrl", "SSO start URL"), ("ssoRegion", "SSO region"), ("accountId", "Account"),
        ("roleName", "Role"), ("resourceRegion", "Region"), ("instanceTagKey", "Instance tag key"),
        ("instanceTagValue", "Instance tag value"), ("localPort", "Local port"), ("remotePort", "Remote port"),
    ];

    public SettingsWindow(ShellController controller, IShellPlatform platform, StartupRegistration? startup = null)
        : this(controller, platform.ChooseProfileFile, startup) { }

    public SettingsWindow(ShellController controller, Func<string?> chooseProfileFile, StartupRegistration? startup = null)
    {
        this.controller = controller;
        this.chooseProfileFile = chooseProfileFile;
        Title = "SSM Connect Settings";
        Width = 520;
        SizeToContent = SizeToContent.Height;
        var panel = new StackPanel { Margin = new Thickness(16) };
        panel.Children.Add(list);
        foreach (var (key, label) in Editable)
        {
            panel.Children.Add(new Label { Content = label });
            var box = new TextBox { Name = key };
            fields[key] = box;
            panel.Children.Add(box);
        }
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 12, 0, 0) };
        buttons.Children.Add(Button("Save", "save", Save));
        buttons.Children.Add(Button("Use This Profile", "use", Use));
        buttons.Children.Add(Button("Import File…", "import", Import));
        buttons.Children.Add(Button("Set Up VS Code", "editorSetup", async () => await controller.InstallEditorSetupAsync()));
        panel.Children.Add(buttons);
        var registration = startup ?? new StartupRegistration();
        var atLogin = new CheckBox { Content = "Start SSM Connect when I sign in", Name = "startAtLogin", Margin = new Thickness(0, 12, 0, 0),
                                     IsChecked = registration.IsEnabled };
        atLogin.Click += (_, _) => registration.SetEnabled(atLogin.IsChecked == true, Environment.ProcessPath ?? "SSMConnect.exe");
        panel.Children.Add(atLogin);
        Content = panel;
        list.SelectionChanged += (_, _) => Show(list.SelectedItem as ProfileRow);
        Loaded += async (_, _) => await ReloadAsync();
    }

    public sealed record ProfileRow(string Name, JsonObject Profile);

    static Button Button(string label, string name, Func<Task> action)
    {
        var button = new Button { Content = label, Name = name, Margin = new Thickness(0, 0, 8, 0), Padding = new Thickness(10, 4, 10, 4) };
        button.Click += async (_, _) => await action();
        return button;
    }

    /// <summary>
    /// Reloads the profiles from the helper, keeping the selected profile selected (or
    /// <paramref name="select"/>, such as the profile just saved) so Use acts on the same profile.
    /// </summary>
    public async Task ReloadAsync(string? select = null)
    {
        select ??= (string?)(list.SelectedItem as ProfileRow)?.Profile["id"];
        var result = await controller.ListProfilesAsync();
        list.Items.Clear();
        if (result.Value.TryGetValue("profiles", out var json) && JsonNode.Parse(json) is JsonArray profiles)
            foreach (var node in profiles.OfType<JsonObject>()) list.Items.Add(new ProfileRow((string?)node["name"] ?? "", node));
        list.SelectedItem = list.Items.OfType<ProfileRow>()
            .FirstOrDefault(row => select is not null && string.Equals((string?)row.Profile["id"], select, StringComparison.OrdinalIgnoreCase));
    }

    void Show(ProfileRow? row)
    {
        foreach (var (key, box) in fields) box.Text = row?.Profile[key]?.ToString() ?? "";
    }

    async Task Save()
    {
        var profile = (list.SelectedItem as ProfileRow)?.Profile.DeepClone().AsObject() ?? new JsonObject { ["id"] = Guid.NewGuid().ToString().ToUpperInvariant() };
        foreach (var (key, box) in fields)
            profile[key] = key is "localPort" or "remotePort" ? int.TryParse(box.Text, out var port) ? port : 8443 : box.Text;
        await controller.SaveProfileAsync(profile.ToJsonString());
        await ReloadAsync((string?)profile["id"]);
    }

    async Task Use()
    {
        if (list.SelectedItem is ProfileRow row && (string?)row.Profile["id"] is { } id) await controller.SetActiveProfileAsync(id);
    }

    async Task Import()
    {
        if (chooseProfileFile() is { } path) { await controller.ImportProfileAsync(path, attach: true); await ReloadAsync(); }
    }
}
