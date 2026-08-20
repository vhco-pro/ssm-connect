using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;
using SSMConnect.Aws;
using SSMConnect.Domain;
using SSMConnect.Windows;
using SSMConnect.Workflow;

namespace SSMConnect.App;

/// <summary>
/// The composition root and the notification-area shell.
/// </summary>
/// <remarks>
/// The shell observes workflow state and issues commands. It does not reproduce connection rules:
/// every decision about when to connect, retry, or give up belongs to <see cref="ConnectionWorkflow"/>,
/// and everything here is a reaction to an event that workflow published.
/// </remarks>
public partial class App : System.Windows.Application
{
    private readonly ProfileStore _store = new();
    private readonly StartupRegistration _startup = new();
    private readonly ConnectionLog _log = new();
    private ClipboardPolicy _clipboard = null!;
    private TrayIcon _tray = null!;
    private ContextMenu _menu = null!;
    private ConnectionWorkflow? _workflow;
    private StoredState _state = null!;
    private string? _password;
    private SettingsWindow? _settingsWindow;
    private LogWindow? _logWindow;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        DispatcherUnhandledException += (_, args) =>
        {
            _tray?.ShowNotification("SSM Connect hit an unexpected problem",
                args.Exception.Message, TrayNotificationKind.Error);
            args.Handled = true;
        };

        _clipboard = new ClipboardPolicy(
            value => Dispatcher.Invoke(() => System.Windows.Clipboard.SetText(value)),
            () => Dispatcher.Invoke(System.Windows.Clipboard.Clear));

        _state = _store.Load();

        _menu = new ContextMenu();
        _tray = new TrayIcon();
        _tray.PrimaryActionRequested += PrimaryAction;
        _tray.ContextMenuRequested += () => TrayMenuPlacement.ShowAtCursor(_menu);

        RebuildWorkflow();

        // The workflow owns launch policy, including whether auto-connect applies.
        _workflow?.OnLaunch();

        SystemEvents.PowerModeChanged += OnPowerModeChanged;
        SystemEvents.SessionEnding += OnSessionEnding;
    }

    private ConnectionProfile? ActiveProfile =>
        _state.Profiles.FirstOrDefault(profile => profile.Id == _state.ActiveProfileId)
        ?? _state.Profiles.FirstOrDefault();

    // MARK: Composition

    private void RebuildWorkflow()
    {
        if (ActiveProfile is not ConnectionProfile profile)
        {
            _workflow = null;
            UpdateTray(ConnectionState.Disconnected);
            return;
        }

        _workflow = new ConnectionWorkflow(
            new SsoAuthProvider(OpenInBrowser),
            new Ec2Adapter(),
            new SsmAdapter(),
            new SecretsAdapter(),
            new StsIdentityAdapter(),
            new WorkstationAgentClient(),
            new PluginTunnelProvider(),
            new LoopbackReadinessProbe(),
            new DcvViewerLauncher(),
            new FileInstanceIdStore(),
            new RealDelay(),
            new ShellEventSink(this),
            profile,
            _state.Settings);

        UpdateTray(_workflow.State);
    }

    private static void OpenInBrowser(string uri) =>
        Process.Start(new ProcessStartInfo { FileName = uri, UseShellExecute = true })?.Dispose();

    // MARK: Tray

    /// <summary>
    /// Rebuilds the menu for a state. Items are enabled by what the workflow can currently do, so
    /// the menu never offers an action that would be a no-op.
    /// </summary>
    private void RebuildMenu(ConnectionState state)
    {
        _menu.Items.Clear();

        bool configured = ActiveProfile?.IsConfigured == true;
        bool connected = state == ConnectionState.Connected;
        bool busy = state.IsTransitioning();

        _menu.Items.Add(new MenuItem { Header = TrayIcons.Tooltip(state), IsEnabled = false });
        _menu.Items.Add(new Separator());

        if (connected || busy)
        {
            _menu.Items.Add(Item("Disconnect", () => _workflow?.Disconnect()));
            _menu.Items.Add(Item("Reconnect", () => _workflow?.Reconnect(), enabled: connected));
            _menu.Items.Add(Item("Stop workstation", () => _workflow?.StopWorkstation(), enabled: connected));
        }
        else
        {
            _menu.Items.Add(Item("Connect", () => _workflow?.Connect(), enabled: configured));
        }

        if (_password is not null)
        {
            _menu.Items.Add(new MenuItem
            {
                Header = $"Password: {new string('•', Math.Min(_password.Length, 12))}",
                IsEnabled = false,
            });
            _menu.Items.Add(Item("Copy password", CopyPassword));
        }

        _menu.Items.Add(new Separator());

        if (_state.Profiles.Count > 1)
        {
            var chooser = new MenuItem { Header = "Workstation" };
            foreach (ConnectionProfile profile in _state.Profiles)
            {
                Guid id = profile.Id;
                var entry = new MenuItem
                {
                    Header = profile.Name,
                    IsChecked = id == ActiveProfile?.Id,
                    // Switching target mid-connection would swap the workstation out from under an
                    // active tunnel, so it is only offered while idle.
                    IsEnabled = !connected && !busy,
                };
                entry.Click += (_, _) => SetActiveProfile(id);
                chooser.Items.Add(entry);
            }

            _menu.Items.Add(chooser);
        }

        var startAtSignIn = new MenuItem { Header = "Start at sign-in", IsChecked = _startup.IsEnabled };
        startAtSignIn.Click += (_, _) =>
        {
            _startup.SetEnabled(!_startup.IsEnabled);
            RebuildMenu(_workflow?.State ?? ConnectionState.Disconnected);
        };
        _menu.Items.Add(startAtSignIn);

        _menu.Items.Add(Item("Show log", ShowLog));
        _menu.Items.Add(Item("Settings…", ShowSettings));
        _menu.Items.Add(new Separator());
        _menu.Items.Add(Item("Quit SSM Connect", Quit));
    }

    private static MenuItem Item(string header, Action onClick, bool enabled = true)
    {
        var item = new MenuItem { Header = header, IsEnabled = enabled };
        item.Click += (_, _) => onClick();
        return item;
    }

    private void PrimaryAction()
    {
        if (_workflow is null)
        {
            ShowSettings();
            return;
        }

        if (_workflow.State == ConnectionState.Connected)
        {
            _workflow.Disconnect();
        }
        else if (!_workflow.State.IsTransitioning())
        {
            _workflow.Connect();
        }
    }

    private void UpdateTray(ConnectionState state)
    {
        string detail = ActiveProfile is { } profile ? $" — {profile.Name}" : string.Empty;
        _tray.Update(TrayIcons.For(state), $"{TrayIcons.Tooltip(state)}{detail}");
        RebuildMenu(state);
    }

    private void CopyPassword()
    {
        if (_password is string password)
        {
            _clipboard.Copy(password, _state.Settings.ClipboardAutoClearSeconds);
            _tray.ShowNotification("Password copied",
                _state.Settings.ClipboardAutoClearSeconds > 0
                    ? $"The clipboard clears in {_state.Settings.ClipboardAutoClearSeconds} seconds."
                    : "Auto-clear is disabled in Settings.",
                TrayNotificationKind.Information);
        }
    }

    // MARK: Settings

    private void ShowLog()
    {
        if (_logWindow is { IsLoaded: true })
        {
            _logWindow.Activate();
            return;
        }

        _logWindow = new LogWindow(_log);
        _logWindow.Closed += (_, _) => _logWindow = null;
        _logWindow.Show();
        _logWindow.Activate();
    }

    private void ShowSettings()
    {
        if (_settingsWindow is { IsLoaded: true })
        {
            _settingsWindow.Activate();
            return;
        }

        _settingsWindow = new SettingsWindow(_state, Persist);
        _settingsWindow.Closed += (_, _) => _settingsWindow = null;
        _settingsWindow.Show();
        _settingsWindow.Activate();
    }

    private void Persist(StoredState updated)
    {
        _state = updated;
        _store.Save(updated);

        // A profile edit takes effect on the next connection; the workflow refuses to swap targets
        // while one is in flight, so rebuilding it is only safe while idle.
        bool idle = _workflow is null
            || (!_workflow.State.IsTransitioning() && _workflow.State != ConnectionState.Connected);

        if (idle)
        {
            RebuildWorkflow();
        }
        else
        {
            _workflow!.Apply(ActiveProfile ?? _workflow.Profile, updated.Settings);
            UpdateTray(_workflow.State);
        }
    }

    private void SetActiveProfile(Guid id) => Persist(_state with { ActiveProfileId = id });

    // MARK: Lifecycle

    private void OnPowerModeChanged(object sender, PowerModeChangedEventArgs e)
    {
        if (e.Mode == PowerModes.Resume && _workflow is not null)
        {
            // The plugin survives sleep but its data channel does not, so a tunnel can look
            // connected while the viewer has already dropped. The workflow health-checks it.
            _ = _workflow.HandleSystemWakeAsync();
        }
    }

    private void OnSessionEnding(object sender, SessionEndingEventArgs e) => ShutdownCleanly();

    private void Quit()
    {
        ShutdownCleanly();
        Shutdown();
    }

    /// <summary>
    /// Graceful teardown, which also closes the SSM session server-side. Killing the process would
    /// leave that session reported as connected until it timed out.
    /// </summary>
    private void ShutdownCleanly()
    {
        _clipboard.Cancel();
        try
        {
            _workflow?.ShutdownAsync().Wait(TimeSpan.FromSeconds(8));
        }
        catch (Exception)
        {
            // The Job Object is the backstop if the graceful path cannot finish in time.
        }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        SystemEvents.PowerModeChanged -= OnPowerModeChanged;
        SystemEvents.SessionEnding -= OnSessionEnding;
        _tray?.Dispose();
        base.OnExit(e);
    }

    /// <summary>Turns workflow events into shell behavior. The workflow never does any of this itself.</summary>
    private sealed class ShellEventSink(App app) : IEventSink
    {
        public void StateChanged(ConnectionState state)
        {
            if (state is ConnectionState.Disconnected or ConnectionState.Error)
            {
                app._password = null;
            }

            app.Dispatcher.Invoke(() => app.UpdateTray(state));

            if (state == ConnectionState.Error)
            {
                app.Dispatcher.Invoke(() => app._tray.ShowNotification("Connection failed",
                    app._workflow?.ErrorMessage ?? "The connection could not be established.",
                    TrayNotificationKind.Error));
            }
        }

        public void Log(string category, string message)
        {
            Debug.WriteLine($"[{category}] {message}");
            app._log.Append(category, message);
        }

        public void Notify(ConnectionNotification notification)
        {
            (string title, string body, TrayNotificationKind kind) = notification switch
            {
                ConnectionNotification.Connected =>
                    ("Workstation connected", "Amazon DCV should open shortly.", TrayNotificationKind.Information),
                ConnectionNotification.Reconnecting =>
                    ("Reconnecting", "The tunnel dropped; re-establishing it.", TrayNotificationKind.Warning),
                ConnectionNotification.Stopped =>
                    ("Workstation stopping", "The instance is shutting down.", TrayNotificationKind.Information),
                ConnectionNotification.SignInRequired =>
                    ("Sign-in required", "Your AWS session expired; check your browser.", TrayNotificationKind.Warning),
                _ => ("SSM Connect", string.Empty, TrayNotificationKind.Information),
            };

            app.Dispatcher.Invoke(() => app._tray.ShowNotification(title, body, kind));
        }

        /// <summary>
        /// The workflow reports the password; the decision to put it on a clipboard is the shell's,
        /// and it is deliberately not automatic — the user asks for it from the menu.
        /// </summary>
        public void PasswordAvailable(string password)
        {
            app._password = password;
            app.Dispatcher.Invoke(() => app.RebuildMenu(app._workflow?.State ?? ConnectionState.Connected));
        }
    }
}
