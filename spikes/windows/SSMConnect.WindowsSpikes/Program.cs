using Amazon.Runtime;
using Amazon.Runtime.CredentialManagement;
using Amazon.SecurityToken;
using Amazon.SecurityToken.Model;
using Amazon.SecretsManager;
using Amazon.SecretsManager.Model;
using Amazon.SimpleSystemsManagement;
using Amazon.SimpleSystemsManagement.Model;
using Microsoft.Win32;
using System.Diagnostics;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.Json;

if (!System.OperatingSystem.IsWindows())
{
    return Fail("Phase 0 spikes must run on Windows.");
}

if (args is ["child"])
{
    Console.Out.WriteLine("stdout-ready");
    Console.Error.WriteLine("stderr-ready");
    await Task.Delay(Timeout.InfiniteTimeSpan);
    return 0;
}

if (args is ["crash-holder"])
{
    // Stands in for the client process: owns a kill-on-close job containing a
    // plugin-shaped child, reports the child id, then blocks so the caller can
    // terminate it without any managed cleanup running.
    using Process held = StartChild();
    var holderJob = new KillOnCloseJob();
    holderJob.AddProcess(held);
    Console.Out.WriteLine(held.Id);
    Console.Out.Flush();
    await Task.Delay(Timeout.InfiniteTimeSpan);
    return 0;
}

string command = args.FirstOrDefault() ?? "host";
return command switch
{
    "host" => await ProbeHostAsync(),
    "plugin" => await ProbePluginAsync(),
    "aws" when args.Length == 3 => await ProbeAwsAsync(args[1], args[2]),
    "tunnel" when args.Length == 6 => await ProbeTunnelAsync(args[1], args[2], args[3], int.Parse(args[4]), int.Parse(args[5])),
    "multi-user" when args.Length == 6 => await ProbeMultiUserAsync(args[1], args[2], args[3], int.Parse(args[4]), int.Parse(args[5])),
    "single-user" when args.Length == 8 => await ProbeSingleUserAsync(args[1], args[2], args[3], int.Parse(args[4]), args[5], args[6], args[7]),
    "dcv-files" => ProbeDcvFiles(),
    "crash" => await ProbeCrashAsync(),
    _ => Fail("Usage: host | plugin | crash | aws <profile> <resource-region> | tunnel <profile> <region> <instance-id> <local-port> <remote-port> | multi-user <profile> <region> <instance-id> <dcv-local-port> <agent-local-port> | single-user <profile> <region> <instance-id> <local-port> <secret-id> <user> <expected-session-id> | dcv-files"),
};

static async Task<int> ProbeHostAsync()
{
    Console.WriteLine($"OS: {RuntimeInformation.OSDescription}");
    Console.WriteLine($"Architecture: {RuntimeInformation.OSArchitecture}");
    Console.WriteLine($"Runtime: {RuntimeInformation.FrameworkDescription}");

    if (RuntimeInformation.OSArchitecture != Architecture.X64)
    {
        return Fail("Windows v1 requires x64.");
    }

    using Process child = StartChild();
    using var job = new KillOnCloseJob();
    job.AddProcess(child);

    Task<string?> stdout = child.StandardOutput.ReadLineAsync();
    Task<string?> stderr = child.StandardError.ReadLineAsync();
    if (await stdout != "stdout-ready" || await stderr != "stderr-ready")
    {
        return Fail("redirected process output was not drained correctly.");
    }

    job.Dispose();
    await child.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5));
    Console.WriteLine($"PASS: Job Object close terminated the redirected child (exit {child.ExitCode}).");
    return 0;
}

static async Task<int> ProbePluginAsync()
{
    const string pluginPath = @"C:\Program Files\Amazon\SessionManagerPlugin\bin\session-manager-plugin.exe";
    if (!File.Exists(pluginPath))
    {
        return Fail($"Session Manager plugin not found at {pluginPath}");
    }

    var startInfo = new ProcessStartInfo
    {
        FileName = pluginPath,
        UseShellExecute = false,
        RedirectStandardOutput = true,
        RedirectStandardError = true,
        CreateNoWindow = true,
    };
    startInfo.ArgumentList.Add("{\"SessionId\":\"synthetic\",\"StreamUrl\":\"wss://127.0.0.1/\",\"TokenValue\":\"SECRET_SENTINEL\"}");
    startInfo.ArgumentList.Add("eu-west-1");
    startInfo.ArgumentList.Add("StartSession");
    startInfo.ArgumentList.Add(string.Empty);
    startInfo.ArgumentList.Add("{\"Target\":\"i-00000000000000000\",\"DocumentName\":\"AWS-StartPortForwardingSession\",\"Parameters\":{\"portNumber\":[\"8443\"],\"localPortNumber\":[\"58443\"]}}");

    using var process = new Process { StartInfo = startInfo };
    using var job = new KillOnCloseJob();
    process.Start();
    job.AddProcess(process);
    Task<string> stdout = process.StandardOutput.ReadToEndAsync();
    Task<string> stderr = process.StandardError.ReadToEndAsync();
    bool requiredTermination = false;
    try
    {
        await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5));
    }
    catch (TimeoutException)
    {
        requiredTermination = true;
        job.Dispose();
        await process.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5));
    }
    string combined = $"{await stdout}\n{await stderr}";

    Console.WriteLine($"Plugin exit code: {process.ExitCode}");
    Console.WriteLine($"Output captured: {!string.IsNullOrWhiteSpace(combined)}");
    Console.WriteLine($"Job Object termination required: {requiredTermination}");
    if (combined.Contains("SECRET_SENTINEL", StringComparison.Ordinal))
    {
        return Fail("plugin output echoed token material.");
    }

    Console.WriteLine("PASS: official x64 plugin accepted direct five-argument Process invocation and exited without a shell.");
    return 0;
}

static async Task<int> ProbeAwsAsync(string profileName, string regionName)
{
    AWSCredentials credentials = ResolveCredentials(profileName);

    if (string.IsNullOrWhiteSpace(regionName))
    {
        return Fail($"Profile '{profileName}' has no resource region.");
    }

    ImmutableCredentials resolved = await credentials.GetCredentialsAsync();
    if (string.IsNullOrWhiteSpace(resolved.AccessKey) || string.IsNullOrWhiteSpace(resolved.Token))
    {
        return Fail("AWS SDK returned incomplete temporary credentials.");
    }

    using var sts = new AmazonSecurityTokenServiceClient(credentials, Amazon.RegionEndpoint.GetBySystemName(regionName));
    GetCallerIdentityResponse identity = await sts.GetCallerIdentityAsync(new GetCallerIdentityRequest());
    if (string.IsNullOrWhiteSpace(identity.Account) || string.IsNullOrWhiteSpace(identity.Arn))
    {
        return Fail("STS GetCallerIdentity returned an incomplete identity.");
    }

    Console.WriteLine($"PASS: AWS SDK v4 resolved SSO profile '{profileName}' and called STS in {regionName}.");
    return 0;
}

static async Task<int> ProbeTunnelAsync(string profileName, string regionName, string instanceId, int localPort, int remotePort)
{
    const string pluginPath = @"C:\Program Files\Amazon\SessionManagerPlugin\bin\session-manager-plugin.exe";
    AWSCredentials credentials = ResolveCredentials(profileName);
    using var ssm = new AmazonSimpleSystemsManagementClient(credentials, Amazon.RegionEndpoint.GetBySystemName(regionName));
    StartSessionResponse? session = null;
    Process? plugin = null;
    KillOnCloseJob? job = null;
    try
    {
        session = await ssm.StartSessionAsync(new StartSessionRequest
        {
            Target = instanceId,
            DocumentName = "AWS-StartPortForwardingSession",
            Parameters = new Dictionary<string, List<string>>
            {
                ["portNumber"] = [remotePort.ToString()],
                ["localPortNumber"] = [localPort.ToString()],
            },
        });

        string sessionJson = JsonSerializer.Serialize(new
        {
            session.SessionId,
            session.StreamUrl,
            session.TokenValue,
        });
        string requestJson = JsonSerializer.Serialize(new
        {
            Target = instanceId,
            DocumentName = "AWS-StartPortForwardingSession",
            Parameters = new Dictionary<string, string[]>
            {
                ["portNumber"] = [remotePort.ToString()],
                ["localPortNumber"] = [localPort.ToString()],
            },
        });
        var startInfo = new ProcessStartInfo
        {
            FileName = pluginPath,
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
        };
        foreach (string argument in new[] { sessionJson, regionName, "StartSession", string.Empty, requestJson })
        {
            startInfo.ArgumentList.Add(argument);
        }

        plugin = new Process { StartInfo = startInfo };
        plugin.Start();
        _ = plugin.StandardOutput.ReadToEndAsync();
        _ = plugin.StandardError.ReadToEndAsync();
        job = new KillOnCloseJob();
        job.AddProcess(plugin);

        DateTime deadline = DateTime.UtcNow.AddSeconds(15);
        bool listening = false;
        while (!listening && DateTime.UtcNow < deadline && !plugin.HasExited)
        {
            using var client = new TcpClient();
            try
            {
                await client.ConnectAsync("127.0.0.1", localPort).WaitAsync(TimeSpan.FromMilliseconds(500));
                listening = true;
            }
            catch (Exception error) when (error is SocketException or TimeoutException)
            {
                await Task.Delay(250);
            }
        }
        if (!listening)
        {
            return Fail($"plugin did not listen on 127.0.0.1:{localPort}.");
        }

        Console.WriteLine($"PASS: live SSM port-forward session listened on 127.0.0.1:{localPort} and remained under Job Object supervision.");
        return 0;
    }
    finally
    {
        job?.Dispose();
        if (plugin is not null && !plugin.HasExited)
        {
            await plugin.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5));
        }
        plugin?.Dispose();
        job?.Dispose();
        if (!string.IsNullOrWhiteSpace(session?.SessionId))
        {
            await ssm.TerminateSessionAsync(new TerminateSessionRequest { SessionId = session.SessionId });
        }
    }
}

static async Task<int> ProbeMultiUserAsync(string profileName, string regionName, string instanceId, int dcvLocalPort, int agentLocalPort)
{
    AWSCredentials credentials = ResolveCredentials(profileName);
    ImmutableCredentials immutable = await credentials.GetCredentialsAsync();
    using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };

    string validationToken = StsPresigner.Presign(immutable, regionName, DateTime.UtcNow);
    using HttpResponseMessage stsResponse = await http.GetAsync(validationToken);
    if (!stsResponse.IsSuccessStatusCode)
    {
        return Fail($"presigned STS URL validation returned HTTP {(int)stsResponse.StatusCode}.");
    }

    await using LiveTunnel agentTunnel = await StartLiveTunnelAsync(credentials, regionName, instanceId, agentLocalPort, 8444);
    string ensureToken = StsPresigner.Presign(immutable, regionName, DateTime.UtcNow);
    using var ensureRequest = new HttpRequestMessage(HttpMethod.Post, $"http://127.0.0.1:{agentLocalPort}/ensure-session")
    {
        Content = new StringContent($"authenticationToken={Uri.EscapeDataString(ensureToken)}", Encoding.UTF8, "application/x-www-form-urlencoded"),
    };
    using HttpResponseMessage ensureResponse = await http.SendAsync(ensureRequest);
    string ensureJson = await ensureResponse.Content.ReadAsStringAsync();
    if (!ensureResponse.IsSuccessStatusCode)
    {
        return Fail($"workstation agent returned HTTP {(int)ensureResponse.StatusCode}.");
    }
    using JsonDocument result = JsonDocument.Parse(ensureJson);
    string user = result.RootElement.GetProperty("user").GetString() ?? throw new InvalidOperationException("Agent response omitted user.");
    string sessionId = result.RootElement.GetProperty("sessionId").GetString() ?? throw new InvalidOperationException("Agent response omitted sessionId.");
    await agentTunnel.DisposeAsync();

    await using LiveTunnel dcvTunnel = await StartLiveTunnelAsync(credentials, regionName, instanceId, dcvLocalPort, 8443);
    string freshToken = StsPresigner.Presign(immutable, regionName, DateTime.UtcNow);
    string directory = CreateProtectedDcvDirectory();
    string connectionFile = Path.Combine(directory, $"ssm-connect-{Guid.NewGuid():N}.dcv");
    File.WriteAllText(connectionFile, DcvContent(user, $"sessionid={sessionId}\nauthtoken={freshToken}", dcvLocalPort));

    Process? viewer = null;
    try
    {
        viewer = Process.Start(new ProcessStartInfo
        {
            FileName = @"C:\Program Files (x86)\NICE\DCV\Client\bin\dcvviewer.exe",
            UseShellExecute = false,
            ArgumentList =
            {
                $"--connection-file={connectionFile}",
                "--certificate-validation-policy=accept-untrusted",
            },
        });
        if (viewer is null)
        {
            return Fail("DCV Viewer did not start.");
        }
        await Task.Delay(TimeSpan.FromSeconds(5));
        File.Delete(connectionFile);
        await Task.Delay(TimeSpan.FromSeconds(3));
        int connections = await GetDcvConnectionCountAsync(credentials, regionName, instanceId, sessionId);
        if (connections < 1)
        {
            return Fail("DCV server reported no authenticated multi-user client connection.");
        }
        if (viewer.HasExited)
        {
            return Fail($"DCV Viewer exited early with code {viewer.ExitCode}.");
        }

        Console.WriteLine("PASS: presigned STS identity, agent provisioning, secure file deletion, and server-confirmed multi-user DCV connection succeeded.");
        return 0;
    }
    finally
    {
        if (File.Exists(connectionFile))
        {
            File.Delete(connectionFile);
        }
        if (Directory.Exists(directory))
        {
            Directory.Delete(directory);
        }
        if (viewer is not null && !viewer.HasExited)
        {
            viewer.Kill(entireProcessTree: true);
            await viewer.WaitForExitAsync();
        }
        viewer?.Dispose();
    }
}

static async Task<LiveTunnel> StartLiveTunnelAsync(AWSCredentials credentials, string regionName, string instanceId, int localPort, int remotePort)
{
    var ssm = new AmazonSimpleSystemsManagementClient(credentials, Amazon.RegionEndpoint.GetBySystemName(regionName));
    StartSessionResponse session = await ssm.StartSessionAsync(new StartSessionRequest
    {
        Target = instanceId,
        DocumentName = "AWS-StartPortForwardingSession",
        Parameters = new Dictionary<string, List<string>>
        {
            ["portNumber"] = [remotePort.ToString()],
            ["localPortNumber"] = [localPort.ToString()],
        },
    });
    try
    {
        string sessionJson = JsonSerializer.Serialize(new { session.SessionId, session.StreamUrl, session.TokenValue });
        string requestJson = JsonSerializer.Serialize(new
        {
            Target = instanceId,
            DocumentName = "AWS-StartPortForwardingSession",
            Parameters = new Dictionary<string, string[]>
            {
                ["portNumber"] = [remotePort.ToString()],
                ["localPortNumber"] = [localPort.ToString()],
            },
        });
        var startInfo = new ProcessStartInfo
        {
            FileName = @"C:\Program Files\Amazon\SessionManagerPlugin\bin\session-manager-plugin.exe",
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
        };
        foreach (string argument in new[] { sessionJson, regionName, "StartSession", string.Empty, requestJson })
        {
            startInfo.ArgumentList.Add(argument);
        }
        var plugin = new Process { StartInfo = startInfo };
        plugin.Start();
        _ = plugin.StandardOutput.ReadToEndAsync();
        _ = plugin.StandardError.ReadToEndAsync();
        var job = new KillOnCloseJob();
        job.AddProcess(plugin);
        var tunnel = new LiveTunnel(ssm, session.SessionId, plugin, job);
        await tunnel.WaitForListenerAsync(localPort);
        return tunnel;
    }
    catch
    {
        await ssm.TerminateSessionAsync(new TerminateSessionRequest { SessionId = session.SessionId });
        ssm.Dispose();
        throw;
    }
}

static AWSCredentials ResolveCredentials(string profileName)
{
    var chain = new CredentialProfileStoreChain();
    if (!chain.TryGetAWSCredentials(profileName, out AWSCredentials? credentials))
    {
        throw new InvalidOperationException($"AWS SDK could not resolve profile '{profileName}'.");
    }
    if (credentials is SSOAWSCredentials ssoCredentials)
    {
        ssoCredentials.Options.ClientName = "SSM Connect Windows Phase 0 Spike";
        ssoCredentials.Options.SupportsGettingNewToken = true;
        ssoCredentials.Options.SsoVerificationCallback = verification =>
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = verification.VerificationUriComplete,
                UseShellExecute = true,
            });
            Console.WriteLine("AWS SDK opened the IAM Identity Center verification page in the default browser.");
        };
    }
    return credentials;
}

static string CreateProtectedDcvDirectory()
{
    SecurityIdentifier user = WindowsIdentity.GetCurrent().User
        ?? throw new InvalidOperationException("Current Windows identity has no SID.");
    string directory = Path.Combine(Path.GetTempPath(), "SSMConnect", Guid.NewGuid().ToString("N"));
    DirectoryInfo directoryInfo = Directory.CreateDirectory(directory);
    var security = new DirectorySecurity();
    security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
    security.AddAccessRule(new FileSystemAccessRule(user, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
    FileSystemAclExtensions.SetAccessControl(directoryInfo, security);
    return directory;
}

static int ProbeDcvFiles()
{
    string? command = Registry.ClassesRoot.OpenSubKey(@"DcvViewerProgId\shell\open\command")?.GetValue(null) as string;
    if (string.IsNullOrWhiteSpace(command) || !command.Contains("--connection-file", StringComparison.OrdinalIgnoreCase))
    {
        return Fail("DCV Viewer shell registration was not found.");
    }

    SecurityIdentifier user = WindowsIdentity.GetCurrent().User
        ?? throw new InvalidOperationException("Current Windows identity has no SID.");
    string directory = Path.Combine(Path.GetTempPath(), "SSMConnect", "dcv-spike");
    var security = new DirectorySecurity();
    security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
    security.AddAccessRule(new FileSystemAccessRule(user, FileSystemRights.FullControl, InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit, PropagationFlags.None, AccessControlType.Allow));
    DirectoryInfo directoryInfo = Directory.CreateDirectory(directory);
    FileSystemAclExtensions.SetAccessControl(directoryInfo, security);

    string singleUser = Path.Combine(directory, "ssm-connect-single-user.dcv");
    string multiUser = Path.Combine(directory, "ssm-connect-multi-user.dcv");
    File.WriteAllText(singleUser, DcvContent("ec2-user", "password=synthetic-password"));
    File.WriteAllText(multiUser, DcvContent("synthetic-user", "sessionid=synthetic-user\nauthtoken=synthetic-token"));

    FileSecurity fileSecurity = FileSystemAclExtensions.GetAccessControl(new FileInfo(singleUser));
    AuthorizationRuleCollection rules = fileSecurity.GetAccessRules(includeExplicit: true, includeInherited: true, typeof(SecurityIdentifier));
    bool currentUserOnly = rules
        .OfType<FileSystemAccessRule>()
        .Where(rule => rule.AccessControlType == AccessControlType.Allow)
        .All(rule => user.Equals(rule.IdentityReference));
    File.Delete(singleUser);
    File.Delete(multiUser);
    Directory.Delete(directory);

    if (!currentUserOnly)
    {
        return Fail("DCV file granted access to a principal other than the current user.");
    }

    Console.WriteLine("PASS: DCV association supports connection files; both auth formats were created under a current-user-only ACL and deleted.");
    return 0;
}

static string DcvContent(string user, string auth, int port = 58443) => $"""
    [version]
    format=1.0

    [connect]
    host=127.0.0.1
    port={port}
    user={user}
    {auth}
    weburlpath=/
    """;

static async Task<int> ProbeCrashAsync()
{
    string executable = Environment.ProcessPath
        ?? throw new InvalidOperationException("Unable to resolve the spike executable path.");
    using var holder = new Process
    {
        StartInfo = new ProcessStartInfo
        {
            FileName = executable,
            Arguments = "crash-holder",
            UseShellExecute = false,
            RedirectStandardOutput = true,
            CreateNoWindow = true,
        },
    };
    holder.Start();

    string? line = await holder.StandardOutput.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(30));
    if (!int.TryParse(line, out int heldId))
    {
        holder.Kill(entireProcessTree: true);
        return Fail("crash holder did not report the contained child id.");
    }

    // TerminateProcess on the holder only: no finalizers, no Dispose, no
    // graceful shutdown path. The job handle is released by the kernel.
    holder.Kill(entireProcessTree: false);
    await holder.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(10));

    var deadline = TimeSpan.FromSeconds(10);
    var elapsed = Stopwatch.StartNew();
    while (elapsed.Elapsed < deadline)
    {
        try
        {
            using Process survivor = Process.GetProcessById(heldId);
            if (survivor.HasExited)
            {
                break;
            }
        }
        catch (ArgumentException)
        {
            break;
        }

        await Task.Delay(200);
    }

    try
    {
        using Process survivor = Process.GetProcessById(heldId);
        if (!survivor.HasExited)
        {
            survivor.Kill();
            return Fail($"contained child {heldId} survived holder termination.");
        }
    }
    catch (ArgumentException)
    {
        // Expected: the kernel reaped the child with the job.
    }

    Console.WriteLine($"PASS: killing the owner terminated contained child {heldId} in {elapsed.ElapsedMilliseconds} ms without managed cleanup.");
    return 0;
}

static Process StartChild()
{
    string executable = Environment.ProcessPath
        ?? throw new InvalidOperationException("Unable to resolve the spike executable path.");
    var child = new Process
    {
        StartInfo = new ProcessStartInfo
        {
            FileName = executable,
            Arguments = "child",
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            CreateNoWindow = true,
        },
    };
    child.Start();
    return child;
}

static int Fail(string message)
{
    Console.Error.WriteLine($"FAIL: {message}");
    return 1;
}

static async Task<int> ProbeSingleUserAsync(
    string profileName,
    string regionName,
    string instanceId,
    int localPort,
    string secretId,
    string user,
    string expectedSessionId)
{
    AWSCredentials credentials = ResolveCredentials(profileName);
    using var secrets = new AmazonSecretsManagerClient(credentials, Amazon.RegionEndpoint.GetBySystemName(regionName));
    GetSecretValueResponse secret = await secrets.GetSecretValueAsync(new GetSecretValueRequest { SecretId = secretId });
    if (string.IsNullOrEmpty(secret.SecretString))
    {
        return Fail("Secrets Manager returned an empty DCV password.");
    }

    await using LiveTunnel dcvTunnel = await StartLiveTunnelAsync(credentials, regionName, instanceId, localPort, 8443);
    string directory = CreateProtectedDcvDirectory();
    string connectionFile = Path.Combine(directory, $"ssm-connect-{Guid.NewGuid():N}.dcv");
    File.WriteAllText(connectionFile, DcvContent(user, $"password={secret.SecretString}", localPort));
    secret.SecretString = string.Empty;

    Process? viewer = null;
    try
    {
        viewer = Process.Start(new ProcessStartInfo
        {
            FileName = @"C:\Program Files (x86)\NICE\DCV\Client\bin\dcvviewer.exe",
            UseShellExecute = false,
            ArgumentList =
            {
                $"--connection-file={connectionFile}",
                "--certificate-validation-policy=accept-untrusted",
            },
        });
        if (viewer is null)
        {
            return Fail("DCV Viewer did not start.");
        }

        await Task.Delay(TimeSpan.FromSeconds(5));
        File.Delete(connectionFile);
        await Task.Delay(TimeSpan.FromSeconds(3));
        int connections = await GetDcvConnectionCountAsync(credentials, regionName, instanceId, expectedSessionId);
        if (connections < 1)
        {
            return Fail("DCV server reported no authenticated client connection.");
        }
        if (viewer.HasExited)
        {
            return Fail($"DCV Viewer exited early with code {viewer.ExitCode}.");
        }

        Console.WriteLine("PASS: Secrets Manager retrieval, password auto-login, secure file deletion, and server-confirmed single-user DCV connection succeeded.");
        return 0;
    }
    finally
    {
        if (File.Exists(connectionFile))
        {
            File.Delete(connectionFile);
        }
        if (Directory.Exists(directory))
        {
            Directory.Delete(directory);
        }
        if (viewer is not null && !viewer.HasExited)
        {
            viewer.Kill(entireProcessTree: true);
            await viewer.WaitForExitAsync();
        }
        viewer?.Dispose();
    }
}

static async Task<int> GetDcvConnectionCountAsync(
    AWSCredentials credentials,
    string regionName,
    string instanceId,
    string sessionId)
{
    using var ssm = new AmazonSimpleSystemsManagementClient(credentials, Amazon.RegionEndpoint.GetBySystemName(regionName));
    SendCommandResponse sent = await ssm.SendCommandAsync(new SendCommandRequest
    {
        InstanceIds = [instanceId],
        DocumentName = "AWS-RunShellScript",
        Parameters = new Dictionary<string, List<string>>
        {
            ["commands"] = [$"dcv describe-session --json {sessionId}"],
        },
    });
    for (int attempt = 0; attempt < 20; attempt++)
    {
        await Task.Delay(TimeSpan.FromMilliseconds(500));
        try
        {
            GetCommandInvocationResponse invocation = await ssm.GetCommandInvocationAsync(new GetCommandInvocationRequest
            {
                CommandId = sent.Command.CommandId,
                InstanceId = instanceId,
            });
            if (invocation.Status == CommandInvocationStatus.Success)
            {
                using JsonDocument document = JsonDocument.Parse(invocation.StandardOutputContent);
                return document.RootElement.GetProperty("num-of-connections").GetInt32();
            }
            if (invocation.Status == CommandInvocationStatus.Failed ||
                invocation.Status == CommandInvocationStatus.Cancelled ||
                invocation.Status == CommandInvocationStatus.TimedOut)
            {
                throw new InvalidOperationException($"DCV connection check failed with status {invocation.Status}.");
            }
        }
        catch (InvocationDoesNotExistException)
        {
        }
    }
    throw new TimeoutException("Timed out waiting for the DCV connection check.");
}