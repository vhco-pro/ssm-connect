using System.Globalization;
using System.Text;

namespace SSMConnect.Domain;

/// <summary>
/// An Amazon DCV connection file (<c>.dcv</c>, INI format) used to auto-login the viewer.
/// </summary>
/// <remarks>
/// Rendering lives in the domain because both clients must produce byte-identical content; writing,
/// permissioning, launching, and deleting the file are platform concerns and live in the adapter.
/// <para>
/// The host is the IPv4 loopback literal, never <c>localhost</c>. The SSM port-forward binds IPv4
/// only, while <c>localhost</c> can resolve to <c>::1</c> first — the viewer then connects to an
/// address with no listener and reports the endpoint as unreachable.
/// </para>
/// </remarks>
public sealed record DcvConnectionFile
{
    public const string TempFilePrefix = "ssm-connect-";
    public const string FileExtension = "dcv";
    public const string DefaultUser = "ec2-user";
    public const string LoopbackHost = "127.0.0.1";

    public string Host { get; init; } = LoopbackHost;
    public required int Port { get; init; }
    public string User { get; init; } = DefaultUser;

    /// <summary>Single-user auth: the Secrets Manager password. Null in multi-user mode.</summary>
    public string? Password { get; init; }

    /// <summary>Multi-user auth: a presigned identity token. Null in single-user mode.</summary>
    public string? AuthToken { get; init; }

    /// <summary>The user's own virtual session. Null targets the default session.</summary>
    public string? SessionId { get; init; }

    public string WebUrlPath { get; init; } = "/";

    /// <summary>Single-user connection: a shared user plus a Secrets Manager password.</summary>
    public static DcvConnectionFile SingleUser(int port, string password, string user = DefaultUser) =>
        new() { Port = port, User = user, Password = password };

    /// <summary>Multi-user connection: the caller's own session, authorised by a presigned token.</summary>
    public static DcvConnectionFile MultiUser(int port, string user, string sessionId, string authToken) =>
        new() { Port = port, User = user, SessionId = sessionId, AuthToken = authToken };

    /// <summary>
    /// Renders the INI content the viewer expects, emitting only the fields relevant to the active
    /// auth mode.
    /// </summary>
    public string ToIni()
    {
        var builder = new StringBuilder();
        builder.Append("[version]\n");
        builder.Append("format=1.0\n");
        builder.Append('\n');
        builder.Append("[connect]\n");
        builder.Append(CultureInfo.InvariantCulture, $"host={Host}\n");
        builder.Append(CultureInfo.InvariantCulture, $"port={Port.ToString(CultureInfo.InvariantCulture)}\n");
        builder.Append(CultureInfo.InvariantCulture, $"user={User}\n");
        if (SessionId is not null)
        {
            builder.Append(CultureInfo.InvariantCulture, $"sessionid={SessionId}\n");
        }

        if (AuthToken is not null)
        {
            builder.Append(CultureInfo.InvariantCulture, $"authtoken={AuthToken}\n");
        }

        if (Password is not null)
        {
            builder.Append(CultureInfo.InvariantCulture, $"password={Password}\n");
        }

        builder.Append(CultureInfo.InvariantCulture, $"weburlpath={WebUrlPath}");
        return builder.ToString();
    }
}
