using System.Text.Json.Nodes;
using System.Windows;

namespace SSMConnect.App.Shell;

/// <summary>The profile editor, with the macOS editor's fields.</summary>
public sealed class ProfileEditorWindow : Window
{
    public ProfileEditorWindow(ShellController controller, JsonObject draft, bool attached) { Title = "Profile"; }
}

/// <summary>The connection log, as the macOS Log window shows it.</summary>
public sealed class LogWindow : Window
{
    public LogWindow(ShellController controller, IReadOnlyList<JsonObject> entries) { Title = "SSM Connect Log"; }
}

/// <summary>About SSM Connect, as the macOS About window.</summary>
public sealed class AboutWindow : Window
{
    public AboutWindow(ShellController controller) { Title = "About SSM Connect"; }
}
