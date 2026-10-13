# Local Release Candidate Verification

Date: 2026-10-13. Scope: this branch's macOS ARM64 candidate, not a published release.

## Executed Gates

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
was performed. Organization-wide Dependabot drafts remain separate, unpublished changes
as detailed in the [coverage report](2026-10-13-dependabot-coverage.md).