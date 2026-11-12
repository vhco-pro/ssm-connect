using Amazon;
using Amazon.EC2;
using Amazon.EC2.Model;
using Amazon.Runtime;
using Amazon.SecretsManager;
using Amazon.SecretsManager.Model;
using Amazon.SecurityToken;
using Amazon.SecurityToken.Model;
using Amazon.SimpleSystemsManagement;
using Amazon.SimpleSystemsManagement.Model;
using SSMConnect.Domain;
using SSMConnect.Workflow;
using Ec2Filter = Amazon.EC2.Model.Filter;
using Ec2Instance = SSMConnect.Domain.Ec2Instance;

namespace SSMConnect.Aws;

/// <summary>
/// Translates AWS SDK failures into the workflow's typed errors.
/// </summary>
/// <remarks>
/// Provider messages and inner exceptions can contain request URLs or credentials. Only safe,
/// fixed messages cross the adapter boundary.
/// </remarks>
public static class AwsErrors
{
    public static Exception Translate(Exception error) => error switch
    {
        ExpiredCredentialsException or SignInRequiredException or ConnectionException => error,
        AmazonServiceException service when IsExpiry(service) => new ExpiredCredentialsException(),
        AmazonServiceException { ErrorCode: "AccessDenied" or "AccessDeniedException" or "ForbiddenException" } =>
            new AuthorizationAccessDeniedException(),
        AmazonServiceException { StatusCode: System.Net.HttpStatusCode.Forbidden } =>
            new AuthorizationAccessDeniedException(),
        HttpRequestException or System.Net.Sockets.SocketException or IOException => new AuthorizationUnavailableException(),
        AmazonServiceException { InnerException: HttpRequestException or System.Net.Sockets.SocketException or IOException } =>
            new AuthorizationUnavailableException(),
        AmazonServiceException => new AwsServiceException("AWS could not complete the operation. Check network connectivity and account permissions."),
        _ => error,
    };

    /// <summary>Runs an AWS call, translating whatever it throws.</summary>
    public static async Task<T> GuardAsync<T>(Func<Task<T>> operation)
    {
        try
        {
            return await operation().ConfigureAwait(false);
        }
        catch (Exception error) when (error is not OperationCanceledException)
        {
            throw Translate(error);
        }
    }

    private static bool IsExpiry(AmazonServiceException error) =>
        error.ErrorCode is "ExpiredToken" or "ExpiredTokenException" or "RequestExpired"
            or "UnauthorizedAccess" or "InvalidClientTokenId" or "UnauthorizedException"
            or "UnrecognizedClientException"
        || error.StatusCode == System.Net.HttpStatusCode.Unauthorized
        || error is AmazonSecurityTokenServiceException { ErrorCode: "ExpiredToken" };

}

/// <summary>Builds SDK clients from the workflow's credential value type.</summary>
internal static class AwsClients
{
    internal static SessionAWSCredentials Session(AwsCredentials credentials) =>
        new(credentials.AccessKeyId, credentials.SecretAccessKey, credentials.SessionToken);

    internal static RegionEndpoint Region(string region) => RegionEndpoint.GetBySystemName(region);
}

public sealed class Ec2Adapter : IEc2Provider
{
    public async Task<Ec2Instance> ResolveInstanceAsync(
        string tagKey, string tagValue, string region, AwsCredentials credentials, CancellationToken cancellationToken)
    {
        AmazonEC2Client client = AwsClientCache.Get(credentials, region, (c, r) => new AmazonEC2Client(c, r));
        DescribeInstancesResponse response = await AwsErrors.GuardAsync(() =>
            client.DescribeInstancesAsync(new DescribeInstancesRequest
            {
                Filters = [new Ec2Filter($"tag:{tagKey}", [tagValue])],
            }, cancellationToken)).ConfigureAwait(false);

        Amazon.EC2.Model.Instance? instance = response.Reservations
            .SelectMany(reservation => reservation.Instances)
            .Where(candidate => Ec2InstanceStateNames.Parse(candidate.State?.Name?.Value) is not Ec2InstanceState.Terminated)
            .OrderByDescending(candidate => candidate.LaunchTime ?? DateTime.MinValue)
            .FirstOrDefault()
            ?? response.Reservations.SelectMany(reservation => reservation.Instances).FirstOrDefault();

        if (instance is null)
        {
            throw new AwsServiceException(
                $"No EC2 instance is tagged {tagKey}={tagValue} in {region}.");
        }

        return new Ec2Instance(
            instance.InstanceId,
            Ec2InstanceStateNames.Parse(instance.State?.Name?.Value),
            instance.PrivateIpAddress);
    }

    public async Task StartInstanceAsync(
        string instanceId, string region, AwsCredentials credentials, CancellationToken cancellationToken)
    {
        AmazonEC2Client client = AwsClientCache.Get(credentials, region, (c, r) => new AmazonEC2Client(c, r));
        await AwsErrors.GuardAsync(() => client.StartInstancesAsync(
            new StartInstancesRequest { InstanceIds = [instanceId] }, cancellationToken)).ConfigureAwait(false);
    }

    public async Task<Ec2Instance> PollUntilRunningAsync(
        string instanceId, string region, AwsCredentials credentials,
        TimeSpan timeout, TimeSpan interval, CancellationToken cancellationToken)
    {
        AmazonEC2Client client = AwsClientCache.Get(credentials, region, (c, r) => new AmazonEC2Client(c, r));
        DateTimeOffset deadline = DateTimeOffset.UtcNow + timeout;

        while (DateTimeOffset.UtcNow < deadline)
        {
            cancellationToken.ThrowIfCancellationRequested();
            DescribeInstancesResponse response = await AwsErrors.GuardAsync(() =>
                client.DescribeInstancesAsync(new DescribeInstancesRequest { InstanceIds = [instanceId] },
                    cancellationToken)).ConfigureAwait(false);

            Amazon.EC2.Model.Instance? instance = response.Reservations
                .SelectMany(reservation => reservation.Instances).FirstOrDefault();
            Ec2InstanceState state = Ec2InstanceStateNames.Parse(instance?.State?.Name?.Value);

            if (state == Ec2InstanceState.Running)
            {
                return new Ec2Instance(instanceId, state, instance?.PrivateIpAddress);
            }

            if (state.IsTerminal())
            {
                throw new InstanceTerminatedException(instanceId);
            }

            await Task.Delay(interval, cancellationToken).ConfigureAwait(false);
        }

        throw new StageTimeoutException("Starting the workstation");
    }

    public async Task StopInstanceAsync(
        string instanceId, string region, AwsCredentials credentials, CancellationToken cancellationToken)
    {
        AmazonEC2Client client = AwsClientCache.Get(credentials, region, (c, r) => new AmazonEC2Client(c, r));
        await AwsErrors.GuardAsync(() => client.StopInstancesAsync(
            new StopInstancesRequest { InstanceIds = [instanceId] }, cancellationToken)).ConfigureAwait(false);
    }
}

public sealed class SsmAdapter : ISsmProvider
{
    /// <summary>The AWS-managed document that opens a port forward.</summary>
    public const string PortForwardDocument = "AWS-StartPortForwardingSession";

    public async Task WaitForSsmOnlineAsync(
        string instanceId, string region, AwsCredentials credentials,
        TimeSpan timeout, TimeSpan interval, CancellationToken cancellationToken)
    {
        AmazonSimpleSystemsManagementClient client = AwsClientCache.Get(
            credentials, region, (c, r) => new AmazonSimpleSystemsManagementClient(c, r));
        DateTimeOffset deadline = DateTimeOffset.UtcNow + timeout;

        while (DateTimeOffset.UtcNow < deadline)
        {
            cancellationToken.ThrowIfCancellationRequested();
            DescribeInstanceInformationResponse response = await AwsErrors.GuardAsync(() =>
                client.DescribeInstanceInformationAsync(new DescribeInstanceInformationRequest
                {
                    Filters = [new InstanceInformationStringFilter { Key = "InstanceIds", Values = [instanceId] }],
                }, cancellationToken)).ConfigureAwait(false);

            if (response.InstanceInformationList.Any(info => info.PingStatus == PingStatus.Online))
            {
                return;
            }

            await Task.Delay(interval, cancellationToken).ConfigureAwait(false);
        }

        throw new StageTimeoutException("Waiting for SSM");
    }

    public async Task<SsmSession> StartSessionAsync(
        string instanceId, string region, AwsCredentials credentials,
        int localPort, int remotePort, CancellationToken cancellationToken)
    {
        AmazonSimpleSystemsManagementClient client = AwsClientCache.Get(
            credentials, region, (c, r) => new AmazonSimpleSystemsManagementClient(c, r));
        StartSessionResponse response = await AwsErrors.GuardAsync(() =>
            client.StartSessionAsync(new StartSessionRequest
            {
                Target = instanceId,
                DocumentName = PortForwardDocument,
                Parameters = new Dictionary<string, List<string>>
                {
                    ["portNumber"] = [remotePort.ToString(System.Globalization.CultureInfo.InvariantCulture)],
                    ["localPortNumber"] = [localPort.ToString(System.Globalization.CultureInfo.InvariantCulture)],
                },
            }, cancellationToken)).ConfigureAwait(false);

        return new SsmSession(response.SessionId, response.StreamUrl, response.TokenValue);
    }

    /// <summary>
    /// Terminates sessions this caller left open against the target.
    /// </summary>
    /// <remarks>
    /// Only sessions whose owner matches this caller's identity are touched. Filtering on the target
    /// alone would let one user tear down another user's session on a shared workstation, which on a
    /// multi-user host is exactly the wrong outcome.
    /// </remarks>
    public async Task<int> ReapOrphanedSessionsAsync(
        string instanceId, string region, AwsCredentials credentials, CancellationToken cancellationToken)
    {
        AmazonSecurityTokenServiceClient sts = AwsClientCache.Get(
            credentials, region, (c, r) => new AmazonSecurityTokenServiceClient(c, r));
        GetCallerIdentityResponse identity = await AwsErrors.GuardAsync(() =>
            sts.GetCallerIdentityAsync(new GetCallerIdentityRequest(), cancellationToken)).ConfigureAwait(false);

        AmazonSimpleSystemsManagementClient client = AwsClientCache.Get(
            credentials, region, (c, r) => new AmazonSimpleSystemsManagementClient(c, r));
        DescribeSessionsResponse response = await AwsErrors.GuardAsync(() =>
            client.DescribeSessionsAsync(new DescribeSessionsRequest
            {
                State = SessionState.Active,
                Filters = [new SessionFilter { Key = SessionFilterKey.Target, Value = instanceId }],
            }, cancellationToken)).ConfigureAwait(false);

        // The caller ARN is an assumed-role ARN; the session owner is reported in the same shape,
        // so an ordinal comparison is the right test.
        int reaped = 0;
        foreach (Session session in response.Sessions.Where(
                     candidate => string.Equals(candidate.Owner, identity.Arn, StringComparison.Ordinal)))
        {
            await AwsErrors.GuardAsync(() => client.TerminateSessionAsync(
                new TerminateSessionRequest { SessionId = session.SessionId }, cancellationToken))
                .ConfigureAwait(false);
            reaped++;
        }

        return reaped;
    }

    /// <summary>
    /// Asks AWS what state a session is in. Used to establish whether an abnormally exited client
    /// leaves its session open, which local process containment cannot answer (AC-07).
    /// </summary>
    public static async Task<string> DescribeSessionStateAsync(
        string sessionId, string region, AwsCredentials credentials, CancellationToken cancellationToken = default)
    {
        AmazonSimpleSystemsManagementClient client = AwsClientCache.Get(
            credentials, region, (c, r) => new AmazonSimpleSystemsManagementClient(c, r));

        foreach (SessionState state in new[] { SessionState.Active, SessionState.History })
        {
            DescribeSessionsResponse response = await AwsErrors.GuardAsync(() =>
                client.DescribeSessionsAsync(new DescribeSessionsRequest
                {
                    State = state,
                    Filters = [new SessionFilter { Key = SessionFilterKey.SessionId, Value = sessionId }],
                }, cancellationToken)).ConfigureAwait(false);

            Session? found = response.Sessions.FirstOrDefault();
            if (found is not null)
            {
                return found.Status?.Value ?? state.Value;
            }
        }

        return "NotFound";
    }

    /// <summary>
    /// Terminates a session server-side. The workflow's local process containment does not do this,
    /// so an abnormal exit can otherwise leave a session open until it times out (AC-07).
    /// </summary>
    public async Task TerminateSessionAsync(
        string sessionId, string region, AwsCredentials credentials, CancellationToken cancellationToken = default)
    {
        AmazonSimpleSystemsManagementClient client = AwsClientCache.Get(
            credentials, region, (c, r) => new AmazonSimpleSystemsManagementClient(c, r));
        await AwsErrors.GuardAsync(() => client.TerminateSessionAsync(
            new TerminateSessionRequest { SessionId = sessionId }, cancellationToken)).ConfigureAwait(false);
    }
}

public sealed class SecretsAdapter : ISecretsProvider
{
    public async Task<string> FetchSecretAsync(
        string secretId, string region, AwsCredentials credentials, CancellationToken cancellationToken)
    {
        AmazonSecretsManagerClient client = AwsClientCache.Get(
            credentials, region, (c, r) => new AmazonSecretsManagerClient(c, r));
        GetSecretValueResponse response = await AwsErrors.GuardAsync(() =>
            client.GetSecretValueAsync(new GetSecretValueRequest { SecretId = secretId }, cancellationToken))
            .ConfigureAwait(false);

        return response.SecretString
            ?? throw new AwsServiceException($"Secret {secretId} has no string value.");
    }
}

/// <summary>
/// Resolves the caller's identity and mints the presigned tokens the workstation agent verifies.
/// </summary>
public sealed class StsIdentityAdapter : IIdentityProvider
{
    private readonly Func<DateTimeOffset> _now;

    public StsIdentityAdapter(Func<DateTimeOffset>? now = null) => _now = now ?? (() => DateTimeOffset.UtcNow);

    public async Task<string> ResolveIdentityAsync(
        string region, AwsCredentials credentials, CancellationToken cancellationToken)
    {
        AmazonSecurityTokenServiceClient client = AwsClientCache.Get(
            credentials, region, (c, r) => new AmazonSecurityTokenServiceClient(c, r));
        GetCallerIdentityResponse identity = await AwsErrors.GuardAsync(() =>
            client.GetCallerIdentityAsync(new GetCallerIdentityRequest(), cancellationToken)).ConfigureAwait(false);

        // The mapping rule is domain, not adapter: it is shared byte-for-byte with the macOS client
        // and the workstation agent.
        return IdentityMapper.UsernameFromArn(identity.Arn);
    }

    public string PresignedIdentityToken(string region, AwsCredentials credentials) =>
        StsPresigner.Presign(credentials, region, _now());
}
