# Browser Bootstrap Implementation Review

- **Date:** 2026-10-13.
- **Scope:** current dirty/untracked local browser bootstrap implementation, not just `git diff`.
- **Specification:** [browser-bootstrap.spec.md](../specs/browser-bootstrap.spec.md).
- **Verdict:** initial review found confirmed edge cases; follow-up fixes and regression evidence
   are recorded below. Full human/browser acceptance gates remain open.
- **Procedure:** direct repository-native review; no Vega metadata or production behavior changes.
  The requested reviewer agent had no filesystem/terminal tool grant, so the main session reviewed
  source and executed the checks directly. No real browser settings, running apps or AWS transports
  were modified during this review.

## Findings

### P1: Unknown Running Instance Does Not Block Routing Replacement

At [BrowserBootstrap.swift](../../SSMConnectKit/Sources/SSMConnectKit/Services/BrowserBootstrap.swift#L203),
the native path treats `ownedApplication(...) == nil` as proof that the previous browser is not
running. It ignores the injected/default running-browser check unless a fake launch callback is
installed. Missing/stale PID records, a manually reopened managed profile, or an unregistered
headless process therefore bypass the changed-routing guard. `open` then writes the new record
and launch options. A singleton can retain old flags, or Zen can have its live user.js replaced,
without a verified refresh/close boundary. No profile-lock check exists in the separate-mode path.

**Executed reproduction:** store the old Zen routing record, omit the instance record, supply a
running-browser result, change SOCKS port, and expect preflight refusal. The production branch
returned successfully: `an error was expected but none was thrown`.

**Required fix:** unknown ownership must be a conflict, not a stopped-instance assertion. Verify
the target profile's lock/instance identity before config writes and before claiming a new native
launch accepted the requested profile/routing. Add tests for the production callback branch.

### P1: Save-Only Configuration Change Makes Restore Unusable

[BrowserBootstrap.restore](../../SSMConnectKit/Sources/SSMConnectKit/Services/BrowserBootstrap.swift#L292)
reconstructs routing from the current saved profile. [FirefoxProxySetup.verify](../../SSMConnectKit/Sources/SSMConnectKit/Services/FirefoxProxySetup.swift#L130)
requires that whole routing object equal the setup journal, including saved SOCKS/suffix values.
Saving a changed SOCKS port while the tunnel is off updates the app profile immediately but does
not change the browser. Restore then fails despite all current affected browser values still
matching the installed journal. The user must know to restore the old app settings first.

**Executed reproduction:** install an owned disposable Zen setup, modify only the in-memory saved
SOCKS port, then request Restore without touching browser preferences. Restore threw `.conflict`;
the expected prior `network.proxy.type=0` was not restored.

**Required fix:** resolve Restore from the consented target and installed ownership journal, not
new desired routing. Still verify owner and current affected values; this must not allow one
workstation to restore another's setup. Browser-version changes must not strand the same recovery.

### P2: Multi-File Setup/Restore Has No Interrupted-Write Recovery

[FirefoxProxySetup.installUnlocked](../../SSMConnectKit/Sources/SSMConnectKit/Services/FirefoxProxySetup.swift#L147)
writes the journal, user.js and prefs.js sequentially. Update and Restore also change multiple
files sequentially. Atomicity of each individual rename does not make the whole operation atomic.
An I/O failure or app termination between writes leaves a mixed state that `verify` rejects,
which blocks both retry and Restore. There is no journal phase or explicit recovery path.

**Evidence:** source/control-flow inspection; fault injection was not executed in this review.
Add phase-aware conditional recovery/rollback and injected failures at every write boundary.
Recovery must never overwrite later independent browser/user changes.

## Executed Evidence

1. Baseline `swift test --package-path SSMConnectKit --skip-update`: **186 tests / 30 suites passed**.
   Three opt-in browser/native/preview tests were skipped because this review did not enable them.
2. Two temporary fixture-only Swift Testing probes were compiled/executed and both failed as
   described above. They were removed after capturing evidence; production source was untouched.
   Logs: `/tmp/ssm-browser-review-probes.log` and `/tmp/ssm-browser-review-baseline.log`.
3. No fresh AWS, invalid-certificate, managed-policy, real-profile, GUI or SSO test was run.
   Earlier recorded E2E results remain historical evidence, not a fresh review execution.

## Acceptance Verdicts

The verdict applies to the whole criterion, not to a green subset. Partial unit evidence is named
without promoting the complete browser/user workflow to `met`.

| Criterion | Verdict | Current evidence / remaining check |
|---|---|---|
| AC-B1 | met | Executed orchestration test deduplicates Open, waits for ready handle, launches once and uses no DCV session. Native execution is historical. |
| AC-B2 | untested | Legacy decoding passed; automatic installed/default-browser selection has no complete scenario test. |
| AC-B3 | not verified | Opt-in native PID/isolation test exists but was not executed in this review. |
| AC-B4 | not verified | Real-browser routing test exists and was skipped; actual workstation browser/TLS navigation remains unverified. |
| AC-B5 | untested | Human-confirmed new-flow identity-provider SSO has not been recorded. |
| AC-B6 | not verified | Opt-in cold-start outage test exists and was skipped; same-running-window outage/config-load-failure proof is incomplete. |
| AC-B7 | not met | Unrecorded running-instance preflight reproduction bypassed routing-change protection; pending/apply unit tests cover only the recorded/fake-launch branch. |
| AC-B8 | untested | Persistent-directory unit check passed; authenticated-session retention and independent relaunch/reopen are not fully verified. |
| AC-B9 | untested | Existing-owner conflict unit check passed; two live separate-profile identities/ownership-transfer flow is incomplete. |
| AC-B10 | not met | Unknown running/locked separate-profile case is allowed by the production preflight branch. Missing executable, policy and launch scenarios also lack full E2E coverage. |
| AC-B11 | untested | Safe-argument unit check passed, but real invalid-chain browser rejection was not executed. |
| AC-B12 | untested | Fresh Mac/user bootstrap has not been performed. |
| AC-B13 | met | Executed cancelled-consent backend test preserves prefs; the method returns before setup writes or launch. Native dialog UX remains a separate check. |
| AC-B14 | untested | Manual-proxy and proxy-extension conflicts passed in fixtures; managed-policy and replacement-consent workflow not fully tested. |
| AC-B15 | untested | Existing-profile login retention/TLS/routing requires human and real-mode confirmation; fixture setup is not that proof. |
| AC-B16 | not met | Save-only desired-routing change reproduced a Restore conflict against unchanged installed browser settings. Baseline simple Restore passed. |
| AC-B17 | untested | Later prefs/extension changes were refused in fixtures; live policy/extension ownership changes not fully exercised. |
| AC-B18 | untested | Backend running-browser refusal passed; native close/cancel/failure workflow was not executed. |

## Next Gate

Fix the two reproduced P1 defects and make interrupted-write recovery testable before release.
Then rerun the targeted regressions and the mode-specific native/browser criteria. Human SSO,
session retention, fresh-user setup and the working-day gate remain open. The previous summary's
test count was correct, but it cannot establish complete acceptance for both modes.

## Auto-Update Restore Follow-Up

The author extended the Restore regression to a newly installed, unverified browser version.
`restoreUsesInstalledRoutingAfterSaveAndBrowserUpgrade` first failed with `.unavailable`, then
passed after Restore alone stopped requiring a launch-verified version. Launch preflight still
refuses that version; policy, closed-browser, exact ownership scope and installed-value checks
remain mandatory for Restore. This supersedes the original Restore regression name above.

## Follow-Up Fix Verification

The two reproduced P1 findings and interrupted-write P2 were addressed after the user authorized
continuation. `unrecordedRunningInstanceBlocksChangedRouting`, `restoreUsesInstalledRoutingAfterSave`
and `interruptedProxyWritesRecoverWithoutOverwritingUserChanges` passed. Fault injection covers
transaction/user/preferences/journal/completion boundaries for install, update and restore, and
recovery refuses later independent proxy changes. A separate unowned-profile lock probe now runs
before configuration writes; `unownedLockedProfileRefusesWrites` passed without writes/launch.
Native launch also refuses a previously running PID rather than recording singleton forwarding
as a fresh owned launch.
`realNativeOpenAndReuse` was rerun after this fix and passed for installed Chrome and Zen,
including new owned PID creation, focus/reuse and preservation of pre-existing processes.

The focused browser suite passed 14 test entries (three opt-in tests skipped). Real installed
Chrome/Zen routing, proxy-side DNS and fail-closed outage were rerun and passed all three scopes.
The current full native suite passed 195 tests/31 suites. Earlier
review verdicts above describe the initial reviewed snapshot, not an assertion the fixes remain
broken; final UI/session/fresh-user acceptance still requires its own execution evidence.