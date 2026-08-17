using Amazon.SimpleSystemsManagement;
using Amazon.SimpleSystemsManagement.Model;
using System.Diagnostics;
using System.Net.Sockets;

internal sealed class LiveTunnel(
    AmazonSimpleSystemsManagementClient ssm,
    string sessionId,
    Process plugin,
    KillOnCloseJob job) : IAsyncDisposable
{
    private bool disposed;

    public async Task WaitForListenerAsync(int localPort)
    {
        DateTime deadline = DateTime.UtcNow.AddSeconds(15);
        while (DateTime.UtcNow < deadline && !plugin.HasExited)
        {
            using var client = new TcpClient();
            try
            {
                await client.ConnectAsync("127.0.0.1", localPort).WaitAsync(TimeSpan.FromMilliseconds(500));
                return;
            }
            catch (Exception error) when (error is SocketException or TimeoutException)
            {
                await Task.Delay(250);
            }
        }
        throw new InvalidOperationException($"Plugin did not listen on 127.0.0.1:{localPort}.");
    }

    public async ValueTask DisposeAsync()
    {
        if (disposed)
        {
            return;
        }
        disposed = true;
        job.Dispose();
        if (!plugin.HasExited)
        {
            await plugin.WaitForExitAsync().WaitAsync(TimeSpan.FromSeconds(5));
        }
        plugin.Dispose();
        await ssm.TerminateSessionAsync(new TerminateSessionRequest { SessionId = sessionId });
        ssm.Dispose();
    }
}