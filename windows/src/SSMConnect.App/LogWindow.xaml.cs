using System.Text;
using System.Windows;
using SSMConnect.Windows;

namespace SSMConnect.App;

/// <summary>
/// Shows what the connection workflow reported.
/// </summary>
/// <remarks>
/// The macOS client has had a log window from the start; without one a failure gives the user a
/// balloon and nothing else, and the detail that would explain it exists only under a debugger.
/// </remarks>
public partial class LogWindow : Window
{
    private readonly ConnectionLog _log;

    public LogWindow(ConnectionLog log)
    {
        InitializeComponent();
        _log = log;

        Render();
        _log.Appended += OnAppended;
        Closed += (_, _) => _log.Appended -= OnAppended;
    }

    private void OnAppended(LogEntry entry) => Dispatcher.Invoke(() =>
    {
        LogText.AppendText(entry + Environment.NewLine);
        if (FollowBox.IsChecked == true)
        {
            LogText.ScrollToEnd();
        }
    });

    private void Render()
    {
        var builder = new StringBuilder();
        foreach (LogEntry entry in _log.Snapshot())
        {
            builder.AppendLine(entry.ToString());
        }

        LogText.Text = builder.ToString();
        LogText.ScrollToEnd();
    }

    private void OnCopy(object sender, RoutedEventArgs e)
    {
        try
        {
            System.Windows.Clipboard.SetText(_log.ToPlainText());
        }
        catch (Exception)
        {
            // Another process can hold the clipboard open; losing a copy is not worth an error box.
        }
    }

    private void OnClear(object sender, RoutedEventArgs e)
    {
        _log.Clear();
        LogText.Clear();
    }

    private void OnClose(object sender, RoutedEventArgs e) => Close();
}
