using System.Windows;

namespace SSMConnect.App.Shell;

/// <summary>
/// One window of a kind: showing it again brings the open window forward, restored if minimized,
/// instead of opening another. A second launch of the shell shows the settings this way.
/// </summary>
public sealed class SingleWindow<T> where T : Window
{
    T? window;

    /// <summary>The open window, or null.</summary>
    public T? Current => window;

    public T Show(Func<T> create)
    {
        if (window is null)
        {
            window = create();
            window.Closed += (_, _) => window = null;
            window.Show();
        }
        if (window.WindowState == WindowState.Minimized) window.WindowState = WindowState.Normal;
        window.Activate();
        return window;
    }
}
