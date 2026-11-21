# FixtureRecorder

Records what the current aws-sdk-swift based code does, so the parity tests in
`SSMConnectKit/AWSClient` can hold SSM Connect's own AWS client to it (AC-28 in
`docs/specs/cross-platform-client.spec.md`). `Package.resolved` is a copy of the
app's, so the recorder runs the SDK version the app ships.

```sh
swift build --build-system native
.build/debug/FixtureRecorder endpoints ../../AWSClient/Tests/SSMConnectAWSClientTests/Fixtures/endpoints.json
.build/debug/FixtureRecorder requests ../../AWSClient/Tests/SSMConnectAWSClientTests/Fixtures/requests
.build/debug/FixtureRecorder retries ../../AWSClient/Tests/SSMConnectAWSClientTests/Fixtures/retries
.build/debug/FixtureRecorder skew ../../AWSClient/Tests/SSMConnectAWSClientTests/Fixtures/skew
```

On Linux the build needs the OpenSSL headers (`libssl-dev`) for aws-crt-swift, and
Swift 6.4.2's default build system fails on an aws-sdk-swift build-tool plugin, so
use `--build-system native`. Run it with no `AWS_ENDPOINT_URL*` variables set.

| Command | Writes |
| --- | --- |
| `endpoints <file>` | each client's default resolver output, without an endpoint override, per service and region |
| `requests <dir>` | for each SDK operation the app calls, with the app's inputs: the request sent to a loopback server, the canned success response, and the decoded fields the app reads |
| `retries <dir>` | for scripted failure sequences (throttling, 5xx, 408, a dropped connection, denials, an ignored retry-after header, and the SSO OIDC errors device polling handles), the SDK's attempts, the delays between them and the outcome, with no retry settings configured |
| `skew <dir>` | for skew errors (`AuthFailure`, `RequestExpired`, `InvalidSignatureException`) and a non-skew denial, answered with a `Date` header far ahead, far behind, near, missing, or after the clock is repaired, and for two concurrent failing calls on one client: the SDK's attempts, each attempt's signing time relative to local time, and the outcome |
