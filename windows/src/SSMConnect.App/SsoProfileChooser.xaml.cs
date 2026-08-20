using System.Windows;
using SSMConnect.Aws;

namespace SSMConnect.App;

/// <summary>Lets the user pick which IAM Identity Center profile to build a workstation from.</summary>
public partial class SsoProfileChooser : Window
{
    public SsoProfileChooser(IReadOnlyList<DiscoveredSsoProfile> profiles)
    {
        InitializeComponent();
        ProfileList.ItemsSource = profiles;
        ProfileList.SelectedIndex = profiles.Count > 0 ? 0 : -1;
    }

    /// <summary>The chosen profile, or null if the dialog was cancelled.</summary>
    public DiscoveredSsoProfile? Selected { get; private set; }

    private void OnUse(object sender, RoutedEventArgs e)
    {
        if (ProfileList.SelectedItem is not DiscoveredSsoProfile chosen)
        {
            return;
        }

        Selected = chosen;
        DialogResult = true;
        Close();
    }

    private void OnCancel(object sender, RoutedEventArgs e)
    {
        DialogResult = false;
        Close();
    }
}
