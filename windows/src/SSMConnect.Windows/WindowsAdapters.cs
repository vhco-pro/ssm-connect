using System.Diagnostics;
using System.Globalization;
using System.Net.Http.Json;
using System.Net.Sockets;
using System.Runtime.Versioning;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Win32;
using SSMConnect.Domain;
using SSMConnect.Workflow;

namespace SSMConnect.Windows;

/// <summary>A running <c>session-manager-plugin</c>, contained in a kill-on-close Job Object.</summary>
[SupportedOSPlatform("windows")]
internal sealed class PluginTunnelHandle : ITunnelHandle
{
    private readonly Process _process;
    private readonly KillOnCloseJob _job;
    private readonly TaskCompletionSource<TunnelDropReason> _dropped =
        new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly System.Text.StringBuilder _standardError = new();
    private int _terminated;

    internal PluginTunnelHandle(Process process, KillOnCloseJob job)
    {
        _process = process;
        _job = job;

        // Both streams must be drained: the plugin writes progress to stdout and diagnostics to
        // stderr, and an undrained pipe eventually blocks the child.
        _process.OutputDataReceived += (_, _) => { };
        _process.ErrorDataReceived += (_, args) =>
        {
            if (args.Data is not null)
            {
                lock (_standardError)
                {
                    _standardError.AppendLine(args.Data);
                }
            }
        };
        _process.BeginOutputReadLine();
        _process.BeginErrorReadLine();

        _ = Task.Run(async () =>
        {
            await _process.WaitForExitAsync().ConfigureAwait(false);
            if (Volatile.Read(ref _terminated) == 0)
            {
                string stderr;
                lock (_standardError)
                {
                    stderr = _standardError.ToString().Trim();
                }

                _dropped.TrySetResult(new TunnelDropReason.ProcessExited(_process.ExitCode, stderr));
            }
        });
    }

    public int ProcessId { get; internal init; }

    public Task<TunnelDropReason> Dropped => _dropped.Task;

    public async Task TerminateAsync()
    {
        if (Interlocked.Exchange(ref _terminated, 1) == 1)
        {
            return;
        }

        _dropped.TrySetResult(new TunnelDropReason.TerminatedByUser());

        try
        {
            if (!_process.HasExited)
            {
                _process.Kill(entireProcessTree: true);
                await _process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false);
            }
        }
        catch (Exception error) when (error is not OperationCanceledException)
        {
            // Termination is best effort; the Job Object is the guarantee, not this call.
        }
        finally
        {
            _job.Dispose();
            _process.Dispose();
        }
    }
}

/// <summary>
/// Starts the official <c>session-manager-plugin</c> as a contained child process.
/// </summary>
/// <remarks>
/// AWS documents the plugin for PowerShell and Command Prompt and warns that third-party
/// command-line tools may be incompatible, so it is launched directly rather than through a shell,
/// with the same five arguments the macOS client uses.
/// </remarks>
[SupportedOSPlatform("windows")]
public sealed class PluginTunnelProvider(string? pluginPath = null) : ITunnelProvider
{
    /// <summary>Where the official installer puts the plugin.</summary>
    public const string DefaultPluginPath =
        @"C:\Program Files\Amazon\SessionManagerPlugin\bin\session-manager-plugin.exe";

    private readonly string _pluginPath = pluginPath ?? DefaultPluginPath;

    public bool IsPluginAvailable => File.Exists(_pluginPath);

    public Task<ITunnelHandle> StartTunnelAsync(
        SsmSession session, string region, string instanceId,
        int localPort, int remotePort, CancellationToken cancellationToken)
    {
        if (!File.Exists(_pluginPath))
        {
            throw new TunnelException($"The Session Manager plugin was not found at {_pluginPath}.");
        }

        string sessionJson = JsonSerializer.Serialize(new
        {
            SessionId = session.SessionId,
            StreamUrl = session.StreamUrl,
            TokenValue = session.TokenValue,
        });

        string requestJson = JsonSerializer.Serialize(new
        {
            Target = instanceId,
            DocumentName = "AWS-StartPortForwardingSession",
            Parameters = new Dictionary<string, string[]>
            {
                ["portNumber"] = [remotePort.ToString(CultureInfo.InvariantCulture)],
                ["localPortNumber"] = [localPort.ToString(CultureInfo.InvariantCulture)],
            },
        });

        var startInfo = new ProcessStartInfo
        {
            FileName = _pluginPath,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
        };

        // The five-argument contract, in order: session JSON, region, StartSession, an empty
        // profile argument, and the request JSON.
        startInfo.ArgumentList.Add(sessionJson);
        startInfo.ArgumentList.Add(region);
        startInfo.ArgumentList.Add("StartSession");
        startInfo.ArgumentList.Add(string.Empty);
        startInfo.ArgumentList.Add(requestJson);

        var process = new Process { StartInfo = startInfo };
        var job = new KillOnCloseJob();

        try
        {
            process.Start();
            job.AddProcess(process);
        }
        catch (Exception error)
        {
            job.Dispose();
            process.Dispose();
            throw new TunnelException($"The Session Manager plugin could not be started: {error.Message}", error);
        }

        return Task.FromResult<ITunnelHandle>(
            new PluginTunnelHandle(process, job) { ProcessId = process.Id });
    }
}

/// <summary>Probes the forwarded DCV endpoint over the loopback tunnel.</summary>
public sealed class LoopbackReadinessProbe : IReadinessProbe
{
    /// <summary>
    /// A successful probe connects to the loopback port, so it also proves the tunnel is listening.
    /// TLS is not completed: the workstation certificate is self-signed for its private name, and
    /// establishing that a TLS server is answering is all this needs to decide.
    /// </summary>
    public async Task<bool> WaitUntilReadyAsync(
        int port, TimeSpan timeout, TimeSpan interval, CancellationToken cancellationToken)
    {
        DateTimeOffset deadline = DateTimeOffset.UtcNow + timeout;
        while (DateTimeOffset.UtcNow < deadline)
        {
            cancellationToken.ThrowIfCancellationRequested();
            if (await IsListeningAsync(port, TimeSpan.FromSeconds(2), cancellationToken).ConfigureAwait(false))
            {
                return true;
            }

            await Task.Delay(interval, cancellationToken).ConfigureAwait(false);
        }

        return false;
    }

    public async Task<bool> IsListeningAsync(int port, TimeSpan timeout, CancellationToken cancellationToken)
    {
        using var client = new TcpClient();
        try
        {
            // The IPv4 literal, never "localhost": the port-forward binds IPv4 only, and localhost
            // can resolve to ::1 first, where nothing is listening.
            await client.ConnectAsync(DcvConnectionFile.LoopbackHost, port, cancellationToken)
                .AsTask().WaitAsync(timeout, cancellationToken).ConfigureAwait(false);
            return client.Connected;
        }
        catch (Exception error) when (error is SocketException or TimeoutException)
        {
            return false;
        }
    }
}

/// <summary>Writes, launches, and cleans up DCV connection files.</summary>
[SupportedOSPlatform("windows")]
public sealed class DcvViewerLauncher : IDcvLauncher
{
    /// <summary>
    /// Required for the workstation's self-signed certificate, reached at the loopback end of an
    /// authenticated SSM tunnel.
    /// </summary>
    /// <remarks>
    /// Specification §9.2 and §12 constrain this narrowly and deliberately: confidentiality and peer
    /// authenticity come from the SSM session, not from the DCV certificate. It is applied here, at
    /// this call site, for a loopback endpoint this application opened — never inherited from a
    /// shared default, never applied to a user-supplied host, and never exposed as a setting.
    /// </remarks>
    public const string AcceptUntrustedArgument = "--certificate-validation-policy=accept-untrusted";

    /// <summary>How long the file stays on disk after launch, so the viewer can read it.</summary>
    public static readonly TimeSpan ConsumptionGrace = TimeSpan.FromSeconds(5);

    /// <summary>Orphans older than this are swept at startup.</summary>
    public static readonly TimeSpan OrphanAge = TimeSpan.FromHours(1);

    private readonly string _viewerPath;

    public DcvViewerLauncher(string? viewerPath = null) =>
        _viewerPath = viewerPath ?? DiscoverViewerPath() ?? string.Empty;

    /// <summary>The application-owned directory, with an ACL granting only the current user.</summary>
    public static string ConnectionFileDirectory { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SSM Connect", "connections");

    public bool IsViewerInstalled() => _viewerPath.Length > 0 && File.Exists(_viewerPath);

    /// <summary>
    /// Resolves the viewer through its registered file association rather than a hardcoded path, so
    /// a non-default install location still works.
    /// </summary>
    public static string? DiscoverViewerPath()
    {
        string? command = Registry.ClassesRoot
            .OpenSubKey(@"DcvViewerProgId\shell\open\command")?.GetValue(null) as string;
        if (string.IsNullOrWhiteSpace(command))
        {
            return null;
        }

        // The value is a command line: an optionally quoted executable followed by arguments.
        string trimmed = command.Trim();
        if (trimmed.StartsWith('"'))
        {
            int closing = trimmed.IndexOf('"', 1);
            return closing > 1 ? trimmed[1..closing] : null;
        }

        int space = trimmed.IndexOf(' ', StringComparison.Ordinal);
        return space > 0 ? trimmed[..space] : trimmed;
    }

    public async Task LaunchAsync(DcvConnectionFile file, CancellationToken cancellationToken)
    {
        string path = WriteCurrentUserOnly(file);
        try
        {
            var startInfo = new ProcessStartInfo
            {
                FileName = _viewerPath,
                UseShellExecute = false,
                CreateNoWindow = false,
            };
            startInfo.ArgumentList.Add(AcceptUntrustedArgument);
            startInfo.ArgumentList.Add($"--connection-file={path}");

            using Process? viewer = Process.Start(startInfo);
            if (viewer is null)
            {
                throw new InvalidOperationException("Amazon DCV Viewer did not start.");
            }

            // Deleting immediately can race the viewer's own read of the file.
            await Task.Delay(ConsumptionGrace, cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            TryDelete(path);
        }
    }

    /// <summary>
    /// Writes the file into an application-owned directory whose ACL grants only the current user.
    /// The file carries a password or an identity token, so it must never be world-readable.
    /// </summary>
    private static string WriteCurrentUserOnly(DcvConnectionFile file)
    {
        Directory.CreateDirectory(ConnectionFileDirectory);
        RestrictToCurrentUser(ConnectionFileDirectory);

        string path = Path.Combine(
            ConnectionFileDirectory,
            $"{DcvConnectionFile.TempFilePrefix}{Guid.NewGuid():N}.{DcvConnectionFile.FileExtension}");

        File.WriteAllText(path, file.ToIni());
        return path;
    }

    private static void RestrictToCurrentUser(string directory)
    {
        var info = new DirectoryInfo(directory);
        DirectorySecurity security = info.GetAccessControl();
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);

        SecurityIdentifier user = WindowsIdentity.GetCurrent().User
            ?? throw new InvalidOperationException("The current Windows identity has no user SID.");
        security.SetOwner(user);
        security.SetAccessRule(new FileSystemAccessRule(
            user,
            FileSystemRights.FullControl,
            InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit,
            PropagationFlags.None,
            AccessControlType.Allow));

        info.SetAccessControl(security);
    }

    /// <summary>
    /// Removes only this application's own connection files, below its own directory, and only ones
    /// old enough to be orphans rather than a launch in flight.
    /// </summary>
    public void SweepOrphanedFiles()
    {
        if (!Directory.Exists(ConnectionFileDirectory))
        {
            return;
        }

        DateTime cutoff = DateTime.UtcNow - OrphanAge;
        foreach (string path in Directory.EnumerateFiles(
                     ConnectionFileDirectory,
                     $"{DcvConnectionFile.TempFilePrefix}*.{DcvConnectionFile.FileExtension}",
                     SearchOption.TopDirectoryOnly))
        {
            try
            {
                if (File.GetLastWriteTimeUtc(path) < cutoff)
                {
                    File.Delete(path);
                }
            }
            catch (IOException)
            {
                // A file still in use is not an orphan; leave it.
            }
            catch (UnauthorizedAccessException)
            {
            }
        }
    }

    private static void TryDelete(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }
    }
}

/// <summary>Remembers the last instance ID per profile, for replacement detection.</summary>
/// <remarks>Non-secret by definition, so a plain file beside the application's other state is enough.</remarks>
public sealed class FileInstanceIdStore : IInstanceIdStore
{
    private readonly string _path;
    private readonly Dictionary<string, string> _values;

    public FileInstanceIdStore(string? path = null)
    {
        _path = path ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "SSM Connect", "last-instance-ids.json");

        _values = File.Exists(_path)
            ? JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(_path)) ?? []
            : [];
    }

    public string? LastInstanceId(Guid profileId) =>
        _values.TryGetValue(profileId.ToString("D"), out string? value) ? value : null;

    public void SetLastInstanceId(Guid profileId, string instanceId)
    {
        _values[profileId.ToString("D")] = instanceId;
        Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
        File.WriteAllText(_path, JsonSerializer.Serialize(_values, new JsonSerializerOptions { WriteIndented = true }));
    }
}

/// <summary>Calls the on-box workstation agent through its transient tunnel.</summary>
public sealed class WorkstationAgentClient(HttpClient? httpClient = null) : IAgentClient, IDisposable
{
    private readonly HttpClient _http = httpClient ?? new HttpClient { Timeout = TimeSpan.FromSeconds(10) };
    private readonly bool _ownsClient = httpClient is null;

    public async Task<EnsureSessionResult> EnsureSessionAsync(
        int port, string authToken, CancellationToken cancellationToken)
    {
        var request = new HttpRequestMessage(
            HttpMethod.Post, $"http://{DcvConnectionFile.LoopbackHost}:{port}/ensure-session")
        {
            Content = JsonContent.Create(new EnsureSessionRequest(authToken)),
        };

        HttpResponseMessage response;
        try
        {
            response = await _http.SendAsync(request, cancellationToken).ConfigureAwait(false);
        }
        catch (Exception error) when (error is HttpRequestException or TaskCanceledException
                                          && !cancellationToken.IsCancellationRequested)
        {
            // The agent did not answer. That is transient while a freshly opened tunnel settles,
            // and the workflow retries it.
            throw new AgentException(
                $"The workstation agent is not reachable on port {port}.", responded: false, error);
        }

        if (!response.IsSuccessStatusCode)
        {
            // The agent answered. That is a decision, not a transient failure, so it must not be
            // retried and must never fall back to a shared user.
            string body = await response.Content.ReadAsStringAsync(cancellationToken).ConfigureAwait(false);
            throw new AgentException(
                $"The workstation agent rejected the request ({(int)response.StatusCode}). {body}".Trim(),
                responded: true);
        }

        EnsureSessionResponse? payload = await response.Content
            .ReadFromJsonAsync<EnsureSessionResponse>(cancellationToken).ConfigureAwait(false);

        if (payload is null || string.IsNullOrWhiteSpace(payload.User) || string.IsNullOrWhiteSpace(payload.SessionId))
        {
            throw new AgentException("The workstation agent returned an incomplete session.", responded: true);
        }

        return new EnsureSessionResult(payload.User, payload.SessionId);
    }

    public void Dispose()
    {
        if (_ownsClient)
        {
            _http.Dispose();
        }
    }

    private sealed record EnsureSessionRequest([property: JsonPropertyName("authToken")] string AuthToken);

    private sealed record EnsureSessionResponse(
        [property: JsonPropertyName("user")] string User,
        [property: JsonPropertyName("sessionId")] string SessionId);
}

/// <summary>The real clock.</summary>
public sealed class RealDelay : IDelay
{
    public Task WaitAsync(TimeSpan duration, CancellationToken cancellationToken) =>
        Task.Delay(duration, cancellationToken);
}
