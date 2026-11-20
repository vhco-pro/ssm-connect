# FixtureRecorder

Records what the current aws-sdk-swift based code does, so the parity tests in
`SSMConnectKit/AWSClient` can hold SSM Connect's own AWS client to it (AC-28 in
`docs/specs/cross-platform-client.spec.md`). `Package.resolved` is a copy of the
app's, so the recorder runs the SDK version the app ships.

```sh
swift build --build-system native
.build/debug/FixtureRecorder endpoints ../../AWSClient/Tests/SSMConnectAWSClientTests/Fixtures/endpoints.json
```

On Linux the build needs the OpenSSL headers (`libssl-dev`) for aws-crt-swift, and
Swift 6.4.2's default build system fails on an aws-sdk-swift build-tool plugin, so
use `--build-system native`. Run it with no `AWS_ENDPOINT_URL*` variables set.

| Command | Writes |
| --- | --- |
| `endpoints <file>` | each client's default resolver output, without an endpoint override, per service and region |
