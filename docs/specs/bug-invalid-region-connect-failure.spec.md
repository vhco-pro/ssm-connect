# BUG REPORT: Connect fails with opaque "Smithy.ClientError error 4" when a profile's region is empty or malformed

- **Status:** OPEN
- **Severity:** P1 — blocks connection for any profile with an empty or malformed region (notably SSO profiles imported from `~/.aws/config` that omit the `region` key); no in-app workaround, and the surfaced error is undiagnosable to the user.
- **Area:** F-06 (instance resolution) / F-18 (profile config) / error surfacing.
- **Reported:** 2026-07-22.

## Symptom

During Connect, users get:

> Error: The operation couldn't be completed. (Smithy.ClientError error 4.)

The message is opaque; it names no field, no value, and no action. Because SSO authentication uses `ssoRegion` and succeeds first, the failure first bites at the "Finding instance" step, giving no hint that the real cause is a bad `resourceRegion`.

## Root cause (two layers, proven from source)

### Layer 1: the failure

`Smithy.ClientError error 4` is `Smithy.ClientError.invalidValue` (5th case, index 4, of the enum in smithy-swift `Sources/Smithy/ClientError.swift`). In this app it is thrown by the AWS SDK region validator at `AWSClientRuntime` `EndpointResolverMiddleware.swift:56`:

```swift
guard isValidRegion(region) else { throw ClientError.invalidValue("Invalid region: ...") }
```

against the regex `^(?!.*-$)(?!-)[a-zA-Z0-9-]{1,63}$`. This rejects an empty region, whitespace or punctuation, or a value starting or ending with `-`.

The region reaching the SDK is `profile.resourceRegion` for EC2/SSM/Secrets (and `profile.ssoRegion` for auth). Because auth uses `ssoRegion` and succeeds first, a bad `resourceRegion` first bites at the "Finding instance" step: `ConnectionStateMachine.swift:270-274` -> `EC2Service.make(region: profile.resourceRegion)`.

How `resourceRegion` goes bad:

- `AWSConfigParser.swift:76` maps `resourceRegion = profile.region` (the `[profile]` block `region` key). SSO profiles commonly carry only `sso_region` in the `[sso-session]` block and omit `region`, so imported profiles get `resourceRegion = ""`.
- Hand-typed profiles can carry a stray leading/trailing space or a trailing `-`.
- `ConnectionProfile.isConfigured` (`ConnectionProfile.swift:60-64`) only checks `!resourceRegion.isEmpty` (no regex) and only gates auto-connect (`ConnectionStateMachine.swift:158`), not a manual Connect tap.

### Layer 2: the opacity

`ConnectionStateMachine.describe(error)` (`ConnectionStateMachine.swift:669-671`) does:

```swift
(error as? LocalizedError)?.errorDescription ?? error.localizedDescription
```

`Smithy.ClientError` conforms only to `Error` (not `LocalizedError` or `CustomNSError`), so the informative `"Invalid region: ..."` associated string is discarded and the user sees the generic `NSError` bridge string (`Smithy.ClientError error 4`).

## Proposed fix

Keep the change minimal and well-tested. Do not change client construction in the region consumers (`{EC2,SSM,Secrets}Clients.swift`, `Auth/SSOClients.swift`); they are listed for context only. Do not bake in any environment specifics.

1. **New helper** `Models/AWSRegion.swift` — single source of truth for region rules: `normalize(_:) -> String` (trims leading/trailing whitespace) and `isValid(_:) -> Bool` using the exact SDK regex `^(?!.*-$)(?!-)[a-zA-Z0-9-]{1,63}$`. Reused by the parser, the editor, and the pre-flight guard so app rules never drift from the SDK's own rule.
2. **`Services/AWSConfigParser.swift`** — trim region values at parse boundary via `AWSRegion.normalize(_:)` for both `resourceRegion` and `ssoRegion`, so stored profiles are clean (a `region = eu-central-1 ` with a trailing space resolves to `eu-central-1`). A profile omitting `region` still yields an empty `resourceRegion` (parse unchanged); it is caught by the validator, not silently accepted.
3. **`StateMachine/ConnectionStateMachine.swift`** — add a pre-flight guard in `runConnect` (~249+), before authenticating, that validates `resourceRegion` and `ssoRegion` via `AWSRegion.isValid(_:)` and, on failure, throws a typed `LocalizedError` app error `ProfileConfigError.invalidRegion(field:value:)` with an actionable message naming the offending field and value. This gates BOTH the manual Connect path and the auto-connect path (~158) before any SDK call.
4. **`StateMachine/ConnectionStateMachine.swift`** — extend `describe(_:)` (~669-671) to unwrap `Smithy.ClientError`, surfacing its associated string (e.g. `"Invalid region: ..."`), with a general fallback to `String(reflecting:)` extraction for AWS SDK errors that are `Error`-only. Wording stays neutral and actionable; no environment specifics.
5. **`Settings/ProfileEditorView.swift`** — trim the region field on commit and surface inline validation (disable Save or show a field error) when the region is empty or malformed, consistent with existing editor validation patterns.
6. **`Models/ConnectionProfile.swift`** — `isConfigured` (~60-64) uses `AWSRegion.isValid(resourceRegion)` instead of a bare `!isEmpty` check.

## Acceptance Criteria

| ID     | Given | When | Then | Test |
|--------|-------|------|------|------|
| AC-1   | A `[profile]` with `region = eu-central-1 ` (trailing space) | Parsed by `AWSConfigParser` | `resourceRegion == "eu-central-1"` (trimmed, valid) | T-1 |
| AC-2   | A profile omitting the `region` key | Parsed then validated | `resourceRegion == ""` and `AWSRegion.isValid` returns `false` | T-1, T-2 |
| AC-3   | Region inputs `eu-central-1`, `us-east-1` (valid) and ``, ` `, `eu-central-1 `, `-eu`, `eu-`, `eu_central_1`, 64-char string (invalid) | `AWSRegion.isValid` and `normalize` applied | Verdicts match the SDK regex `^(?!.*-$)(?!-)[a-zA-Z0-9-]{1,63}$` semantics | T-2 |
| AC-4   | A profile whose `resourceRegion` is empty or malformed | Connect (manual or auto) is invoked | State machine ends in `.error` with a specific, non-opaque `errorMessage` naming the field and value; the EC2/SSM/Secrets seams are NEVER invoked | T-3 |
| AC-5   | A `Smithy.ClientError.invalidValue("Invalid region: xx")` is thrown | `describe(_:)` maps it | User-facing message contains `"Invalid region"`, NOT the generic `Smithy.ClientError error 4` bridge string | T-4 |
| AC-6   | An empty or malformed region entered in the Profile Editor | Field committed | Save is disabled or a field-level error is shown; a valid region clears it | T-5 |

## Test Plan

Mocked-seam unit tests in `SSMConnectKit`; no live AWS.

| ID   | Target | Type | Assertion | Seam / fixture |
|------|--------|------|-----------|----------------|
| T-1  | `AWSConfigParser` | Unit | Trailing-space `region` trims to valid `eu-central-1`; omitted `region` yields empty `resourceRegion` (parse unchanged) | In-memory config string; no SDK |
| T-2  | `AWSRegion` validator | Unit (table) | Valid set `{eu-central-1, us-east-1}` passes; invalid set `{"", " ", "eu-central-1 ", "-eu", "eu-", "eu_central_1", 64-char}` fails; matches SDK regex semantics | Pure function; no seam |
| T-3  | `ConnectionStateMachine` pre-flight guard | Unit | Empty/malformed `resourceRegion` drives state to `.error` with specific `errorMessage`; assert the mocked EC2/SSM/Secrets seam is NOT invoked | Mocked EC2/SSM/Secrets seams (call-count asserted zero) |
| T-4  | `ConnectionStateMachine.describe(_:)` | Unit | Thrown `Smithy.ClientError.invalidValue("Invalid region: xx")` maps to a message containing `"Invalid region"`, not `Smithy.ClientError error 4` | Constructed `Smithy.ClientError` value |
| T-5  | `ProfileEditorView` region validation | Unit | Empty/malformed region -> Save disabled or field error shown; valid region -> cleared | View-model / validation logic under test |

## Out of scope

- Refactoring client construction in `{EC2,SSM,Secrets}Clients.swift` or `Auth/SSOClients.swift`; these consume the region and are unchanged.
- Broader normalization of other profile fields (account IDs, role ARNs, endpoints) beyond region.
- Auto-populating a missing `region` from `sso_region` or any inference of a default region; the fix validates and reports, it does not guess a region.
- Any environment-specific defaults, instance IDs, or region literals baked into code.
- Changes to the SDK's own validation regex or upstream `smithy-swift` / `AWSClientRuntime` behaviour.

## Assumptions (autonomous mode; all low-risk, reversible)

Recorded for audit at the PR merge gate.

- Region validation is centralized in ONE small helper in `SSMConnectKit` (`AWSRegion` with `normalize(_:) -> String` and `isValid(_:) -> Bool` using the exact SDK regex), reused by the parser, editor, and pre-flight guard. Rationale: single source of truth, avoids drift from the SDK's rule. [Risk: low]
- Both `resourceRegion` AND `ssoRegion` are trimmed and validated (the same failure mode applies to the SSO/OIDC clients built from `ssoRegion`). [Risk: low]
- Values are trimmed at parse and edit boundaries so stored profiles are clean; validation additionally gates connect as defense-in-depth. [Risk: low]
- The pre-flight guard throws a typed `LocalizedError` app error (`ProfileConfigError.invalidRegion(field:value:)`) before any SDK call, on both manual and auto-connect paths. [Risk: low]
- `describe(_:)` gains a mapping that unwraps `Smithy.ClientError` and falls back to `String(reflecting:)` extraction for `Error`-only AWS SDK errors; wording stays neutral and actionable. [Risk: low]
- The Profile Editor surfaces inline validation (disable Save or show a field error), consistent with existing editor patterns. [Risk: low - confirm exact UI affordance during planning by reading `ProfileEditorView.swift`]

## Open questions

- Exact Profile Editor affordance (disable Save vs inline field error): confirm during planning against existing validation patterns in `ProfileEditorView.swift`.
- RESOLVED (2026-07-22): `Smithy.ClientError` is `Error`-only in the vendored SDK; a grep of the entire `smithy-swift` checkout (`SSMConnectKit/.build/checkouts/smithy-swift/Sources/`) finds no `LocalizedError`/`CustomNSError` conformance or any `extension ClientError`, and the declaration is `public enum ClientError: Error` at `Sources/Smithy/ClientError.swift:8`. The Layer-2 fix premise holds against the pinned version.
