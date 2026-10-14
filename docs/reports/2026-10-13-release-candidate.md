# Local Release Candidate Verification

Date: 2026-10-13. Scope: this branch's macOS ARM64 candidate, not a published release.

## Initial Candidate Gates

- `scripts/release.sh` completed with exit 0 after aligning Xcode's dependency checkout
  with the verified Swift package checkout and enforcing lockfile-only resolution.
- The local ZIP is `dist/SSMConnect-0.1.0.zip`. This is the source Info.plist version,
  not the next public release version; the release workflow stamps GitVersion's version.
- ZIP SHA-256: `77523d89df6a54857325d10f744caaffb92e781c02c589dc0110f61dfcf1ca49`.
- Checksum and deep/strict signature verification passed after unpacking the ZIP.
  Both embedded helpers are executable and individually pass signature verification.
- The packaged Session Manager plugin reports `1.2.814.0`. The packaged proxy helper
  rejects invalid arguments with a nonzero exit, no stdout and a credential-free error.
- The app and proxy helper retain the macOS 14.0 deployment target. Older-Mac execution
  is not established by inspecting this target alone.
- `swift test --package-path SSMConnectKit --configuration release --disable-automatic-resolution`
  passed: 195 tests across 31 suites. Opt-in live tests are disabled in this invocation;
  their separate execution evidence is recorded in the browser and editor specifications.
- Actionlint 1.7.12 passed for the updated CodeQL workflow. PRs now run the unit suite,
  then a clean traced Swift build using the locked source checkout.
- The added-line/new-file guard found no newly introduced private target identifiers.
  The dependency lockfile is unchanged. Existing baseline examples were not modified.

The initial Release attempt failed in the independent DerivedData AWS CRT checkout with
missing headers. Reusing the verified package checkout removed that failure without a
dependency version change. Existing local Xcode device/simulator and Swift concurrency
warnings remain; they did not fail the successful build or test suite.

## Remaining Acceptance Gates

- Human-confirmed remote folder open/save, terminal, language server and project build/debug.
- Browser identity-provider sign-in and session retention in the user's chosen profile.
- Concurrent editor windows, multi-user socket mode, full drop/SSO/app-relaunch recovery,
  fresh-user/Mac bootstrap and the deferred working-day/DCV observation.
- Hosted PR checks and review. A local passing build is not hosted CodeQL evidence.

The app remains ad-hoc signed, not notarized, as in the existing distribution contract.
No app was installed or launched from this candidate; existing app/editor/DCV state was
left intact. No merge, public release, Homebrew update or organization setting change
was performed.

## PR Self-Review Follow-Up

The author reviewed the app diff directly after the independent reviewer reported that
it had no filesystem or execution tools. No independent-review verdict is claimed.

| Severity | Finding | Resolution and executed check |
|---|---|---|
| P0 | `project.yml` helper embedding was left unstaged: the local ZIP contained a helper the pushed commit would omit. | Include the existing embedding changes in the PR; Release packaging now refuses either missing/non-executable helper. Shell syntax and YAML embedding-contract checks passed. |
| P1 | Browser auto-update blocked conditional Restore through the launch-version gate. | The extended Restore regression reproduced `.unavailable`, then passed after recovery alone bypassed the version gate. Unsupported launch remains refused, and ownership/policy/running checks remain intact. |
| P1 | VS Code CLI preflight/launch could block the menu main actor indefinitely. | Async waits are bounded to 15 seconds and 64 KiB of captured output. Local timeout, cancellation, excessive-output and normal-result checks passed without VM access. |
| P1 | Changing the selected profile during editor preparation was ignored. | The regression reproduced stale profile/error state, then passed after changed-profile cancellation and cancellation checks before subsequent workstation actions. No AWS operation occurred in that test. |

The optimized suite was rerun after the review fixes: 197 tests across 31 suites passed.
Distribution packaging completed, including required-helper checks. The unpacked candidate
passed checksum, app/helper signatures, proxy CLI smoke and deployment-target checks.
Reviewed ZIP SHA-256: `128bf624c576f0f806b2901a745ac67a3d73291cb1df2a78c8bbbc0ac4a8cd29`.
Human acceptance gates remain open; these regressions do not establish a complete
real-workspace or recovery workflow.

## Executed Workflow Follow-Up

Hosted CodeQL Actions and Swift jobs both passed for commit
`2df498471dcc4f3f7add93f3268f916f22acba9e` in
[run 38448482324](https://github.com/vhco-pro/ssm-connect/actions/runs/38448482324).
That run includes the hosted unit-test gate; it is not evidence for later commits.

The isolated native editor fixture passed actual UI file open/save, integrated-terminal
project execution, TypeScript definition navigation and debugger pause/continue/output checks.
The existing server runtime was reused, and no existing user project was inspected. Details
and the initial stale-forwarding recovery caveat are in the
[editor specification](../specs/remote-vscode.spec.md). The fixture preparation command is
`node scripts/test-native-editor-workflow.mjs`; it prepares/opens the workspace, not an
automated assertion that every subsequent UI action passed.

All three supported browser scopes passed the controlled sign-in redirect and authenticated
reopen fixture, alongside DNS/routing/outage checks. See the
[browser review](2026-10-13-browser-bootstrap-review.md). Real identity-provider policy/MFA,
arbitrary user projects, concurrency/socket-mode/recovery and fresh-user coverage remain
separate gates. No merge or public release has been performed.

## Recovery Coverage Follow-Up (2026-10-14)

The user selected completing remaining coverage rather than publishing the preview scope.
The earlier approved candidate is therefore not a release approval.

Local expiry-renewal, exact-identity refusal, double-open deduplication, lease reuse,
sign-in failure/retry and fresh-setup prerequisite tests passed. The full suite passed
202 tests across 31 suites. The recovery Release ZIP was rebuilt and its unpacked app/helper
signatures, checksum and proxy CLI smoke check passed.
Recovery ZIP SHA-256: `1d31956b782d5068c0b268461697f5f8150f1132945ff89434258ca3665c9ecb`.

Explicit native sign-in enabled isolated live concurrent-channel and 65-second fresh-key
authorization tests to pass; a repeat passed after an intervening failed duplicate attempt.
An owned private Unix-socket forwarding fixture also passed and was cleaned up. These do
not replace full concurrent-window/multi-user editor, drop/relaunch, fresh-Mac or real
enterprise browser sign-in coverage. Details are recorded in the editor specification.

Hosted PR checks passed for head `2acdef2dc335cd87b93ea0cc8a0e02f55d9e10a9` in
[run 38473783218](https://github.com/vhco-pro/ssm-connect/actions/runs/38473783218), and
same-head independent verification passed in
[run 38476973135](https://github.com/vhco-pro/ssm-connect/actions/runs/38476973135).
New recovery source changes require their own hosted run. No merge or public release occurred.

## Bounded Shutdown And Cleanup Follow-Up (2026-10-14)

Cancellation during the proxy monitor's polling sleep now stops only its owned plugin.
Lease invalidation has a graceful-stop deadline followed by force-stop if the child ignores
SIGTERM. Executed local tests cover invalidation, cancellation, an unrelated child remaining
alive and an uncooperative child stopped after grace.

The isolated live probe passed in 87 seconds: concurrent authorization, 65-second fresh-key
authorization, deletion of its temporary lease stopping its held channel, and fresh-generation
reconnect. The main app was explicitly used as owner when the old preview was closed; no
normal app lease, browser configuration or user editor session was invalidated.

The full retained suite passed 204 tests across 31 suites. Release packaging completed;
unpacked app/helper signatures, checksum and proxy CLI smoke checks passed.
Shutdown ZIP SHA-256: `641629669b9341aa70fc31c6e137ea35a7afeffab7473e152bd966418961b594`.

Disposable external operational code was removed after checking it was unused. Runtime
helper/library code, reproducible tests, observation tools, saved workspaces and app-owned
leases remain. Full native GUI quit/relaunch, multi-user socket mode, fresh-Mac and enterprise
identity-policy acceptance remain open. No merge or public release was performed.