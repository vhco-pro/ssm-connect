using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using SSMConnect.Workflow;

namespace SSMConnect.Aws;

/// <summary>
/// Builds a presigned <c>sts:GetCallerIdentity</c> URL, which is the identity token the workstation
/// agent verifies for multi-user connections.
/// </summary>
/// <remarks>
/// Signed by hand rather than through the SDK because the agent needs the URL itself, not the
/// result of calling it: the agent re-issues the request against STS to prove the caller holds the
/// credentials. The short expiry is deliberate — the token is minted immediately before each use
/// and is never stored.
/// </remarks>
public static class StsPresigner
{
    /// <summary>Default validity. Long enough to reach the agent, short enough to be worthless if leaked.</summary>
    public const int DefaultExpirySeconds = 120;

    public static string Presign(
        AwsCredentials credentials, string region, DateTimeOffset now, int expiresSeconds = DefaultExpirySeconds)
    {
        string host = $"sts.{region}.amazonaws.com";
        DateTimeOffset utc = now.ToUniversalTime();
        string amzDate = utc.ToString("yyyyMMdd'T'HHmmss'Z'", CultureInfo.InvariantCulture);
        string dateStamp = utc.ToString("yyyyMMdd", CultureInfo.InvariantCulture);
        string scope = $"{dateStamp}/{region}/sts/aws4_request";

        var query = new List<KeyValuePair<string, string>>
        {
            new("Action", "GetCallerIdentity"),
            new("Version", "2011-06-15"),
            new("X-Amz-Algorithm", "AWS4-HMAC-SHA256"),
            new("X-Amz-Credential", $"{credentials.AccessKeyId}/{scope}"),
            new("X-Amz-Date", amzDate),
            new("X-Amz-Expires", expiresSeconds.ToString(CultureInfo.InvariantCulture)),
            new("X-Amz-SignedHeaders", "host"),
        };

        if (!string.IsNullOrEmpty(credentials.SessionToken))
        {
            query.Add(new KeyValuePair<string, string>("X-Amz-Security-Token", credentials.SessionToken));
        }

        string canonicalQuery = string.Join("&", query
            .Select(item => new KeyValuePair<string, string>(Encode(item.Key), Encode(item.Value)))
            .OrderBy(item => item.Key, StringComparer.Ordinal)
            .ThenBy(item => item.Value, StringComparer.Ordinal)
            .Select(item => $"{item.Key}={item.Value}"));

        string canonicalRequest = $"GET\n/\n{canonicalQuery}\nhost:{host}\n\nhost\n{Sha256Hex(string.Empty)}";
        string stringToSign = $"AWS4-HMAC-SHA256\n{amzDate}\n{scope}\n{Sha256Hex(canonicalRequest)}";

        byte[] signingKey = Hmac(
            Hmac(Hmac(Hmac(Encoding.UTF8.GetBytes($"AWS4{credentials.SecretAccessKey}"), dateStamp), region), "sts"),
            "aws4_request");
        string signature = Convert.ToHexStringLower(
            HMACSHA256.HashData(signingKey, Encoding.UTF8.GetBytes(stringToSign)));

        return $"https://{host}/?{canonicalQuery}&X-Amz-Signature={signature}";
    }

    private static byte[] Hmac(byte[] key, string value) =>
        HMACSHA256.HashData(key, Encoding.UTF8.GetBytes(value));

    private static string Sha256Hex(string value) =>
        Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(value)));

    /// <summary>
    /// RFC 3986 unreserved-set encoding. The SDK's URL encoders differ in which characters they
    /// leave alone, and SigV4 canonicalisation is byte-exact, so this is spelled out here.
    /// </summary>
    private static string Encode(string value)
    {
        var result = new StringBuilder();
        foreach (byte valueByte in Encoding.UTF8.GetBytes(value))
        {
            char character = (char)valueByte;
            if (char.IsAsciiLetterOrDigit(character) || character is '-' or '_' or '.' or '~')
            {
                result.Append(character);
            }
            else
            {
                result.Append('%').Append(valueByte.ToString("X2", CultureInfo.InvariantCulture));
            }
        }

        return result.ToString();
    }
}
