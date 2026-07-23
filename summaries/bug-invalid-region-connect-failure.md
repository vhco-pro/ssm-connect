---
description: "Verified fix for the opaque Smithy.ClientError error 4 region failure: centralized region validation, a pre-flight connect guard that blocks all SDK seams, and describe(_:) unwrapping of Smithy.ClientError. All 6 acceptance criteria pass against an executed suite."
status: complete
reviewed: 2026-07-22
reviewer: "SDD Reviewer (automated), run by michielvha <michielvh@outlook.com>"
plan: docs/plans/bug-invalid-region-connect-failure.plan.md
---

# Fix opaque region-failure on Connect (Smithy.ClientError error 4), Implementation Summary

## Overview

The change turns the undiagnosable `Smithy.ClientError error 4` region failure into a caught, field-and-value-specific error and prevents a bad region from ever reaching the AWS SDK. It introduces one region-rules helper (`AWSRegion`), a typed `ProfileConfigError`, a parse-boundary trim, a region-aware `isConfigured`, a pre-flight guard in `runConnect()` that fires before any seam call on both the manual and auto paths, a `describe(_:)` unwrap of `Smithy.ClientError`, and inline editor validation via an extracted, SwiftUI-free seam. The full `SSMConnectKit` suite runs green and every acceptance criterion maps to an executed test carrying a `// Verifies:` traceability comment.

## What Was Implemented

### Region rules (single source of truth)
- `AWSRegion.normalize(_:)` / `isValid(_:)` compiling the exact SDK regex `^(?!.*-$)(?!-)[a-zA-Z0-9-]{1,63}$` once, see `SSMConnectKit/Sources/SSMConnectKit/Models/AWSRegion.swift:14-29`. `isValid` evaluates the raw string; callers normalize first when they want to accept surrounding whitespace.

### Parser + profile gate
- Region values trimmed at the parse boundary in `resolvedProfile(named:)`, see `SSMConnectKit/Sources/SSMConnectKit/Services/AWSConfigParser.swift:71-83`. An omitted `region` still yields `nil` (no inference).
- `ConnectionProfile.isConfigured` now uses `AWSRegion.isValid` for both `resourceRegion` and `ssoRegion`, see `SSMConnectKit/Sources/SSMConnectKit/Models/ConnectionProfile.swift:61-63`.

### Pre-flight guard + typed error
- `ProfileConfigError.invalidRegion(field:value:)` as a `LocalizedError` with an actionable, field-and-value message, see `SSMConnectKit/Sources/SSMConnectKit/Models/ProfileConfigError.swift:7-19`.
- Guard at step 0 of `runConnect()`, before `state = .authenticating` and before any seam call, validating `ssoRegion` then `resourceRegion`, see `SSMConnectKit/Sources/SSMConnectKit/StateMachine/ConnectionStateMachine.swift:255-267`.

### Error legibility
- `describe(_:)` now returns a `LocalizedError` description first, then unwraps `Smithy.ClientError` via an exhaustive 5-case switch, then a general `localizedDescription` fallback, see `SSMConnectKit/Sources/SSMConnectKit/StateMachine/ConnectionStateMachine.swift:681-707` (plus `import Smithy` at line 1).

### Editor validation
- SwiftUI-free `ProfileEditorValidation.regionState(_:)` seam, see `SSMConnectKit/Sources/SSMConnectKit/Settings/ProfileEditorValidation.swift:16-20`.
- `ProfileEditorView` trims regions on commit, gates Save on `regionState(...).isValid`, and shows an inline caption only when a field is non-empty-but-malformed, see `SSMConnectKit/Sources/SSMConnectKit/Settings/ProfileEditorView.swift`.

## Verification

Suite executed this session: `GIT_CONFIG_VALUE_0=all swift test --package-path SSMConnectKit` on branch `feature/bug-invalid-region-connect-failure`, result **140 tests / 25 suites / 0 failures**.

| Criterion | Result | Evidence |
|-----------|--------|----------|
| AC-1: trailing-space `region` trims to valid `eu-central-1` | PASS | `trimsRegionWhitespace` in `AWSConfigParserTests.swift` (asserts `resourceRegion == "eu-central-1"` and `AWSRegion.isValid == true`); ran 2026-07-22 |
| AC-2: omitted `region` yields `""` and `isValid == false` | PASS | `omittedRegionIsInvalid` in `AWSConfigParserTests.swift` (`resolved.resourceRegion == nil`, profile `resourceRegion == ""`, `AWSRegion.isValid(...) == false`, `isConfigured == false`); ran 2026-07-22 |
| AC-3: `isValid`/`normalize` match SDK regex semantics | PASS | `AWSRegionTests.swift` parameterized `isValidVerdicts` (valid `eu-central-1`/`us-east-1`, 63-char boundary; invalid `""`, `" "`, leading/trailing space, `-eu`, `eu-`, `eu_central_1`, interior space, 64-char) plus `normalizeTrims` / `normalizeThenValid`; ran 2026-07-22 |
| AC-4: bad region drives `.error`, names field/value, seams never invoked (manual + auto) | PASS | `manualConnectBadResourceRegionGuarded` (args `""`, `eu_central_1`, `eu-central-1 `) and `manualConnectBadSSORegionGuarded` in `ConnectionStateMachineTests.swift` assert `state == .error`, `errorMessage` contains the field label + "not a valid AWS region", and `auth.authenticateCallCount == 0`, `ec2.resolveCount == 0`, `ssm.waitCount == 0`, `secrets.fetchCount == 0`. Auto path: `autoConnectBadRegionSkips` asserts `isConfigured` short-circuit keeps state `.disconnected` with zero seam calls. Guard placement confirmed at `ConnectionStateMachine.swift:255-267` (before `state = .authenticating`); ran 2026-07-22 |
| AC-5: `Smithy.ClientError.invalidValue("Invalid region: xx")` surfaces its payload, not `error 4` | PASS | `smithyClientErrorIsUnwrapped` in `ConnectionStateMachineTests.swift` injects the error at the EC2 seam (valid regions so the guard passes), asserts `errorMessage == "Invalid region: xx"` and NOT `error 4` / `Smithy.ClientError`; exercises the real `fail(_:) -> describe(_:)` path; ran 2026-07-22 |
| AC-6: editor disables Save + shows field error for bad region; valid clears it | PASS | `ProfileEditorValidationTests.swift`: `emptyRegion` (invalid, no error), `malformedRegion` (invalid + error for `eu_central_1`/`-eu`/`eu-`/`eu central 1`), `validRegion` (valid + no error, tolerates surrounding whitespace); ran 2026-07-22 |

Notes:
- AC-4 seam-count evidence is genuine: `authenticateCallCount`, `resolveCount`, `waitCount`, `fetchCount` increment inside the real mock seam methods (`MockAuthProvider.authenticate`, `MockEC2Service.resolveInstance`, `TunnelMocks` `waitForSSMOnline`, `MockSecretsService.fetchSecret`), and the guard sits ahead of all of them.
- This is a menu-bar desktop app with no HTTP/Playwright surface. The Test Plan's closest-to-E2E row is the integration drive-through (T-3-E2E), which is realized by the `connect()` / `onLaunch()` full-path tests above and was executed. The one remaining row, T-MANUAL, is an at-merge manual check by design (see Outstanding Issues); it is not a blocker for the automated criteria.

## Files Changed

### Sources
- `SSMConnectKit/Sources/SSMConnectKit/Models/AWSRegion.swift`, NEW region-rules helper.
- `SSMConnectKit/Sources/SSMConnectKit/Models/ProfileConfigError.swift`, NEW typed `LocalizedError`.
- `SSMConnectKit/Sources/SSMConnectKit/Models/ConnectionProfile.swift`, `isConfigured` uses `AWSRegion.isValid`.
- `SSMConnectKit/Sources/SSMConnectKit/Services/AWSConfigParser.swift`, normalize regions at parse boundary.
- `SSMConnectKit/Sources/SSMConnectKit/StateMachine/ConnectionStateMachine.swift`, pre-flight guard + `describe(_:)` unwrap + `import Smithy`.
- `SSMConnectKit/Sources/SSMConnectKit/Settings/ProfileEditorValidation.swift`, NEW testable validation seam.
- `SSMConnectKit/Sources/SSMConnectKit/Settings/ProfileEditorView.swift`, Save gate + inline error + trim on commit.

### Tests
- `AWSRegionTests.swift` (NEW, T-2), `AWSConfigParserTests.swift` (extended, T-1), `ConnectionStateMachineTests.swift` (extended, T-3/T-4), `ProfileEditorValidationTests.swift` (NEW, T-5).

### Out-of-scope confirmation
- `EC2Clients.swift` / `SSMClients.swift` / `SecretsClients.swift` / `Auth/SSOClients.swift` are untouched (`git diff main...HEAD --name-only` returns nothing for them). Client construction that consumes the region is unchanged, as required by the spec.

## Outstanding Issues

- **Parser normalize is redundant with the existing `parseKeyValue` trim, acceptable defense-in-depth, not a defect.** `AWSConfigParser.parseKeyValue` already applies `.trimmingCharacters(in: .whitespaces)` to every value (`AWSConfigParser.swift:132`, and the whole line at `:45`), and values cannot contain newlines post-split, so `AWSRegion.normalize` on `resourceRegion`/`ssoRegion` in `resolvedProfile` cannot observe any untrimmed input in practice. It is harmless and keeps region trimming inside the single `AWSRegion` source of truth rather than depending on parser internals. No action required; optionally note it in the PR description.
- **T-MANUAL (manual verification) is unrun by design.** Building and running the app to observe the surfaced message end-to-end is the at-merge human check per the plan's Test Plan. All automated criteria are satisfied without it. Recommend recording the manual result at the PR merge gate.

## Recommendation

**Status transition**: `review` -> `complete`. All six acceptance criteria pass against an executed suite (140/25/0), the guard provably precedes every SDK seam, the `Smithy.ClientError` payload is surfaced instead of `error 4`, and no out-of-scope client construction changed. The one redundancy is benign defense-in-depth, and the only unrun row is the by-design at-merge manual check.
