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

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        instance = SingleInstance.TryAcquire("SSMConnect-" + Environment.UserName);
        if (instance is null) { Shutdown(); return; }
        var helperPath = Path.Combine(AppContext.BaseDirectory, "SSMConnectHelper.exe");
        host = new HelperHost(new JobHelperSpawner(helperPath), HelperBuild.Current, HelperHostLimits.Default, TimeProvider.System);
        tray = new TrayIcon();
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
        var state = controller.States.GetValueOrDefault("desktop", "Disconnected");
        var tooltip = host.Status is HelperHostStatus.Ready ? TrayIcons.Tooltip(state) : host.StatusMessage ?? "Starting…";
        tray.Update(TrayIcons.For(host.Status is HelperHostStatus.Ready ? state : "Error"), "SSM Connect: " + tooltip);
    }

    void ShowSettings()
    {
        if (controller is null) return;
        new SettingsWindow(controller, () =>
        {
            var dialog = new OpenFileDialog { Filter = "SSM Connect profiles|*.ssmconnect;*.yaml;*.yml;*.json" };
            return dialog.ShowDialog() == true ? dialog.FileName : null;
        }).Show();
    }

    void Quit()
    {
        tray?.Dispose();
        instance?.Dispose();
        Shutdown();
    }
}

/// <summary>The build this shell and its helper share; the release job stamps both.</summary>
static class HelperBuild
{
    public const string Current = "dev";
}
