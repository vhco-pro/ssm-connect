using Microsoft.Win32;

namespace SSMConnect.App.Shell;

/// <summary>
/// Starting the shell at sign-in, through the current user's Run key: per user, no elevation, and
/// removed with the value. The key name is injectable for tests.
/// </summary>
public sealed class StartupRegistration(string valueName = "SSM Connect", string keyPath = @"Software\Microsoft\Windows\CurrentVersion\Run")
{
    public bool IsEnabled
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(keyPath);
            return key?.GetValue(valueName) is string;
        }
    }

    public void SetEnabled(bool enabled, string executablePath)
    {
        using var key = Registry.CurrentUser.CreateSubKey(keyPath);
        if (enabled) key.SetValue(valueName, $"\"{executablePath}\"");
        else key.DeleteValue(valueName, throwOnMissingValue: false);
    }
}
