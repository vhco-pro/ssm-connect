using Amazon.Runtime;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;

internal static class StsPresigner
{
    public static string Presign(ImmutableCredentials credentials, string region, DateTime now, int expiresSeconds = 120)
    {
        string host = $"sts.{region}.amazonaws.com";
        string amzDate = now.ToUniversalTime().ToString("yyyyMMdd'T'HHmmss'Z'", CultureInfo.InvariantCulture);
        string dateStamp = now.ToUniversalTime().ToString("yyyyMMdd", CultureInfo.InvariantCulture);
        string scope = $"{dateStamp}/{region}/sts/aws4_request";
        var query = new List<KeyValuePair<string, string>>
        {
            new("Action", "GetCallerIdentity"),
            new("Version", "2011-06-15"),
            new("X-Amz-Algorithm", "AWS4-HMAC-SHA256"),
            new("X-Amz-Credential", $"{credentials.AccessKey}/{scope}"),
            new("X-Amz-Date", amzDate),
            new("X-Amz-Expires", expiresSeconds.ToString(CultureInfo.InvariantCulture)),
            new("X-Amz-SignedHeaders", "host"),
        };
        if (credentials.UseToken)
        {
            query.Add(new("X-Amz-Security-Token", credentials.Token));
        }

        string canonicalQuery = string.Join("&", query
            .Select(item => new KeyValuePair<string, string>(Encode(item.Key), Encode(item.Value)))
            .OrderBy(item => item.Key, StringComparer.Ordinal)
            .ThenBy(item => item.Value, StringComparer.Ordinal)
            .Select(item => $"{item.Key}={item.Value}"));
        string canonicalRequest = $"GET\n/\n{canonicalQuery}\nhost:{host}\n\nhost\n{Sha256Hex(string.Empty)}";
        string stringToSign = $"AWS4-HMAC-SHA256\n{amzDate}\n{scope}\n{Sha256Hex(canonicalRequest)}";
        byte[] signingKey = Hmac(Hmac(Hmac(Hmac(Encoding.UTF8.GetBytes($"AWS4{credentials.SecretKey}"), dateStamp), region), "sts"), "aws4_request");
        string signature = Convert.ToHexStringLower(HMACSHA256.HashData(signingKey, Encoding.UTF8.GetBytes(stringToSign)));
        return $"https://{host}/?{canonicalQuery}&X-Amz-Signature={signature}";
    }

    private static byte[] Hmac(byte[] key, string value) => HMACSHA256.HashData(key, Encoding.UTF8.GetBytes(value));
    private static string Sha256Hex(string value) => Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(value)));

    private static string Encode(string value)
    {
        var result = new StringBuilder();
        foreach (byte valueByte in Encoding.UTF8.GetBytes(value))
        {
            char character = (char)valueByte;
            if ((character >= 'A' && character <= 'Z') || (character >= 'a' && character <= 'z') ||
                (character >= '0' && character <= '9') || character is '-' or '_' or '.' or '~')
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