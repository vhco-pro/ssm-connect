using System.IO;
using System.Windows;
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
    readonly SingleWindow<LogWindow> log = new();
    readonly SingleWindow<AboutWindow> about = new();
    WindowsShellPlatform? platform;

    protected override async void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        instance = SingleInstance.TryAcquire("SSMConnect-" + Environment.UserName);
        if (instance is null) { Shutdown(); return; }
        var helperPath = Path.Combine(AppContext.BaseDirectory, "SSMConnectHelper.exe");
        host = new HelperHost(new JobHelperSpawner(helperPath), HelperBuild.Current, HelperHostLimits.Default, TimeProvider.System);
        tray = new TrayIcon();
        sessionEnd = new SessionEndWindow(() => { StopHelper(); Shutdown(); });
        platform = new WindowsShellPlatform(
            notify: (title, body) => tray.ShowNotification(title, body, TrayNotificationKind.Information),
            showError: (action, message) => tray.ShowNotification(action, message, TrayNotificationKind.Error),
            clipboardClearSeconds: () => int.TryParse((string?)controller?.AppSettings["clipboardAutoClearSeconds"], out var seconds) ? seconds : 30);
        controller = new ShellController(host, platform);
        menu = TrayMenu.Build(controller, ShowSettings, () => _ = host.RetryAsync(), Quit);
        var shell = controller;
        shell.ShowAboutRequested += () => about.Show(() => new AboutWindow(shell));
        shell.ShowLogRequested += entries => { log.Current?.Close(); log.Show(() => new LogWindow(shell, entries)); };
        shell.EditProfileRequested += draft =>
        {
            var attached = draft is not null && shell.Files.OfType<System.Text.Json.Nodes.JsonObject>().Any(f => (string?)f["id"] == (string?)draft["id"]);
            new ProfileEditorWindow(shell, draft ?? [], attached).Show();
        };
        shell.StateChanged += () => Dispatcher.Invoke(UpdateTray);
        host.StatusChanged += () => Dispatcher.Invoke(UpdateTray);
        tray.ContextMenuRequested += () => { menu.IsOpen = true; };
        // A click on the tray icon is Connect, as the first macOS action, when macOS would offer it.
        tray.PrimaryActionRequested += () => _ = shell.TriggerAsync("menucontent-button-machine-actiontitle");
        instance.Activated += () => Dispatcher.Invoke(ShowSettings);
        // After a sleep the helper checks its connections, as macOS does on its wake notification.
        Microsoft.Win32.SystemEvents.PowerModeChanged += OnPowerModeChanged;
        UpdateTray();
        await host.StartAsync();
    }

    void OnPowerModeChanged(object? sender, Microsoft.Win32.PowerModeChangedEventArgs e) => controller?.PowerModeChanged(e.Mode);

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
        if (platform is null) return;
        var shell = controller;
        var windows = platform;
        settings.Show(() => new SettingsWindow(shell, windows));
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
        // SystemEvents holds its handlers statically: detach before the shell goes away.
        Microsoft.Win32.SystemEvents.PowerModeChanged -= OnPowerModeChanged;
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
