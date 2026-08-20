using System.Collections.Concurrent;
using Amazon.Runtime;
using SSMConnect.Workflow;

namespace SSMConnect.Aws;

/// <summary>
/// Reuses AWS SDK clients across calls instead of building one per request.
/// </summary>
/// <remarks>
/// A connection makes about a dozen AWS calls, and constructing a client is not free: it resolves
/// the endpoint, builds the pipeline, and wires credentials each time. Building and discarding one
/// per call was measurably the largest avoidable cost in the connect path.
/// <para>
/// Clients are keyed by region and by the access key they were built with, so a re-authentication
/// produces new clients rather than silently reusing ones holding expired credentials. Superseded
/// clients are disposed on eviction. The SDK's clients are thread-safe, so sharing them is the
/// intended usage.
/// </para>
/// </remarks>
internal static class AwsClientCache
{
    private static readonly ConcurrentDictionary<CacheKey, IDisposable> Clients = new();

    private readonly record struct CacheKey(Type ClientType, string Region, string AccessKeyId);

    internal static TClient Get<TClient>(
        AwsCredentials credentials, string region, Func<SessionAWSCredentials, Amazon.RegionEndpoint, TClient> create)
        where TClient : class, IDisposable
    {
        var key = new CacheKey(typeof(TClient), region, credentials.AccessKeyId);
        if (Clients.TryGetValue(key, out IDisposable? existing))
        {
            return (TClient)existing;
        }

        TClient client = create(AwsClients.Session(credentials), AwsClients.Region(region));
        if (Clients.TryAdd(key, client))
        {
            EvictSupersededFor(typeof(TClient), region, credentials.AccessKeyId);
            return client;
        }

        // Another thread won the race; use theirs and drop ours rather than leaking it.
        client.Dispose();
        return (TClient)Clients[key];
    }

    /// <summary>
    /// Drops clients for the same type and region built with different credentials. Without this a
    /// long session would accumulate one client per re-authentication.
    /// </summary>
    private static void EvictSupersededFor(Type clientType, string region, string currentAccessKeyId)
    {
        foreach (CacheKey key in Clients.Keys)
        {
            if (key.ClientType == clientType
                && key.Region == region
                && key.AccessKeyId != currentAccessKeyId
                && Clients.TryRemove(key, out IDisposable? stale))
            {
                stale.Dispose();
            }
        }
    }

    /// <summary>Drops every cached client. Used by tests; the process otherwise keeps them.</summary>
    internal static void Clear()
    {
        foreach (CacheKey key in Clients.Keys)
        {
            if (Clients.TryRemove(key, out IDisposable? client))
            {
                client.Dispose();
            }
        }
    }

    internal static int Count => Clients.Count;
}
