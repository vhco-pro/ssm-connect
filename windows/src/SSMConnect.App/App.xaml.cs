using System.IO;
using System.Windows;
using Microsoft.Win32;
using SSMConnect.App.Helper;
using SSMConnect.App.Shell;

namespace SSMConnect.App;

/// <summary>
/// The SSM Connect Windows shell: a tray icon whose menu sends each action to the private helper,
/// which owns every connection rule. One shell per user session; the helper runs in its own job.
/// </summary>
public partial class App : Application
{
    SingleInstance? instance;
    HelperHost? host;
    ShellController? controller;
    TrayIcon? tray;
    System.Windows.Controls.ContextMenu? menu;
    SessionEndWindow? sessionEnd;
    readonly SingleWindow<SettingsWindow> settings = new();

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        instance = SingleInstance.TryAcquire("SSMConnect-" + Environment.UserName);
        if (instance is null) { Shutdown(); return; }
        var helperPath = Path.Combine(AppContext.BaseDirectory, "SSMConnectHelper.exe");
        host = new HelperHost(new JobHelperSpawner(helperPath), HelperBuild.Current, HelperHostLimits.Default, TimeProvider.System);
        tray = new TrayIcon();
        sessionEnd = new SessionEndWindow(() => { StopHelper(); Shutdown(); });
        var platform = new WindowsShellPlatform(
            notify: (title, body) => tray.ShowNotification(title, body, TrayNotificationKind.Information),
            showError: (action, message) => tray.ShowNotification(action, message, TrayNotificationKind.Error),
            clipboardClearSeconds: () => 30);
        controller = new ShellController(host, platform);
        menu = TrayMenu.Build(controller, ShowSettings, () => _ = host.RetryAsync(), Quit);
        controller.StateChanged += () => Dispatcher.Invoke(UpdateTray);
        host.StatusChanged += () => Dispatcher.Invoke(UpdateTray);
        tray.ContextMenuRequested += () => { menu.IsOpen = true; };
        tray.PrimaryActionRequested += () => _ = controller.RunAsync(ShellController.MenuActions[1]);
        instance.Activated += () => Dispatcher.Invoke(ShowSettings);
        UpdateTray();
        await host.StartAsync();
    }

    void UpdateTray()
    {
        if (tray is null || host is null || controller is null) return;
        var states = controller.States;
        var state = states.GetValueOrDefault("desktop", "Disconnected");
        var signInRequired = states.GetValueOrDefault("authorization") == "signInRequired";
        var tooltip = host.Status is not HelperHostStatus.Ready ? host.StatusMessage ?? "Starting…"
            : signInRequired ? "Sign in required" : TrayIcons.Tooltip(state);
        tray.Update(TrayIcons.For(host.Status is HelperHostStatus.Ready ? state : "Error"), "SSM Connect: " + tooltip);
    }

    void ShowSettings()
    {
        if (controller is null) return;
        var shell = controller;
        settings.Show(() => new SettingsWindow(shell, () =>
        {
            var dialog = new OpenFileDialog { Filter = "SSM Connect profiles|*.ssmconnect;*.yaml;*.yml;*.json" };
            return dialog.ShowDialog() == true ? dialog.FileName : null;
        }));
    }

    void Quit()
    {
        StopHelper();
        Shutdown();
    }

    /// <summary>
    /// Ends the helper cleanly before the shell exits: it cancels its running commands and ends its
    /// connections, and its job is emptied after a short grace. Runs off the dispatcher, because the
    /// installer's close request arrives on it and waits for this to finish.
    /// </summary>
    void StopHelper()
    {
        if (helperStopped) return;
        helperStopped = true;
        if (host is { } running) Task.Run(() => running.ShutdownAsync(TimeSpan.FromSeconds(5))).Wait(TimeSpan.FromSeconds(10));
        tray?.Dispose();
        instance?.Dispose();
    }

    bool helperStopped;

    /// <summary>
    /// WPF ends the application itself when Windows ends the session: it raises SessionEnding at
    /// WM_QUERYENDSESSION and shuts down right away, before any WM_ENDSESSION arrives. So every exit
    /// stops the helper first, letting it end its connections and remove its keys and leases.
    /// </summary>
    protected override void OnExit(ExitEventArgs e)
    {
        StopHelper();
        base.OnExit(e);
    }
}

/// <summary>
/// The build this shell and its helper share. The release build passes it as the
/// <c>SSMConnectBuild</c> MSBuild property, recorded as assembly metadata; a development build is "dev".
/// </summary>
static class HelperBuild
{
    public static string Current { get; } =
        typeof(HelperBuild).Assembly.GetCustomAttributes(typeof(System.Reflection.AssemblyMetadataAttribute), false)
            .OfType<System.Reflection.AssemblyMetadataAttribute>()
            .FirstOrDefault(attribute => attribute.Key == "SSMConnectBuild")?.Value ?? "dev";
}
