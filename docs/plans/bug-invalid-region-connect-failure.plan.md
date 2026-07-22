---
status: review
status_description: "All 5 phases implemented and green: AWSRegion helper (T-2), parser trim + isConfigured region validation (T-1), pre-flight connect guard + ProfileConfigError (T-3), describe(_:) Smithy.ClientError unwrap (T-4), ProfileEditor inline validation via extracted seam (T-5). Full suite: 140 tests, 25 suites, 0 failures (GIT_CONFIG_VALUE_0=all swift test --package-path SSMConnectKit). Ready for review."
description: "Fix opaque Smithy.ClientError error 4 on Connect when a profile region is empty or malformed: centralized region validation, pre-flight guard, and error unwrapping."
spec: docs/specs/bug-invalid-region-connect-failure.spec.md
author: "SDD Planner (automated), run by michielvha <michielvh@outlook.com>"
goal: "Turn the undiagnosable 'Smithy.ClientError error 4' region failure into a caught, field-and-value-specific, actionable error, and prevent bad regions from ever reaching the AWS SDK."
priority: high
created: 2026-07-22
slug: bug-invalid-region-connect-failure
lifecycle: transactional
---

# Plan: Fix opaque region-failure on Connect (Smithy.ClientError error 4)

Translates `docs/specs/bug-invalid-region-connect-failure.spec.md` into a minimal, well-tested change in the `SSMConnectKit` SwiftPM package: a single region-rules helper, a parse/edit trim, a pre-flight connect guard, and an error-unwrap in `describe(_:)`, so an empty or malformed `resourceRegion`/`ssoRegion` fails fast with a message naming the offending field and value instead of the generic `NSError` bridge string.

## Table of Contents

1. Context
2. Dependencies
3. Scope
4. Design
5. Acceptance Criteria
6. Implementation Phases
7. Test Plan
8. Implementation Order
9. File Reference Summary
10. Open Questions

## Context

This is a native macOS SwiftUI menu-bar app; all code and tests live in the `SSMConnectKit` SwiftPM package (`SSMConnectKit/Sources/SSMConnectKit/`, tests under `SSMConnectKit/Tests/SSMConnectKitTests/`). There is no Engie cloud archetype here: no container, GitOps, Terraform, or service-mesh work applies. The quality gate is `swift test` (or the repo test target).

The bug has two proven layers (see spec §"Root cause"):

- **Layer 1 (the failure).** `profile.resourceRegion` reaches the AWS SDK region validator and is rejected against `^(?!.*-$)(?!-)[a-zA-Z0-9-]{1,63}$`, throwing `Smithy.ClientError.invalidValue`. SSO profiles imported from `~/.aws/config` commonly omit the `[profile]` `region` key (they carry only `sso_region` on the `[sso-session]` block), so `AWSConfigParser.resolvedProfile(named:)` (`AWSConfigParser.swift:76`) yields `resourceRegion = ""`. Auth uses `ssoRegion` and succeeds first, so the failure first bites at the "Finding instance" step: `ConnectionStateMachine.runConnect()` (`ConnectionStateMachine.swift:268-277`) calls `ec2.resolveInstance(..., region: profile.resourceRegion, ...)`, whose first act is `makeClient(credentials, region)` (`EC2Service.swift:25`, `EC2Clients.swift` `EC2ClientFactory.make`) where the SDK region validator throws.
- **Layer 2 (the opacity).** `ConnectionStateMachine.describe(_:)` (`ConnectionStateMachine.swift:669-671`) does `(error as? LocalizedError)?.errorDescription ?? error.localizedDescription`. `Smithy.ClientError` is `Error`-only (confirmed: `public enum ClientError: Error` at `.build/checkouts/smithy-swift/Sources/Smithy/ClientError.swift:8`, 5 cases, `invalidValue` is index 4), so the informative `"Invalid region: ..."` associated string is discarded and the user sees `The operation couldn't be completed. (Smithy.ClientError error 4.)`.

Current weak spots this plan closes:
- `ConnectionProfile.isConfigured` (`ConnectionProfile.swift:63-67`) checks only `!resourceRegion.isEmpty`, with no regex, and gates only auto-connect (`ConnectionStateMachine.swift:158`), never a manual Connect tap.
- `ProfileEditorView.isValid` (`ProfileEditorView.swift:83-94`) checks only `!trimmed(resourceRegion).isEmpty` (and does not validate `ssoRegion` format at all), so a malformed-but-non-empty region passes Save.

`Smithy.ClientError` is constructible in the test target via `import Smithy` (the module is already a transitive dependency; `EC2Clients.swift` imports the sibling `SmithyIdentity`). This makes T-4 directly compilable: `Smithy.ClientError.invalidValue("Invalid region: xx")`.

## Dependencies

- Existing `SSMConnectKit` package builds and tests green (`swift test`).
- Swift Testing framework (`import Testing`, `@Suite`/`@Test`/`#expect`), already used across the suite (e.g. `ConnectionStateMachineTests.swift`).
- Existing state-machine test doubles (`StateMachine/StateMachineTestDoubles.swift`, `ConnectionProfileExample.swift`) reused as-is; T-3 needs one small addition (call-count-asserting EC2/SSM/Secrets doubles, see Phase 3).
- `Smithy` module resolvable from the test target for T-4 (verified present in `.build/checkouts/smithy-swift`).

Build/test caveat (project knowledge): SwiftPM / xcodebuild in this environment must be prefixed with `GIT_CONFIG_VALUE_0=all` to avoid a git-config hang, e.g.:

```
GIT_CONFIG_VALUE_0=all swift test --package-path SSMConnectKit
```

Use the repo `Makefile` test target if one exists; otherwise the command above is the per-phase quality gate.

## Scope

### In Scope

- New `Models/AWSRegion.swift`: `normalize(_:) -> String` (trim) and `isValid(_:) -> Bool` using the exact SDK regex. Single source of truth reused by parser, editor, and guard.
- New typed `LocalizedError` app error `ProfileConfigError.invalidRegion(field:value:)`.
- `AWSConfigParser.swift`: trim `resourceRegion` and `ssoRegion` at the parse boundary via `AWSRegion.normalize(_:)` (omitted `region` still yields empty; parse otherwise unchanged).
- `ConnectionStateMachine.swift`: pre-flight guard in `runConnect()` validating both regions before authenticating (covers manual and auto paths); extend `describe(_:)` to unwrap `Smithy.ClientError` with a general `Error`-only fallback.
- `ConnectionProfile.swift`: `isConfigured` uses `AWSRegion.isValid(resourceRegion)`.
- `ProfileEditorView.swift`: trim region on commit and surface inline validation (disable Save + inline field error), with the validation predicate extracted to a testable seam.
- Unit tests T-1..T-5, plus a full mocked-seam state-machine drive-through and a manual-verification row.

### Out of Scope

- Client construction in `{EC2,SSM,Secrets}Clients.swift` / `Auth/SSOClients.swift` (they consume the region; unchanged; listed for context only).
- Normalizing other profile fields (account IDs, role ARNs, endpoints).
- Auto-populating a missing `region` from `sso_region` or inferring any default region: the fix validates and reports, it does not guess.
- Any environment-specific defaults, instance IDs, or region literals in code.
- Changes to the SDK's own regex or upstream `smithy-swift` / `AWSClientRuntime` behavior.

## Design

### Region validation as a single source of truth

```mermaid
flowchart TD
    A["~/.aws/config text"] -->|AWSConfigParser.normalize| B["ConnectionProfile\n(resourceRegion, ssoRegion trimmed)"]
    B --> C{ProfileEditorView\nisValid + inline error}
    C -->|Save| B
    B --> D["ConnectionStateMachine.runConnect()\npre-flight guard"]
    D -->|AWSRegion.isValid == false| E["throw ProfileConfigError.invalidRegion(field,value)"]
    E --> F["catch -> teardownTunnel + fail(error)"]
    F --> G["describe(error) -> LocalizedError.errorDescription\nstate = .error, errorMessage set"]
    D -->|valid| H["authenticate -> resolveInstance -> ... (SDK seams)"]
    H -.->|residual SDK region reject| I["Smithy.ClientError.invalidValue(\"Invalid region: ...\")"]
    I --> G2["describe(error) unwraps Smithy.ClientError\n-> associated string surfaced"]
    subgraph helper["Models/AWSRegion.swift (single rule)"]
      R["isValid(_:) uses ^(?!.*-$)(?!-)[a-zA-Z0-9-]{1,63}$\nnormalize(_:) trims whitespace"]
    end
    A -.-> R
    C -.-> R
    D -.-> R
```

<details>
<summary>Legend</summary>

- Solid arrows: primary data/control flow.
- Dotted arrows to `helper`: all three call sites share the one `AWSRegion` rule so app validation never drifts from the SDK's own regex.
- The pre-flight guard (`D`) is the primary defense: no SDK seam is invoked for a bad region. The `describe(_:)` unwrap (`G2`) is the belt-and-suspenders fallback for any residual SDK-thrown region error (or other `Error`-only AWS SDK errors).
</details>

### Key design decisions

- **One helper, three call sites.** `AWSRegion` holds the regex once; parser, editor, and guard all call it. Keeps app rules aligned with the SDK's rule (spec assumption, low risk).
- **Both regions validated.** `ssoRegion` feeds the SSO/OIDC clients and has the same failure mode, so the guard validates `resourceRegion` and `ssoRegion`; the parser trims both.
- **Guard placed before `state = .authenticating`.** `runConnect()` is the single funnel for both manual `connect()` and auto-connect (`onLaunch()` -> `connect()`), so one guard covers both paths and throws before any seam call. The existing `do/catch` at the bottom of `runConnect()` routes the thrown `ProfileConfigError` through `teardownTunnel()` + `fail(_:)`, which sets `state = .error` and `errorMessage = describe(error)`. Since `ProfileConfigError` is a `LocalizedError`, its `errorDescription` is surfaced directly.
- **`describe(_:)` unwrap.** Add a branch that, for `Smithy.ClientError`, returns its associated string (switch over the 5 cases, or extract via `String(reflecting:)`), plus a general `String(reflecting:)`-based fallback for other `Error`-only AWS SDK errors. Wording stays neutral; no environment specifics. This is defense-in-depth: with the guard in place the app should never reach the SDK with a bad region, but the unwrap ensures any future or residual SDK region error is legible.
- **Editor affordance (resolves spec open question).** The editor already gates on `disabled(!isValid)` (disable Save). Keep that as the primary affordance for consistency, tighten `isValid` to use `AWSRegion.isValid` for `resourceRegion` and `ssoRegion`, and additionally show an inline field-level error ONLY when a field is non-empty but malformed (so a fresh empty form is not noisy). Extract the region-validation predicate into a small testable function/type so T-5 can assert it without rendering SwiftUI.
- **`ProfileConfigError` location.** New `Models/ProfileConfigError.swift`, mirroring the existing typed-error pattern (`EC2Error`, `AuthError`, `DCVError`, `DCVReadinessError`), conforming to `LocalizedError` with an actionable `errorDescription` that names the field and the offending value.

## Acceptance Criteria

- [x] AC-1: A `[profile]` with `region = eu-central-1 ` (trailing space), parsed by `AWSConfigParser`, yields `resourceRegion == "eu-central-1"` (trimmed, valid).
- [x] AC-2: A profile omitting the `region` key, parsed then validated, yields `resourceRegion == ""` and `AWSRegion.isValid("")` returns `false`.
- [x] AC-3: For region inputs `eu-central-1`, `us-east-1` (valid) and ``, ` `, `eu-central-1 `, `-eu`, `eu-`, `eu_central_1`, a 64-char string (invalid), `AWSRegion.isValid`/`normalize` verdicts match the SDK regex `^(?!.*-$)(?!-)[a-zA-Z0-9-]{1,63}$` semantics.
- [x] AC-4: A profile whose `resourceRegion` is empty or malformed, when Connect is invoked (manual OR auto), drives the state machine to `.error` with a specific, non-opaque `errorMessage` naming the field and value, and the EC2/SSM/Secrets seams are NEVER invoked (call count asserted zero).
- [x] AC-5: A thrown `Smithy.ClientError.invalidValue("Invalid region: xx")` mapped by `describe(_:)` produces a user-facing message containing `"Invalid region"`, NOT the generic `Smithy.ClientError error 4` bridge string.
- [x] AC-6: An empty or malformed region entered in the Profile Editor disables Save (and shows a field-level error when non-empty-but-malformed); a valid region re-enables Save and clears the error.

## Implementation Phases

### Phase 1: Models, AWSRegion helper

**Priority: HIGH**, everything else depends on this single rule.

**Goal**: One source of truth for region normalization and validation, with exhaustive table tests.

**Tasks**:
- [x] Add `Models/AWSRegion.swift` with `enum AWSRegion { static func normalize(_ s: String) -> String; static func isValid(_ s: String) -> Bool }`. `normalize` trims leading/trailing whitespace (and newlines). `isValid` matches the exact SDK regex `^(?!.*-$)(?!-)[a-zA-Z0-9-]{1,63}$` (compile the `NSRegularExpression`/`Regex` once as a static constant). Decide whether `isValid` normalizes internally or expects a pre-normalized value; document it (recommend: `isValid` evaluates the raw string so ` eu-central-1 ` is invalid, and callers normalize first when they want to accept trimming).
- [x] Add `Tests/SSMConnectKitTests/Models/AWSRegionTests.swift` table test (T-2, AC-3): valid `{eu-central-1, us-east-1}`; invalid `{"", " ", "eu-central-1 ", "-eu", "eu-", "eu_central_1", <64-char string>}`. Include a case pinning boundary length (63 valid, 64 invalid). Add the `// Verifies:` traceability comment.

**Depends on**: None

### Phase 2: Parser trim + ConnectionProfile.isConfigured

**Priority: HIGH**, cleans stored profiles at the parse boundary and tightens the auto-connect gate.

**Goal**: Regions are trimmed when read from `~/.aws/config`; `isConfigured` uses the real region rule.

**Tasks**:
- [x] `Services/AWSConfigParser.swift`: in `resolvedProfile(named:)` (`:71-77`), wrap `resourceRegion` and `ssoRegion` in `AWSRegion.normalize(_:)` (apply to the `session?.region ?? profile.ssoRegion` result and to `profile.region`). Omitting `region` still yields empty `resourceRegion` (parse logic otherwise unchanged; do not infer a region).
- [x] `Models/ConnectionProfile.swift`: change `isConfigured` (`:63-67`) to use `AWSRegion.isValid(resourceRegion)` instead of `!resourceRegion.isEmpty`. Leave the other field checks as-is (out of scope).
- [x] Extend `Tests/SSMConnectKitTests/Services/AWSConfigParserTests.swift` (T-1, AC-1/AC-2): trailing-space `region` trims to valid `eu-central-1`; omitted `region` yields empty `resourceRegion`; add an assertion that `AWSRegion.isValid` of the omitted case is `false`. Add the `// Verifies:` comment.

**Depends on**: Phase 1

### Phase 3: Pre-flight connect guard + ProfileConfigError

**Priority: HIGH**, this is the core fix that stops a bad region reaching the SDK on both connect paths.

**Goal**: `runConnect()` fails fast with a typed, actionable error before any seam call, for both manual and auto-connect.

**Tasks**:
- [x] Add `Models/ProfileConfigError.swift`: `enum ProfileConfigError: LocalizedError, Equatable { case invalidRegion(field: String, value: String) }` with an `errorDescription` that names the field label (e.g. "resource region" / "SSO region") and shows the offending value (quote empty as `\"\"`), plus a short remediation hint (e.g. "set a valid AWS region such as eu-central-1 in Settings"). No environment-specific literals beyond a generic example.
- [x] `StateMachine/ConnectionStateMachine.swift`: at the top of `runConnect()` (after resetting `errorMessage`/`warningMessage`, before `state = .authenticating`, ~line 254), validate `profile.resourceRegion` and `profile.ssoRegion` via `AWSRegion.isValid(_:)`; on the first failure `throw ProfileConfigError.invalidRegion(field:value:)`. The existing bottom `catch` (`:356-359`) routes it through `teardownTunnel()` + `fail(_:)` -> `state = .error`, `errorMessage = describe(error)`.
- [x] Confirm auto path coverage: `onLaunch()` (`:158`) already gates on `profile.isConfigured` (now region-aware via Phase 2), and any bad `ssoRegion` that slips past `isConfigured` is still caught by the `runConnect()` guard. No separate auto-connect edit needed; document this in the phase notes.
- [x] Test doubles for call-count assertions: add lightweight recording doubles (or reuse `MockEC2Service`/`MockSSMService`/`MockSecretsService` if they expose call counts) that assert `resolveInstance`/`startSession`/`fetchSecret` are never called. If existing doubles lack a zero-call assertion surface, add a `resolveCount`/`startSessionCount`/`fetchCount` read to the relevant double in `StateMachine/StateMachineTestDoubles.swift` (mirror `SequencedEC2Service.resolveCount`).
- [x] Add T-3 tests in `Tests/SSMConnectKitTests/StateMachine/ConnectionStateMachineTests.swift`: for `resourceRegion == ""`, `resourceRegion == "eu_central_1"`, and `ssoRegion == "-eu"`, call `machine.connect()`, `await machine.awaitInFlightTask()`, then `#expect(machine.state == .error)`, `#expect(machine.errorMessage?.contains(<field/value>) == true)`, and `#expect(ec2.resolveCount == 0 && ssm.startSessionCount == 0 && secrets.fetchCount == 0)`. Add one auto-connect variant driving through `onLaunch()` with `settings.autoConnect == true`. Add `// Verifies:` comments.

**Depends on**: Phase 1 (uses `AWSRegion.isValid`)

### Phase 4: describe(_:) unwraps Smithy.ClientError

**Priority: MEDIUM**, closes the opacity layer so any residual SDK region error is legible.

**Goal**: `describe(_:)` surfaces `Smithy.ClientError`'s associated string, with a general fallback for `Error`-only AWS SDK errors.

**Tasks**:
- [x] `StateMachine/ConnectionStateMachine.swift`: `import Smithy`; extend `describe(_:)` (`:669-671`) so that before the generic `localizedDescription` fallback it: (a) returns `(error as? LocalizedError)?.errorDescription` when present; (b) for `error as? Smithy.ClientError`, returns the associated string (switch over the 5 cases returning the payload, so `.invalidValue("Invalid region: xx")` -> `"Invalid region: xx"`); (c) general fallback using `String(reflecting: error)` extraction for other `Error`-only AWS SDK errors, avoiding the bare `NSError` bridge string. Keep wording neutral; no environment specifics.
- [x] Add T-4 tests in `ConnectionStateMachineTests.swift` (or a focused `DescribeErrorTests.swift`): `import Smithy`; construct `Smithy.ClientError.invalidValue("Invalid region: xx")`; assert the mapped message contains `"Invalid region"` and does NOT contain `"error 4"`/the `Smithy.ClientError error 4` bridge form. If `describe(_:)` is private, expose a `nonisolated`/internal test seam or drive it through `fail(_:)` via an injected failing seam; prefer a minimal internal `@testable` accessor over widening the public API. Add `// Verifies:` comments.

**Depends on**: Phase 3 (shares `ConnectionStateMachine.swift`; sequence after to avoid edit conflicts)

### Phase 5: ProfileEditorView inline validation

**Priority: MEDIUM**, prevents a malformed region from being saved and tells the user why.

**Goal**: Region fields are trimmed on commit and validated inline; Save is disabled while invalid.

**Tasks**:
- [x] `Settings/ProfileEditorView.swift`: tighten `isValid` (`:83-94`) to require `AWSRegion.isValid(trimmed(draft.resourceRegion))` and `AWSRegion.isValid(trimmed(draft.ssoRegion))` (replace the bare `!isEmpty` checks for those two fields). Trim the region fields on commit (normalize into `draft` when Save is pressed, or on field-change).
- [x] Add inline field-level error text under the Resource region and SSO region fields shown ONLY when the field is non-empty AND invalid (e.g. a `.foregroundStyle(.red)` caption "Not a valid AWS region"), consistent with the existing caption styling in the "Connect mode" section.
- [x] Extract the region-validation decision into a testable seam: a small pure function/struct (e.g. `ProfileEditorValidation.regionState(_:) -> {valid, emptyRequired, malformed}` or two booleans `saveEnabled`/`showFieldError`) so T-5 can assert without SwiftUI rendering. Keep it in the same file or a sibling `Settings/ProfileEditorValidation.swift`.
- [x] Add T-5 tests in `Tests/SSMConnectKitTests/Settings/ProfileEditorValidationTests.swift`: empty region -> Save disabled, no field error (fresh form); malformed non-empty region -> Save disabled + field error shown; valid region -> Save enabled + no error; repeat for `ssoRegion`. Add `// Verifies:` comments. (Note: `Settings` is currently untested; create the `Tests/.../Settings/` folder.)

**Depends on**: Phase 1

## Test Plan

Mocked-seam unit tests in `SSMConnectKit`; no live AWS. Quality gate per phase: `GIT_CONFIG_VALUE_0=all swift test --package-path SSMConnectKit` (or the repo `Makefile`/xcodebuild test target). Each test carries a traceability comment: `// Verifies: Fix opaque region-failure on Connect, Criterion: "<exact AC text>"`.

| Criterion | Test ID | Test Type | Test Location |
|-----------|---------|-----------|---------------|
| AC-3: `AWSRegion.isValid`/`normalize` match SDK regex semantics | T-2 | Unit (table) | `SSMConnectKit/Tests/SSMConnectKitTests/Models/AWSRegionTests.swift` |
| AC-1: trailing-space `region` trims to valid `eu-central-1` | T-1 | Unit | `SSMConnectKit/Tests/SSMConnectKitTests/Services/AWSConfigParserTests.swift` |
| AC-2: omitted `region` yields empty `resourceRegion` and `isValid == false` | T-1, T-2 | Unit | `SSMConnectKit/Tests/SSMConnectKitTests/Services/AWSConfigParserTests.swift`, `.../Models/AWSRegionTests.swift` |
| AC-4: empty/malformed region -> `.error` with specific message; seams never invoked | T-3 | Unit | `SSMConnectKit/Tests/SSMConnectKitTests/StateMachine/ConnectionStateMachineTests.swift` |
| AC-5: `Smithy.ClientError.invalidValue` maps to a message containing "Invalid region" | T-4 | Unit | `SSMConnectKit/Tests/SSMConnectKitTests/StateMachine/ConnectionStateMachineTests.swift` (or `.../DescribeErrorTests.swift`) |
| AC-6: editor disables Save + shows field error for bad region; valid clears it | T-5 | Unit | `SSMConnectKit/Tests/SSMConnectKitTests/Settings/ProfileEditorValidationTests.swift` |
| AC-4 (integration): full connect drive-through with bad region halts at `.error`, zero seam calls | T-3-E2E | Integration (mocked seams) | `SSMConnectKit/Tests/SSMConnectKitTests/StateMachine/ConnectionStateMachineTests.swift` |
| AC-4/AC-5 (manual): real app, bad region entered, actionable message observed | T-MANUAL | Manual verification | Build + run the app; see below |

### Closest-to-E2E rows (developer-tool desktop app)

This is a menu-bar desktop app, not a web/API surface, so there is no HTTP/Playwright E2E. The two equivalents are mandatory:

- **T-3-E2E (integration drive-through).** Construct a `ConnectionStateMachine` wired entirely from the existing mock doubles (the `makeMachine(...)` builder in `ConnectionStateMachineTests.swift`) with a profile whose `resourceRegion` is `""` (and a second whose `ssoRegion` is malformed). Call `connect()` (and a variant via `onLaunch()` with `autoConnect`), await the in-flight task, and assert: `state == .error`, `errorMessage` names the field and value, and the EC2/SSM/Secrets doubles recorded zero calls. This exercises the full `runConnect()` path end-to-end through the guard.
- **T-MANUAL (manual verification).** Build the app (`GIT_CONFIG_VALUE_0=all` prefix), open Settings, create/edit a profile with (a) an empty resource region and (b) a malformed region such as `eu_central_1`, confirm Save is disabled with the inline error; then, for a profile that somehow reaches Connect with a bad region (e.g. an imported SSO profile missing `region`), tap Connect and confirm the surfaced error names the field and value and is not `Smithy.ClientError error 4`. Record the result at the PR merge gate.

## Implementation Order

| Phase | Description | Effort | Depends on |
|-------|-------------|--------|------------|
| 1 | `AWSRegion` helper + table tests (T-2) | S | None |
| 2 | Parser trim + `ConnectionProfile.isConfigured` (T-1) | S | Phase 1 |
| 3 | Pre-flight guard + `ProfileConfigError`, wired into `runConnect()` both paths, seam-never-invoked tests (T-3) | M | Phase 1 |
| 4 | `describe(_:)` unwrap of `Smithy.ClientError` + fallback (T-4) | S | Phase 3 (same file) |
| 5 | `ProfileEditorView` inline validation + extracted testable predicate (T-5) | M | Phase 1 |

Phases 2, 3, and 5 can proceed in parallel once Phase 1 lands; Phase 4 is sequenced after Phase 3 only because both edit `ConnectionStateMachine.swift`.

## File Reference Summary

| File | Change | Phase |
|------|--------|-------|
| `SSMConnectKit/Sources/SSMConnectKit/Models/AWSRegion.swift` | NEW: `normalize`/`isValid` (SDK regex) | 1 |
| `SSMConnectKit/Tests/SSMConnectKitTests/Models/AWSRegionTests.swift` | NEW: T-2 table tests | 1 |
| `SSMConnectKit/Sources/SSMConnectKit/Services/AWSConfigParser.swift` | Trim `resourceRegion`/`ssoRegion` in `resolvedProfile(named:)` | 2 |
| `SSMConnectKit/Sources/SSMConnectKit/Models/ConnectionProfile.swift` | `isConfigured` uses `AWSRegion.isValid(resourceRegion)` | 2 |
| `SSMConnectKit/Tests/SSMConnectKitTests/Services/AWSConfigParserTests.swift` | EXTEND: T-1 trim/omit cases | 2 |
| `SSMConnectKit/Sources/SSMConnectKit/Models/ProfileConfigError.swift` | NEW: `LocalizedError` typed error | 3 |
| `SSMConnectKit/Sources/SSMConnectKit/StateMachine/ConnectionStateMachine.swift` | Pre-flight guard in `runConnect()`; extend `describe(_:)` (+`import Smithy`) | 3, 4 |
| `SSMConnectKit/Tests/SSMConnectKitTests/StateMachine/StateMachineTestDoubles.swift` | Add zero-call assertion surface if missing | 3 |
| `SSMConnectKit/Tests/SSMConnectKitTests/StateMachine/ConnectionStateMachineTests.swift` | ADD: T-3 guard tests + T-4 describe tests + integration drive-through | 3, 4 |
| `SSMConnectKit/Sources/SSMConnectKit/Settings/ProfileEditorView.swift` | Tighten `isValid`, trim on commit, inline error, extract predicate | 5 |
| `SSMConnectKit/Tests/SSMConnectKitTests/Settings/ProfileEditorValidationTests.swift` | NEW: T-5 validation tests | 5 |

## Open Questions

- **RESOLVED (editor affordance).** The spec left "disable Save vs inline field error" open. Resolved to BOTH, keeping disable-Save as the primary gate (matches the existing `disabled(!isValid)` pattern) and adding an inline field-level error shown only when a field is non-empty-but-malformed, so a fresh empty form is not noisy. See Phase 5.
- **`describe(_:)` extraction mechanism for `Smithy.ClientError`.** Prefer an explicit `switch` over the 5 enum cases (returns the payload string cleanly) over a `String(reflecting:)` parse; confirm during Phase 4 that `import Smithy` in the app target does not pull an unwanted symbol clash. Low risk.
- **Test access to a private `describe(_:)`.** T-4 needs to reach `describe(_:)`. Prefer a minimal `@testable`-internal accessor or driving it through `fail(_:)` via an injected failing seam over widening the public API; decide in Phase 4. Low risk.
- **Plan location note (for the reviewer):** this plan was written to `plans/bug-invalid-region-connect-failure.md` as instructed; the repo's pre-existing plans live under `docs/plans/*.plan.md`. If the team wants a single taxonomy, relocate/rename to match `docs/plans/<slug>.plan.md`. No functional impact.
