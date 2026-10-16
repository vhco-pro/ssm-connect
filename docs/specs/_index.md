# Specs index

| Spec | Date | Description |
|------|------|-------------|
| [macos-trusted-distribution](./macos-trusted-distribution.spec.md) | 2026-10-16 | Organization Developer ID signing, notarization/stapling, restricted CI credentials and final-artifact release gates; pending enrollment and implementation. |
| [ssm-connect](./ssm-connect.spec.md) | 2026-10-16 | Released macOS baseline with local auth freshness/recovery follow-up; real expiry, native-UI and Windows acceptance remain open. |
| [web-forwards](./web-forwards.spec.md) | 2026-10-15 | Shipped SOCKS/PAC and local forwards over SSH-in-SSM, independent from DCV; retained live-test limits are stated. |
| [browser-bootstrap](./browser-bootstrap.spec.md) | 2026-10-15 | Shipped verified Chrome/Zen scopes, owned launch/routing, explicit setup/restore and fail-closed behavior. |
| [remote-vscode](./remote-vscode.spec.md) | 2026-10-16 | Stable-workspace upgrade/relaunch requirements UPGRADE-01 through UPGRADE-06 and automatic lease continuation LEASE-01 through LEASE-08; observed reconnect is not complete automation. |
| [portable-profiles](./portable-profiles.spec.md) | 2026-10-16 | Local macOS and Windows v2 codecs, real export crossing, checked file-backed editing and staged changes; native Windows/UI acceptance remains open. |
| [cross-platform-client](./cross-platform-client.spec.md) | 2026-10-16 | Parallel Windows profile/auth/headless increment is portable-tested and cross-built; current browser/editor adapters and native parity remain open. |
| [bug-invalid-region-connect-failure](./bug-invalid-region-connect-failure.spec.md) | 2026-07-22 | Connect fails with opaque "Smithy.ClientError error 4" when a profile's region is empty or malformed; trim and validate region against the SDK regex, add a pre-flight guard, and unwrap the SDK error message. |
