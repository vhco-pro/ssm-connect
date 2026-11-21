using System.IO;
using System.Diagnostics;

namespace SSMConnect.App.Helper;

/// <summary>
/// Starts the bundled helper as the shell's child, connected only by anonymous stdin/stdout
/// pipes, inside a new kill-on-close job; diagnostics on stderr go to the shell's log.
/// </summary>
public sealed class JobHelperSpawner(string helperPath, Action<string>? diagnostics = null) : IHelperSpawner
{
    sealed class Connection(Process process, JobObject job) : IHelperConnection
    {
        public Process Process { get; } = process;
        public JobObject Job { get; } = job;
        public Stream Input => Process.StandardInput.BaseStream;
        public Stream Output => Process.StandardOutput.BaseStream;
        public Task Exited { get; } = process.WaitForExitAsync();

        public ValueTask DisposeAsync()
        {
            Job.Dispose();
            Process.Dispose();
            return ValueTask.CompletedTask;
        }
    }

    public Task<IHelperConnection> StartAsync(CancellationToken cancellationToken)
    {
        var job = new JobObject();
        var info = new ProcessStartInfo(helperPath)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        var process = Process.Start(info) ?? throw new InvalidOperationException("The helper did not start.");
        job.Assign(process);
        process.ErrorDataReceived += (_, line) => { if (line.Data is not null) diagnostics?.Invoke(line.Data); };
        process.BeginErrorReadLine();
        return Task.FromResult<IHelperConnection>(new Connection(process, job));
    }

    public Task TerminateAndWaitEmptyAsync(IHelperConnection connection, CancellationToken cancellationToken) =>
        ((Connection)connection).Job.TerminateAndWaitEmptyAsync(cancellationToken);
}
