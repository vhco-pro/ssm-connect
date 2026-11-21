using System.Diagnostics;

namespace SSMConnect.App.Helper;

/// <summary>
/// Starts the applications that hold the user's work (VS Code, DCV Viewer, browsers) from the
/// shell's own process, outside every helper job, so they outlive a helper or shell failure.
/// </summary>
public static class UserApplications
{
    public static Process Start(string path, IEnumerable<string> arguments)
    {
        var info = new ProcessStartInfo(path) { UseShellExecute = false };
        foreach (var argument in arguments) info.ArgumentList.Add(argument);
        return Process.Start(info) ?? throw new InvalidOperationException($"{path} did not start.");
    }
}
