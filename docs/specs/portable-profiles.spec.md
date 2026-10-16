# SPECIFICATION: Reusable Text Profiles

- **Status:** attached-file source of truth and canonical GUI save behavior accepted by the owner on 2026-10-15; local macOS and Windows profile/auth increments added on 2026-10-16. Not released; Windows browser/editor adapters and native Windows/UI acceptance remain open.
- **Baseline:** released macOS v0.5.0 and cross-platform branch
  `chore/windows-phase-0-spikes` at `33b68c1365a2ad325068190ddeb098b49467cdfe`.
- **Related:** [current client](./ssm-connect.spec.md),
  [cross-platform reconciliation](./cross-platform-client.spec.md#17-reconciliation-findings-2026-10-15),
  [web forwards](./web-forwards.spec.md), [browser bootstrap](./browser-bootstrap.spec.md),
  [native editor](./remote-vscode.spec.md).
- **Scope:** share and automate non-secret workstation configuration while retaining the native
  visual editor. This does not authorize replacing the app, changing live connections or merging
  the cross-platform rewrite.

## 1. Existing Behavior and Reuse

Released macOS profiles are JSON-encoded native model data in UserDefaults. The active profile
and global settings have separate keys. AWS-config import is explicit. These preferences are not
a supported public editing API; external preference writes can conflict with in-memory state.

The cross-platform branch already supplies a separate versioned JSON document, schema, Swift/C#
validators, credential-field rejection, exchange fixtures and import/export controls in both UIs.
Keep this contract boundary rather than exposing either client's private persistence encoding.

It does not yet implement this request:

- Import creates a local copy, not an attachment to the source file. macOS still uses UserDefaults.
- No YAML parser or external-file watcher was found in the inspected branch.
- Schema v1 only permits `dcvViewer`; it cannot represent current `tunnelOnly`, web forwards,
  browser bootstrap or native editor capabilities.
- The DTO can preserve unknown optional fields, but macOS UI import converts to a native profile
  and gives it a fresh UUID. Later UI export passes only that native profile, so DTO preservation
  alone is not proof that unknown fields or document identity survive the GUI round-trip.

## 2. Proposed User Experience

The recommended model is **attached profiles**: the visual editor and external tools edit the
same file, not two independently writable copies. Import as Local Copy remains an explicitly
different operation. The owner explicitly accepted this source-of-truth model on 2026-10-15,
including one profile per file initially, checked saves and staged external changes.

The initial proposal is one profile per file with multiple attachments allowed. The app offers
Open Profile File, Export Profile and Save a Local Copy through familiar native file controls.
The current visual settings remain the normal way to inspect and edit values.

1. Opening a file parses, validates and previews it without connecting or changing SSH/browser
   setup. The user explicitly attaches it or imports a local copy.
2. GUI Save validates the complete document and writes the same attached file, subject to a
   checked revision. A read-only file is shown read-only and offers Save a Local Copy.
3. External edits are validated. Invalid input leaves the last good configuration available,
   keeps existing transports intact, and presents an actionable file/field error.
4. Valid external edits appear as pending changes for explicit Apply. They do not automatically
   reconnect, start EC2, change routing, open clients or grant integration permissions.
5. Changes affecting an active target/routing are reconciled using the existing pending-Apply,
   generation and ownership rules. Do not silently redirect an existing connection.
6. A missing, renamed or temporarily inaccessible attached file does not delete a profile or
   its sessions. Show the problem and offer Locate File, Detach or Save a Local Copy.

## 3. Portable Contract

Use one versioned data contract with YAML for human editing and JSON for interoperable tooling.
The JSON Schema describes the normalized data, not a second divergent JSON implementation.
Parsers must produce equivalent validated values in Swift and .NET.

Retain reading of the branch's v1 JSON documents. Introduce an explicit newer schema when adding
semantics that v1 cannot represent. A schema-version change must have migration and cross-client
fixtures; do not silently rewrite an attached document on Open.

The new contract must cover all currently released non-secret profile capabilities:

- Display/document identity; SSO portal/region, account/role and resource region.
- Instance tag selector and connect mode.
- DCV/tunnel-only action, local/remote ports, agent port and optional secret identifier.
- SOCKS/domain routing and explicit local forwards.
- Browser choice/mode, with machine-specific profile locations handled locally.
- Native editor enablement and an optional remote folder, clearly distinguished from local paths.

Required unsupported capabilities fail explicitly; they must not be discarded or silently become
DCV-only behavior on another platform. Unknown optional values must survive supported GUI and
text round-trips, not just DTO encode/decode tests. Unknown values cannot bypass security rules.

Global app preferences such as auto-connect, notifications, login-at-startup, active selection
and clipboard policy remain local in this iteration. A portable workstation file does not opt
another user's app into automatic connections.

## 4. Local State and Security

Portable definitions must never contain AWS credentials or tokens, passwords, private keys,
presigned identities, SSM session responses, lease generations, process identities, browser
cookies/history or integration consent/restore journals. Secret IDs are references, not values.
Infrastructure metadata can still be sensitive; a non-secret document is not automatically
appropriate for publication in a public repository.

Recipients authenticate using their own SSO and permissions. Reading a file cannot authorize
AWS access, create remote users or grant SSH/browser integration consent.

Keep local browser-profile paths, executable/helper paths, known-hosts trust, attachment paths,
and owned alias/key/browser records in local state. Define a persistent mapping from portable
document identity/source to local profile identity. A colleague's UUID or a duplicate attachment
must not inherit another profile's ownership or silently replace a local target.

Parsing must reject duplicate keys, unsafe YAML tags, executable content and unsupported required
versions. Specify finite file/depth/collection limits and alias handling before implementation.
Do not evaluate shell commands, fetch remote includes or implicitly expand environment variables.
Use established YAML/JSON parsers; do not implement a line-based YAML parser.

GUI saves must be atomic and compare the loaded file revision with the current one. A concurrent
external change requires Reload, Review Changes or Save a Copy; no last-writer-wins data loss.
Detect unsupported filesystem permissions/symlinks and report them without broadening access.
Never overwrite a selected destination without normal native save confirmation.

The owner accepted canonical formatting on 2026-10-15. GUI Save may normalize YAML and remove
comments. Make that policy clear before the first GUI write to an attached human-authored file;
do not describe these saves as textually lossless. Use deterministic output for useful diffs and
preserve validated supported values and permitted unknown optional fields. Normalize only on an
explicit save/migration action, never merely because a file was opened or changed externally.

## 5. Authentication and Transport Independence

Portable configuration changes do not fix or waive the observed authentication UX failure in
[F-17 and AUTH-01 through AUTH-07](./ssm-connect.spec.md#13-authentication-freshness-and-recovery-follow-up-2026-10-15).
Both native clients need silent renewal, actionable SSO status, same-target pending-action
recovery and preservation of healthy sessions. Keep auth freshness distinct from file validity,
local lease validity and established-channel health.

## 6. Acceptance Criteria

| ID | Scenario | Required Evidence |
| --- | --- | --- |
| CFG-01 | Export and open a current profile | Every supported non-secret feature survives; native enums/private persistence are not leaked as the public format. |
| CFG-02 | Equivalent YAML/JSON on Swift and .NET | Shared fixtures produce equivalent validated values, including quoted account IDs and default semantics. |
| CFG-03 | Existing v1 JSON | Explicit import/migration retains supported meaning; unsupported new versions fail without changing local state. |
| CFG-04 | GUI edits an attached file | Reloaded file contains the change and permitted unknown optional values. Canonical output is deterministic; comment removal/format normalization follows the disclosed save policy. |
| CFG-05 | Automation edits the attached file | The app detects the revision, validates and stages it; no connection or integration write occurs before Apply/consent. |
| CFG-06 | Invalid, partial, missing or read-only file | Last good profile and working transports remain; diagnostics identify the remedy without deleting data. |
| CFG-07 | External edit races GUI Save | No overwrite; a checked conflict offers recovery/copy without losing either edit. |
| CFG-08 | Shared identity collides with an existing profile | No key, alias, browser ownership or target crossover; local mapping/confirmation is verified. |
| CFG-09 | Unsafe/oversized YAML, duplicate or credential fields | Deterministic rejection; no execution, network fetch, secret logging or partial persistence. |
| CFG-10 | Another OS lacks a configured capability | Explicit unsupported-capability result, not a silently incomplete import or different client launch. |
| CFG-11 | Attach/import with default app settings | No AWS call, auto-connect enablement, browser read or SSH/editor setup write. |

## 7. Decisions Before Building

| Decision | Recommendation | State |
| --- | --- | --- |
| Source of truth | Attached file; Import as Local Copy remains distinct | Accepted 2026-10-15 |
| File granularity | One profile per file; multiple attachments | Accepted initial scope 2026-10-15 |
| Representations | YAML and JSON over the existing contract boundary | Local v2 contract and v1 read/explicit-save migration implemented; Windows reconciliation remains open |
| Comment/format fidelity | Deterministic canonical output; comments/layout may be normalized or removed on explicit GUI Save | Accepted 2026-10-15 |
| Automatic external Apply | No; validate and stage changes affecting active behavior | Safety requirement |
| OS scope | Existing macOS and WPF Windows clients; no new Linux desktop rewrite | Existing architectural direction |

This spec records the next product contract, not an authorization to perform the full port or
rewrite live profile storage. Build one accepted user-visible capability at a time with the
current macOS regression suite preserved.

## 8. Local macOS Implementation (2026-10-16)

The implementation is on the existing macOS branch without merging the cross-platform rewrite,
changing an installed app, or exercising live connections. The maintenance releases v0.5.1/v0.5.2
were independently verified as published; they do not contain this follow-up.

- [The v2 schema](../../contracts/connection-profile.schema.json) represents `tunnelOnly`, web
  forwards, browser choice/mode and remote editor settings. Enabled features declare required
  capabilities; unsupported required capabilities fail explicitly. Shared v1/v2 JSON and equivalent
  v2 YAML fixtures live in [contracts](../../contracts/fixtures/profiles/).
- The portable document remains separate from native `ConnectionProfile` persistence. Imported
  portable UUIDs never become local profile/SSH ownership IDs. Document identity and permitted
  unknown fields, including nested forward options, are retained through the store's GUI-save and
  re-export paths. Local browser paths remain in native storage only.
- Yams 6.2.2 is pinned. Its libyaml event parser enforces a 256 KiB UTF-8 file limit, depth 32 and
  8192 nodes before the recursive tree parser runs. Anchors, aliases, explicit tags, merges,
  duplicate keys and multiple documents are rejected. Scalars use JSON-compatible booleans and
  finite decimal numbers with at most 38 significant digits and exponent -128 through 127;
  account IDs are strings.
- Settings supplies preview/attach/import-copy/export, checked canonical saves, save-copy recovery,
  read-only indication, two-second file monitoring, pending review/Apply, Locate and Detach.
  Invalid/missing files keep the native last-good configuration. A changed document identity
  requires a new attachment rather than inheriting the old profile's access.
- Saves use macOS file coordination, no-follow regular-file checks, revision checks, a same-directory
  temporary file, security-metadata preservation, fsync and atomic replacement. New exports use
  mode 0600 without inherited ACL grants. Symlink/hard-link files are refused. Revision conflicts
  preserve the external bytes and leave the GUI draft available for a local copy.
- File coordination serializes cooperating writers. This is not a claim of a filesystem-level
  compare-and-swap against arbitrary writers that ignore macOS coordination.

Tests exercise CFG-01 through CFG-11 on the macOS codec/store seams, including the exact resource
boundaries, actual automatic file detection, shared migration fixtures and a pre-commit external
edit. CFG-02 now also executes the .NET codec against actual Swift exports and vice versa.
CFG-10's native Windows behavior, save-panel/editor UI interaction and hostile
uncoordinated-writer interleavings remain **not verified**; see the Windows follow-up below.

### Executed Local Verification

- Release-mode Swift suite: **245 tests across 34 suites passed**, with every live browser/SSM
  opt-in explicitly unset. The event-parser file/depth/node boundary tests passed.
- Draft 2020-12 schema validation passed, including the v2 fixture and rejection of missing
  required capabilities and nested credential fields.
- Isolated ARM64 Release `.app` build passed with the macOS 14.0 deployment target. App and both
  embedded helper signatures passed deep/strict checks; the Session Manager plugin reports
  `1.2.814.0`. Yams/libyaml notices are included in the package resource bundle.
- The ZIP passed integrity checks. Its unpacked app passed signature verification and its
  third-party notices matched the source notice file.
- Unreleased local ZIP SHA-256:
  `1f6300604c6432bf9af701befd6db715645d0733f8420e709e65cf6365802964`.

The SDK-matched Xcode Swift compiler (`/usr/bin/xcrun swift`) was used. The PATH-selected Swiftly
compiler failed against the installed SDK; no global toolchain setting was changed. Existing
Xcode device/simulator and Swift concurrency warnings did not fail the final build. No candidate
was installed or launched, no live authorization was performed, and no commit/push/release occurred.

## 9. Parallel Windows Follow-Up (2026-10-16)

The Windows increment is uncommitted on `feature/windows-profile-auth-followups`, based on the
inspected port at `33b68c1`, in the separate `ssm-connect-windows-followups` worktree. The original
macOS edits and existing audit/maintenance worktrees remain intact. This is not a wholesale merge
of the old modular Swift branch into released macOS.

- .NET reads v1 and v2 JSON plus YAML through YamlDotNet 18.1.0, with the same byte/depth/node
  limits and credential/alias/tag/duplicate-key refusals. Actual-client export fixtures cross both
  implementations, including GUI/native mapping with separate local versus portable identities.
- Shared negative fixtures pin malformed/null action and block shapes, strict UUID encoding and
  invalid inactive ports. Scientific optional values retain precision through canonical saves;
  this crossing exposed and fixed the macOS scientific-number re-import edge case.
- WPF supplies preview, Attach File, Import as Local Copy, canonical checked Save, Export, local
  copy, pending review/Apply, Locate and Detach. Application settings remain separate and can be
  saved without writing a read-only attached profile. Corrupt saved metadata is reported without
  discarding or rewriting the original file.
- The Windows adapter uses current-user SID checks, native file identity, no-follow/reparse and
  hard-link refusal, ACL preservation and same-directory atomic rename. UNC/mapped-network paths,
  alternate streams and ambiguous trailing-dot/space paths are unsupported rather than silently
  written. Those native filesystem guarantees require the actual Windows tests.
- Enabled Windows web/browser/editor capabilities are explicitly refused before attachment or
  AWS operations because their current adapters do not exist. Their data can be represented by
  the portable contract; representation is not runtime support or permission to downgrade to DCV.
- YAML attribution is included in the app output/publish content and MSI payload. Windows CI now
  checks the v2 exchanges and off-Windows SDK authorization suite; hosted execution was not started.

Executed here: **122 domain + 91 workflow + 11 SDK adapter + 6 persisted-store tests passed**.
All Windows/WPF/harness/test projects cross-build with zero warnings/errors. **Six native
filesystem tests were skipped on macOS**, explicitly, not counted as passing. V1 schemas,
39 workflow fixtures and three legacy exports still validate; actual Swift/.NET v2 exports pass
the v2 schema. Actionlint 1.7.12 and installer XML/notice-copy checks passed. Windows-native UI,
SSO expiry/revocation, ACL/rename behavior, MSI install/upgrade/uninstall and browser/editor
runtime parity remain open.

Both ordinary and single-file `win-x64` publish outputs were produced without launching them.
The resulting GUI executables identify as Windows x86-64 PE images, and the YAML notice matches
the published sidecar even with single-file publishing. These are framework-dependent build
payloads, not verified installers: .NET 10 Windows Desktop and a usable Session Manager plugin
are still runtime prerequisites. No Windows payload was installed or executed.

## 10. Independent macOS Release Candidate (2026-10-16)

The macOS release branch is based on current main `9d0f74b`, retaining both maintenance merges.
The original dirty worktree, Windows branch and running editor/DCV/app sessions are unchanged.
This candidate is published for review in [PR #26](https://github.com/vhco-pro/ssm-connect/pull/26).

Independent correctness review found two release blockers, both corrected before merge:

- Saving a connected profile could change the shared auth context while the desktop retained
  its original target, stranding Reconnect or Stop. Established-target authorization is now
  retained separately; saved configuration is pending until explicit adoption. Eight regression
  cases cover display-name/target edits with reconnect, stop, disconnect and wake recovery.
- Per-forward unknown values followed an editable local port, so port changes/swaps could lose
  or transfer them. These values now travel with the native edited item and private persistence,
  not an editable matching key; the public document never exposes the internal metadata wrapper.
  Regression coverage includes port changes, swaps, reordering and native persistence.

The reviewer confirmed both original findings addressed and found no high-confidence, tightly
coupled defect in the fix hunks. The exact-current-main full Release suite passed **247 tests
across 34 suites**. Hosted checks and candidate packaging are tracked separately from this local
test evidence. Automatic editor-lease continuation remains explicitly unimplemented under
[LEASE-01 through LEASE-08](./remote-vscode.spec.md#15-automatic-editor-lease-continuation-2026-10-16).