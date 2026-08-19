using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using Microsoft.Win32;
using MessageBox = System.Windows.MessageBox;
using OpenFileDialog = Microsoft.Win32.OpenFileDialog;
using SaveFileDialog = Microsoft.Win32.SaveFileDialog;
using SSMConnect.Domain;
using SSMConnect.Windows;

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
    private List<ConnectionProfile> _profiles;
    private AppSettings _settings;
    private Guid? _activeId;
    private bool _loading;

    public SettingsWindow(StoredState state, Action<StoredState> persist)
    {
        InitializeComponent();
        _persist = persist;
        _profiles = [.. state.Profiles];
        _settings = state.Settings;
        _activeId = state.ActiveProfileId ?? state.Profiles.FirstOrDefault()?.Id;

        LoadSettings();
        RefreshList(_activeId);
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

        _profiles.Remove(profile);
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
            };
        }

        return null;
    }

    private static bool TryPort(string text, out int port) =>
        int.TryParse(text.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out port)
        && port is >= 1 and <= 65535;

    private void OnSave(object sender, RoutedEventArgs e)
    {
        if (_profiles.Count > 0)
        {
            ConnectionProfile? updated = ReadEditor(out string? error);
            if (updated is null)
            {
                ValidationText.Text = error;
                return;
            }

            _profiles[_profiles.FindIndex(profile => profile.Id == updated.Id)] = updated;
            _activeId = updated.Id;
        }

        if (!TrySettings(out AppSettings settings, out string? settingsError))
        {
            ValidationText.Text = settingsError;
            return;
        }

        _settings = settings;
        ValidationText.Text = string.Empty;
        _persist(new StoredState([.. _profiles], _settings, _activeId));
        RefreshList(_activeId);
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
            Title = "Import a connection profile",
            Filter = "Connection profile (*.json)|*.json|All files (*.*)|*.*",
        };

        if (dialog.ShowDialog(this) != true)
        {
            return;
        }

        try
        {
            ConnectionProfile imported = ProfilePortability.ImportProfile(File.ReadAllText(dialog.FileName));

            // A re-import of the same document updates in place rather than silently duplicating.
            int existing = _profiles.FindIndex(profile => profile.Id == imported.Id);
            if (existing >= 0)
            {
                _profiles[existing] = imported;
            }
            else
            {
                _profiles.Add(imported);
            }

            _activeId = imported.Id;
            RefreshList(_activeId);
            ValidationText.Text = string.Empty;
        }
        catch (Exception error) when (error is ProfilePortabilityException or IOException)
        {
            MessageBox.Show(this, error.Message, "Could not import that profile",
                MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private void OnExport(object sender, RoutedEventArgs e)
    {
        ConnectionProfile? profile = ReadEditor(out string? error) ?? Selected;
        if (profile is null)
        {
            ValidationText.Text = error ?? "Select a workstation first.";
            return;
        }

        var dialog = new SaveFileDialog
        {
            Title = "Export the connection profile",
            FileName = $"{profile.Name}.json",
            Filter = "Connection profile (*.json)|*.json",
        };

        if (dialog.ShowDialog(this) != true)
        {
            return;
        }

        try
        {
            File.WriteAllText(dialog.FileName, ProfilePortability.Export(profile));
        }
        catch (IOException failure)
        {
            MessageBox.Show(this, failure.Message, "Could not export that profile",
                MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    private void OnClose(object sender, RoutedEventArgs e) => Close();
}
