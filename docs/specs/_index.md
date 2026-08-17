# Specs index

| Spec | Date | Description |
|------|------|-------------|
| [cross-platform-client](./cross-platform-client.spec.md) | 2026-08-17 | Refactor the macOS package into explicit domain, workflow, AWS, and platform boundaries; add a native .NET Windows tray client governed by shared contracts and conformance fixtures. |
| [bug-invalid-region-connect-failure](./bug-invalid-region-connect-failure.spec.md) | 2026-07-22 | Connect fails with opaque "Smithy.ClientError error 4" when a profile's region is empty or malformed; trim and validate region against the SDK regex, add a pre-flight guard, and unwrap the SDK error message. |
