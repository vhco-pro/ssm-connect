using System.Globalization;
using System.Text;

namespace SSMConnect.Windows;

/// <summary>One line the workflow reported while connecting.</summary>
public sealed record LogEntry(DateTimeOffset Timestamp, string Category, string Message)
{
    public override string ToString() =>
        $"{Timestamp.ToLocalTime():HH:mm:ss}  {Category,-6}  {Message}";
}

/// <summary>
/// A bounded in-memory record of what the workflow did, for the log window.
/// </summary>
/// <remarks>
/// The shell previously sent log lines to <c>Debug.WriteLine</c>, which means they existed only
/// under a debugger: a user hitting a failure got a balloon and nothing else. This keeps the recent
/// history so it can be read and copied.
/// <para>
/// Bounded on purpose. A tray application runs for days, and an unbounded list of every poll and
/// retry is a slow leak. Oldest entries are dropped once the buffer is full.
/// </para>
/// </remarks>
public sealed class ConnectionLog(int capacity = 500)
{
    private readonly Queue<LogEntry> _entries = new();
    private readonly Lock _gate = new();

    /// <summary>Raised after each entry is appended, so a window can follow along.</summary>
    public event Action<LogEntry>? Appended;

    public int Capacity { get; } = capacity > 0
        ? capacity
        : throw new ArgumentOutOfRangeException(nameof(capacity), capacity, "Capacity must be positive.");

    public void Append(string category, string message)
    {
        var entry = new LogEntry(DateTimeOffset.Now, category, message);

        lock (_gate)
        {
            _entries.Enqueue(entry);
            while (_entries.Count > Capacity)
            {
                _entries.Dequeue();
            }
        }

        Appended?.Invoke(entry);
    }

    public IReadOnlyList<LogEntry> Snapshot()
    {
        lock (_gate)
        {
            return [.. _entries];
        }
    }

    public void Clear()
    {
        lock (_gate)
        {
            _entries.Clear();
        }
    }

    /// <summary>Renders the buffer for copying to the clipboard or pasting into an issue.</summary>
    public string ToPlainText()
    {
        var builder = new StringBuilder();
        builder.AppendLine(CultureInfo.InvariantCulture, $"SSM Connect log, {DateTimeOffset.Now:yyyy-MM-dd HH:mm:ss zzz}");
        builder.AppendLine();

        foreach (LogEntry entry in Snapshot())
        {
            builder.AppendLine(entry.ToString());
        }

        return builder.ToString();
    }
}
