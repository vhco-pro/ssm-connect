using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;
using MessageBox = System.Windows.MessageBox;
using OpenFileDialog = Microsoft.Win32.OpenFileDialog;
using SaveFileDialog = Microsoft.Win32.SaveFileDialog;
using SSMConnect.Aws;
using SSMConnect.Domain;
using SSMConnect.Windows;
using SSMConnect.Workflow;

namespace SSMConnect.App;

/// <summary>
/// Profile management, application settings, and portable import and export.
/// </summary>
/// <remarks>
/// Validation here mirrors the domain rules rather than inventing its own, so a profile the editor
/// accepts is one the workflow's pre-flight will also accept. The alternative — letting a bad region
/// through and surfacing it as a connection failure — is exactly what the pre-flight guard exists
/// to avoid.
/// </remarks>
public partial class SettingsWindow : Window
{
    private readonly Action<StoredState> _persist;
    private readonly ProfileLibrary _library;
    private readonly IProfileFiles _files;
    private readonly System.Windows.Threading.DispatcherTimer _fileTimer = new() { Interval = TimeSpan.FromSeconds(2) };
    private List<ConnectionProfile> _profiles => _library.Profiles;
    private AppSettings _settings;
    private Guid? _activeId;
    private bool _loading;
    private ProfileFileRevision? _editingRevision;

    public SettingsWindow(StoredState state, Action<StoredState> persist, IProfileFiles files,
        IReadOnlySet<string> supported)
    {
        InitializeComponent();
        _persist = persist;
        _files = files;
        _library = new ProfileLibrary(state.Profiles, files, supported, state.Documents, state.Attachments);
        _settings = state.Settings;
        _activeId = state.ActiveProfileId ?? state.Profiles.FirstOrDefault()?.Id;

        LoadSettings();
        RefreshList(_activeId);
        _fileTimer.Tick += (_, _) => { _library.Refresh(); UpdateFileStatus(); };
        _fileTimer.Start();
        Closed += (_, _) => _fileTimer.Stop();
    }

    private ConnectionProfile? Selected => ProfileList.SelectedItem as ConnectionProfile;

    private void RefreshList(Guid? select)
    {
        ProfileList.ItemsSource = null;
        ProfileList.ItemsSource = _profiles;
        ProfileList.SelectedItem = _profiles.FirstOrDefault(profile => profile.Id == select) ?? _profiles.FirstOrDefault();
        RemoveButton.IsEnabled = _profiles.Count > 0;
        ExportButton.IsEnabled = _profiles.Count > 0;
        Editor.IsEnabled = _profiles.Count > 0;
    }

    private void LoadSettings()
    {
        AutoConnectBox.IsChecked = _settings.AutoConnect;
        AutoReconnectBox.IsChecked = _settings.AutoReconnect;
        ClipboardSecondsBox.Text = _settings.ClipboardAutoClearSeconds.ToString(CultureInfo.InvariantCulture);
    }

    private void OnProfileSelected(object sender, SelectionChangedEventArgs e)
    {
        if (Selected is not ConnectionProfile profile)
        {
            return;
        }

        _loading = true;
        NameBox.Text = profile.Name;
        StartUrlBox.Text = profile.SsoStartUrl;
        SsoRegionBox.Text = profile.SsoRegion;
        ResourceRegionBox.Text = profile.ResourceRegion;
        AccountBox.Text = profile.AccountId;
        RoleBox.Text = profile.RoleName;
        TagKeyBox.Text = profile.InstanceTagKey;
        TagValueBox.Text = profile.InstanceTagValue;
        ModeBox.SelectedIndex = profile.ResolvedConnectMode == ConnectMode.MultiUser ? 1 : 0;
        SecretBox.Text = profile.SecretId ?? string.Empty;
        LocalPortBox.Text = profile.LocalPort.ToString(CultureInfo.InvariantCulture);
        RemotePortBox.Text = profile.RemotePort.ToString(CultureInfo.InvariantCulture);
        AgentPortBox.Text = profile.ResolvedAgentRemotePort.ToString(CultureInfo.InvariantCulture);
        _loading = false;

        UpdateModeVisibility();
        ValidationText.Text = string.Empty;
        OpenDcvBox.IsChecked = profile.ConnectAction == ConnectAction.DcvViewer;
        _editingRevision = _library.Attachments.GetValueOrDefault(profile.Id)?.Revision;
        UpdateFileStatus();
    }

    private void OnModeChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!_loading)
        {
            UpdateModeVisibility();
        }
    }

    /// <summary>
    /// A multi-user workstation authenticates by identity and has no shared password, so offering a
    /// secret field there would invite a profile the schema rejects.
    /// </summary>
    private void UpdateModeVisibility()
    {
        bool multiUser = ModeBox.SelectedIndex == 1;
        SecretPanel.Visibility = multiUser ? Visibility.Collapsed : Visibility.Visible;
        AgentPortBox.IsEnabled = multiUser;
    }

    private void OnAdd(object sender, RoutedEventArgs e)
    {
        var created = new ConnectionProfile
        {
            Id = Guid.NewGuid(),
            Name = "New workstation",
            SsoStartUrl = string.Empty,
            SsoRegion = string.Empty,
            AccountId = string.Empty,
            RoleName = string.Empty,
            ResourceRegion = string.Empty,
            InstanceTagKey = "Name",
            InstanceTagValue = string.Empty,
            LocalPort = 8443,
            RemotePort = 8443,
        };

        _profiles.Add(created);
        RefreshList(created.Id);
    }

    /// <summary>
    /// Creates a profile from an IAM Identity Center entry in the shared AWS config (XP-02).
    /// </summary>
    /// <remarks>
    /// The config supplies the SSO endpoints, account, role and region; it has no concept of which
    /// workstation to target or which secret holds its password, so those stay empty and the editor
    /// opens on the new profile rather than saving something that looks complete and cannot connect.
    /// </remarks>
    private void OnFromAwsConfig(object sender, RoutedEventArgs e)
    {
        IReadOnlyList<DiscoveredSsoProfile> discovered;
        try
        {
            discovered = SsoProfileDiscovery.Discover();
        }
        catch (Exception error)
        {
            MessageBox.Show(this, error.Message, "Could not read your AWS config",
                MessageBoxButton.OK, MessageBoxImage.Warning);
            return;
        }

        if (discovered.Count == 0)
        {
            MessageBox.Show(this,
                "No IAM Identity Center profiles were found in your AWS config. Run 'aws configure sso' first.",
                "No SSO profiles found", MessageBoxButton.OK, MessageBoxImage.Information);
            return;
        }

        var chooser = new SsoProfileChooser(discovered) { Owner = this };
        if (chooser.ShowDialog() != true || chooser.Selected is not DiscoveredSsoProfile chosen)
        {
            return;
        }

        ConnectionProfile created = chosen.ToConnectionProfile();
        _profiles.Add(created);
        _activeId = created.Id;
        RefreshList(_activeId);
        ValidationText.Text = "Set the instance tag value for this workstation, then save.";
    }

    private void OnRemove(object sender, RoutedEventArgs e)
    {
        if (Selected is not ConnectionProfile profile)
        {
            return;
        }

        if (MessageBox.Show(this, $"Remove \"{profile.Name}\"?", "SSM Connect",
                MessageBoxButton.OKCancel, MessageBoxImage.Warning) != MessageBoxResult.OK)
        {
            return;
        }

        _library.Remove(profile.Id);
        if (_activeId == profile.Id)
        {
            _activeId = _profiles.FirstOrDefault()?.Id;
        }

        RefreshList(_activeId);
    }

    /// <summary>Builds a profile from the editor, reporting the first problem rather than all of them.</summary>
    private ConnectionProfile? ReadEditor(out string? error)
    {
        error = null;
        if (Selected is not ConnectionProfile original)
        {
            error = "Select a workstation first.";
            return null;
        }

        string ssoRegion = AwsRegion.Normalize(SsoRegionBox.Text);
        string resourceRegion = AwsRegion.Normalize(ResourceRegionBox.Text);

        if (NameBox.Text.Trim().Length == 0)
        {
            error = "Give the workstation a display name.";
        }
        else if (!AwsRegion.IsValid(ssoRegion))
        {
            error = $"The SSO region \"{ssoRegion}\" is not a valid AWS region.";
        }
        else if (!AwsRegion.IsValid(resourceRegion))
        {
            error = $"The resource region \"{resourceRegion}\" is not a valid AWS region.";
        }
        else if (!TryPort(LocalPortBox.Text, out int localPort))
        {
            error = "The local port must be between 1 and 65535.";
        }
        else if (!TryPort(RemotePortBox.Text, out int remotePort))
        {
            error = "The remote port must be between 1 and 65535.";
        }
        else if (!TryPort(AgentPortBox.Text, out int agentPort))
        {
            error = "The agent port must be between 1 and 65535.";
        }
        else
        {
            bool multiUser = ModeBox.SelectedIndex == 1;
            return original with
            {
                Name = NameBox.Text.Trim(),
                SsoStartUrl = StartUrlBox.Text.Trim(),
                SsoRegion = ssoRegion,
                AccountId = AccountBox.Text.Trim(),
                RoleName = RoleBox.Text.Trim(),
                ResourceRegion = resourceRegion,
                InstanceTagKey = TagKeyBox.Text.Trim(),
                InstanceTagValue = TagValueBox.Text.Trim(),
                ConnectMode = multiUser ? ConnectMode.MultiUser : ConnectMode.SingleUser,
                SecretId = multiUser || SecretBox.Text.Trim().Length == 0 ? null : SecretBox.Text.Trim(),
                LocalPort = localPort,
                RemotePort = remotePort,
                AgentRemotePort = multiUser ? agentPort : original.AgentRemotePort,
                ConnectAction = OpenDcvBox.IsChecked == true ? ConnectAction.DcvViewer : ConnectAction.TunnelOnly,
            };
        }

        return null;
    }

    private static bool TryPort(string text, out int port) =>
        int.TryParse(text.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out port)
        && port is >= 1 and <= 65535;

    private void OnSave(object sender, RoutedEventArgs e)
    {
        if (!TrySettings(out AppSettings settings, out string? settingsError))
        {
            ValidationText.Text = settingsError;
            return;
        }
        if (_profiles.Count > 0)
        {
            ConnectionProfile? updated = ReadEditor(out string? error);
            if (updated is null)
            {
                ValidationText.Text = error;
                return;
            }

            try
            {
                bool consent = CanonicalConsent(updated.Id);
                if (!consent) { return; }
                _library.SaveProfile(updated, _editingRevision, consent);
            }
            catch (Exception failure) when (FileFailure(failure))
            {
                ShowFileError(failure);
                return;
            }
            _activeId = updated.Id;
        }

        _settings = settings;
        ValidationText.Text = string.Empty;
        FileOperation(() => { Persist(); RefreshList(_activeId); });
    }

    private bool TrySettings(out AppSettings settings, out string? error)
    {
        settings = _settings;
        error = null;

        if (!int.TryParse(ClipboardSecondsBox.Text.Trim(), NumberStyles.Integer,
                CultureInfo.InvariantCulture, out int seconds) || seconds < 0)
        {
            error = "The clipboard delay must be zero or more seconds.";
            return false;
        }

        settings = new AppSettings
        {
            AutoConnect = AutoConnectBox.IsChecked == true,
            AutoReconnect = AutoReconnectBox.IsChecked == true,
            ClipboardAutoClearSeconds = seconds,
        };
        return true;
    }

    /// <summary>
    /// Imports a portable profile document. Validation and the credential deny-list live in
    /// <see cref="ProfilePortability"/>, so a document carrying authentication material is refused
    /// here exactly as it would be anywhere else.
    /// </summary>
    private void OnImport(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog
        {
            Title = "Open a profile file",
            Filter = "Profile files (*.yaml;*.yml;*.json)|*.yaml;*.yml;*.json",
        };

        if (dialog.ShowDialog(this) != true)
        {
            return;
        }

        try
        {
            ProfileFileSnapshot preview = _files.Read(dialog.FileName);
            int choice = Preview(preview, importing: true);
            if (choice == 0) { return; }
            ConnectionProfile imported = _library.Import(preview, attach: choice == 1);
            _activeId ??= imported.Id;
            Persist();
            RefreshList(imported.Id);
            ValidationText.Text = string.Empty;
        }
        catch (Exception error) when (FileFailure(error))
        {
            MessageBox.Show(this, error.Message, "Could not import that profile",
                MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private void OnExport(object sender, RoutedEventArgs e)
    {
        ConnectionProfile? profile = ReadEditor(out string? error);
        if (profile is null)
        {
            ValidationText.Text = error ?? "Select a workstation first.";
            return;
        }

        var dialog = new SaveFileDialog
        {
            Title = "Export the connection profile",
            FileName = new string(profile.Name.Select(character => Path.GetInvalidFileNameChars().Contains(character) ? '_' : character).ToArray()) + ".yaml",
            Filter = "YAML profile (*.yaml)|*.yaml|JSON profile (*.json)|*.json",
            DefaultExt = ".yaml",
            OverwritePrompt = true,
        };

        if (dialog.ShowDialog(this) != true)
        {
            return;
        }

        try
        {
            if (_library.Attachments.TryGetValue(profile.Id, out ProfileAttachment? attached)
                && string.Equals(Path.GetFullPath(dialog.FileName), attached.Path, StringComparison.OrdinalIgnoreCase))
            {
                if (!CanonicalConsent(profile.Id)) { return; }
                _library.SaveProfile(profile, _editingRevision, true);
                Persist();
                RefreshList(profile.Id);
            }
            else
            {
                _files.Save(_library.Export(profile.Id).WithProfile(profile), dialog.FileName, _files.ExistingRevision(dialog.FileName));
                Persist();
            }
        }
        catch (Exception failure) when (FileFailure(failure))
        {
            MessageBox.Show(this, failure.Message, "Could not export that profile",
                MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private void OnClose(object sender, RoutedEventArgs e) => Close();

    private void Persist() => _persist(new StoredState([.. _profiles], _settings, _activeId,
        _library.Documents.ToDictionary(), _library.Attachments.ToDictionary()));

    private void OnSaveSettings(object sender, RoutedEventArgs e)
    {
        if (!TrySettings(out AppSettings settings, out string? error)) { ValidationText.Text = error; return; }
        FileOperation(() =>
        {
            _settings = settings;
            Persist();
            ValidationText.Text = "Application settings saved. The profile editor draft was not saved.";
        });
    }

    private void OnSaveCopy(object sender, RoutedEventArgs e) => FileOperation(() =>
    {
        ConnectionProfile? draft = ReadEditor(out string? error);
        if (draft is null) { throw new ProfilePortabilityException(error ?? "Select a profile first."); }
        ConnectionProfile copy = _library.SaveLocalCopy(draft, draft.Id);
        Persist();
        RefreshList(copy.Id);
    });

    private void OnReloadFile(object sender, RoutedEventArgs e) => FileOperation(() =>
    {
        _library.Refresh();
        UpdateFileStatus();
        if (Selected is { } selected && _library.Pending.TryGetValue(selected.Id, out ProfileFileSnapshot? pending))
        {
            Preview(pending, importing: false);
        }
    });

    private void OnApplyFile(object sender, RoutedEventArgs e) => FileOperation(() =>
    {
        if (Selected is not { } profile) { throw new ProfilePortabilityException("Select an attached profile first."); }
        if (MessageBox.Show(this,
            "Apply the validated external values for future operations? Existing connections are not redirected or reconnected. This replaces the current editor draft; save a local copy first if needed.",
            "Apply external profile changes", MessageBoxButton.OKCancel, MessageBoxImage.Warning) != MessageBoxResult.OK) { return; }
        _library.Apply(profile.Id);
        Persist();
        RefreshList(profile.Id);
    });

    private void OnLocateFile(object sender, RoutedEventArgs e) => FileOperation(() =>
    {
        if (Selected is not { } profile) { throw new ProfilePortabilityException("Select an attached profile first."); }
        var dialog = new OpenFileDialog { Title = "Locate the same profile document", Filter = "Profile files|*.yaml;*.yml;*.json" };
        if (dialog.ShowDialog(this) != true) { return; }
        _library.Locate(profile.Id, dialog.FileName);
        Persist();
        UpdateFileStatus();
    });

    private void OnDetachFile(object sender, RoutedEventArgs e) => FileOperation(() =>
    {
        if (Selected is not { } profile) { throw new ProfilePortabilityException("Select an attached profile first."); }
        _library.Detach(profile.Id);
        Persist();
        UpdateFileStatus();
    });

    private bool CanonicalConsent(Guid id) => !_library.Attachments.TryGetValue(id, out ProfileAttachment? attached)
        || attached.CanonicalSaveAccepted || MessageBox.Show(this,
            "Saving this attached file uses canonical formatting and may remove YAML comments. Legacy v1 files upgrade to schema v2; older clients may not read them. Validated values and permitted unknown fields are retained. Cancel to keep editing or save a local copy.",
            "Save canonical formatting?", MessageBoxButton.OKCancel, MessageBoxImage.Information) == MessageBoxResult.OK;

    private void UpdateFileStatus()
    {
        if (Selected is not { } profile) { FileStatusText.Text = string.Empty; return; }
        bool attached = _library.Attachments.TryGetValue(profile.Id, out ProfileAttachment? source);
        ApplyFileItem.IsEnabled = _library.Pending.ContainsKey(profile.Id);
        LocateFileItem.IsEnabled = attached;
        DetachFileItem.IsEnabled = attached;
        ReloadFileItem.IsEnabled = attached;
        FileStatusText.Text = attached ? "Attached: " + source!.Path : "Local profile (no attached file)";
        SaveButton.IsEnabled = true;
        if (_library.Pending.ContainsKey(profile.Id)) { FileStatusText.Text += "\nExternal changes pending. Review and Apply explicitly."; }
        if (_library.Errors.TryGetValue(profile.Id, out string? error))
        {
            FileStatusText.Text += "\n" + error;
            SaveButton.IsEnabled = false;
        }
        else if (attached)
        {
            try
            {
                if (!_files.Read(source!.Path).CanWrite)
                {
                    FileStatusText.Text += "\nRead-only or locked. Save a local copy to keep edits.";
                    SaveButton.IsEnabled = false;
                }
            }
            catch (Exception failure) when (FileFailure(failure))
            {
                FileStatusText.Text += "\n" + failure.Message + " Save a local copy or locate the file.";
                SaveButton.IsEnabled = false;
            }
        }
    }

    private int Preview(ProfileFileSnapshot snapshot, bool importing)
    {
        int choice = 0;
        var window = new Window { Owner = this, Title = importing ? "Preview profile file" : "Review external changes",
            Width = 640, Height = 560, WindowStartupLocation = WindowStartupLocation.CenterOwner };
        var panel = new DockPanel { Margin = new Thickness(12) };
        var header = new TextBlock { Text = snapshot.Path + "\nNo AWS access, connection, auto-connect or integration setup has occurred."
            + (snapshot.CanWrite ? "" : "\nThe source is read-only or locked."), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 8) };
        DockPanel.SetDock(header, Dock.Top);
        panel.Children.Add(header);
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right };
        void Button(string title, int value)
        {
            var button = new Button { Content = title, Margin = new Thickness(6, 8, 0, 0), Padding = new Thickness(10, 4, 10, 4) };
            button.Click += (_, _) => { choice = value; window.Close(); };
            buttons.Children.Add(button);
        }
        if (importing) { Button("Attach File", 1); Button("Import as Local Copy", 2); }
        Button(importing ? "Cancel" : "Keep Pending", 0);
        DockPanel.SetDock(buttons, Dock.Bottom);
        panel.Children.Add(buttons);
        panel.Children.Add(new TextBox { Text = ProfilePortability.Export(snapshot.Document), IsReadOnly = true,
            FontFamily = new System.Windows.Media.FontFamily("Consolas"), VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto });
        window.Content = panel;
        window.ShowDialog();
        return choice;
    }

    private static bool FileFailure(Exception error) =>
        error is ProfilePortabilityException or IOException or UnauthorizedAccessException;
    private void ShowFileError(Exception error)
    {
        ValidationText.Text = error.Message;
        MessageBox.Show(this, error.Message, "Profile file was not saved", MessageBoxButton.OK, MessageBoxImage.Warning);
    }
    private void FileOperation(Action operation)
    {
        try { operation(); }
        catch (Exception error) when (FileFailure(error)) { ShowFileError(error); }
    }
}
