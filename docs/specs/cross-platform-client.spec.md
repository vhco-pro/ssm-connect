---
status: draft
status_description: "Shared Swift core direction selected; native feasibility, integration and platform decisions, independent spec review and acceptance remain open."
issue: null
goal: "Use SSM Connect on macOS, Windows and Linux through one shared Swift implementation of its connection behavior, retaining native interfaces and current macOS functionality."
branch: feat/shared-swift-core
covers:
  - SSMConnectKit/
  - SSMConnect/
  - windows/
  - linux/
  - contracts/
  - packaging/
  - project.yml
  - scripts/
  - .github/workflows/
  - spikes/swift-portability/
---

# Shared Swift core and native desktop clients

## Context

### Owner summary

SSM Connect already supplies the required workstation workflows on macOS. The
owner wants the same application on Windows and Linux while reusing that working
Swift implementation. The selected direction is one shared Swift core with
native presentation and platform adapters. It does not require a Go, Rust or C#
rewrite of the connection algorithms.

This revises the August design, which deliberately maintained separate Swift and
C# cores with shared behavioral tests. Windows C#/WPF work remains useful for its
UI, operating-system adapters, installer experience and tests. Its duplicate
domain, authentication and workflow implementations are reference material, not
the new runtime architecture. The earlier Swift target separation is also useful,
but it predates the current macOS browser, editor, profile and recovery features.
Implementation must preserve the current versions of those features.

The consolidation branch starts from released macOS main at
`eb4f0bc0b8f98f206ed519feb461c70ba3614b41`. A preservation merge retains the
old branch and all 42 formerly dirty/untracked source files without applying
them over current macOS code. The preserved implementation is accessible through
Git history, not included as a second active core. Extraction pointers appear
below.

Swift supports Windows and Linux, but this application's exact SDK, networking,
filesystem and process dependencies have not been verified there. The GUI/core
bridge, supported OS/CPU matrix, Linux interface and performance budgets remain
owner decisions. Compilation alone will not establish native support.

This document is a draft and replaces the old two-core scope. Its historical
acceptance and passing tests do not accept or verify this revision. The current
request authorizes branch preparation, preservation and specification work,
not the application rewrite, installation, live AWS access or release. The owner
requested branch-first preparation for this revision; main remains unchanged.
Further work uses vh-adlc review, acceptance, tasks and implementation gates.
The owner's subsequent request authorizes publishing this consolidation branch,
retiring the old SDD flow and running bounded, credential-free portability and
integration spikes. It does not authorize the production rewrite or live AWS,
browser, editor or workstation operations.

### Existing workflow and baseline

The repository previously used separate specifications, plans and reviewer
summaries. The historical
[region-failure plan](https://github.com/vhco-pro/ssm-connect/blob/eb4f0bc0b8f98f206ed519feb461c70ba3614b41/docs/plans/bug-invalid-region-connect-failure.plan.md)
and
[implementation summary](https://github.com/vhco-pro/ssm-connect/blob/eb4f0bc0b8f98f206ed519feb461c70ba3614b41/summaries/bug-invalid-region-connect-failure.md)
record that process. Those files have been removed from the active tree, not
from Git history. No pinned repository instruction entry point existed at the
inspected main commit.

[AGENTS.md](../../AGENTS.md) now pins vh-adlc conventions and declares
`docs/specs/` as the feature root. This document contains the active spec and
plan; historical plans and summaries are not an alternative execution route.

All remaining macOS worktrees were clean in the 2026-11-12 inventory. Their
delivery heads match merged pull requests and are included in released main:
[profile/auth work](https://github.com/vhco-pro/ssm-connect/pull/26),
[distribution specifications](https://github.com/vhco-pro/ssm-connect/pull/27),
[editor continuation](https://github.com/vhco-pro/ssm-connect/pull/28),
[replacement/browser work](https://github.com/vhco-pro/ssm-connect/pull/31) and
[recovery guidance](https://github.com/vhco-pro/ssm-connect/pull/34).
Distribution signing remains specified, not implemented.

Current macOS behavior is defined by the
[client spec](ssm-connect.spec.md),
[portable profiles](portable-profiles.spec.md),
[web forwards](web-forwards.spec.md),
[browser bootstrap](browser-bootstrap.spec.md),
[native editor](remote-vscode.spec.md) and
[workstation replacement](logical-workstation-replacement.spec.md).
Preserve their documented limits as well as their implemented behavior.
[Integrated editor-browser routing](remote-browser-private-dns.spec.md) and
[trusted macOS distribution](macos-trusted-distribution.spec.md) retain their
separate, unfinished scopes.

The current [package manifest](../../SSMConnectKit/Package.swift) builds one
umbrella target. OS responsibilities are still mixed into orchestration:
`SSMConnectKit/Sources/SSMConnectKit/StateMachine/ConnectionStateMachine.swift:1`
imports Darwin and owns shutdown signals;
`SSMConnectKit/Sources/SSMConnectKit/Auth/AWSAuthProvider.swift:1` imports AppKit
and opens the browser. These are boundaries to refactor, not a reason to translate
the working algorithms into another language.

## Scope

Included:

- Extract and reuse current Swift domain, configuration, authentication and
  desktop/web/editor workflow behavior.
- Keep the macOS SwiftUI interface and its observable user behavior.
- Supply Windows and Linux interfaces backed by that same Swift core.
- Implement OS adapters for process ownership, files, local integration,
  notifications and other native capabilities.
- Reuse historical Swift separation, Windows UI/adapters, fixtures and packaging
  work selectively, with current regression tests.
- Preserve profile compatibility, consent, target identity, recovery and
  independently releasable platform artifacts.

Not included:

- A second implementation of connection algorithms in C#, Go or Rust.
- Transpiling SwiftUI, replacing native desktop rendering with a web UI, or
  introducing a permanent system service without a separate decision.
- Replacing Session Manager plugin, OpenSSH, Amazon DCV or their wire protocols.
- Changes to remote workstation infrastructure, SSH policy, browser policy or
  the companion session agent merely to make a client test pass.
- Claiming every OS, Linux distribution, desktop, browser or CPU is supported.
  Initial targets are the owner's macOS, Windows and Linux hosts; the exact
  supported matrix is Q2.
- Automatically including unfinished features from related specifications.

## Design

### One implementation, several shells

```text
macOS SwiftUI --------+
Windows native UI ---+--- versioned commands/events --- shared Swift core
Linux desktop UI ----+                                      |
                                                      platform ports
                                                           |
                                                OS-specific adapters
```

The same core source supplies profile rules, authorization coordination,
connection state machines, retry/cancellation policies, transport orchestration
and recovery decisions on every supported platform. Each target is compiled and
packaged for its OS/architecture. Native adapters remain necessary beyond the UI.

The presentation layer renders snapshots and sends commands. It must not
reimplement AWS sequencing, retry rules, profile validation or target/lease
ownership. C# may remain the language of a Windows shell and adapter; that does
not justify retaining the separate C# core.

Use the historical target split as prior art:

| Boundary | Responsibility |
| --- | --- |
| `SSMConnectDomain` | Models, validation, portable document semantics, state/event values and typed errors. |
| `SSMConnectWorkflow` | Authentication and desktop/web/editor orchestration against injected ports. |
| `SSMConnectAWS` | Swift SDK calls, credential providers and error translation. |
| Platform adapters | Native files, process containment, browser/editor integration, clipboard, notifications and startup. |
| UI/composition | Native presentation, user consent, event observation and dependency assembly. |

Names may be adjusted when tasks are written. Preserve compatibility through
the existing umbrella where needed; do not make current macOS callers migrate
unnecessarily. Domain/workflow boundaries must not import AppKit, SwiftUI,
Darwin, ServiceManagement, UserNotifications or expose AWS SDK/native UI types.
Foundation APIs also require platform checks; importing Foundation is not proof
that every API used is portable.

### Integration and feasibility

Q1 selects an embedded library interface or a bundled user-scoped helper with
private IPC. Both expose high-level commands, ordered state/events, typed
failures, cancellation and explicit shutdown. UI updates must remain responsive.
Do not pass Swift object layouts directly across a foreign-language boundary.
Do not implement both integration mechanisms as permanent alternatives.

If a helper is chosen, define framing, version negotiation, endpoint/process
ownership, failure reporting and crash cleanup. It is not an unauthenticated
localhost web service. SSH raw-stream proxy traffic remains separate from
control messages; diagnostics must not corrupt its stdout.

Before broad extraction, the first accepted implementation increment must prove
the selected bridge and exact Swift dependency stack on native Windows and
Linux. Exercise SSO authorization/refresh, an AWS service call, real SSM/plugin
I/O, cancellation and owned-child cleanup. A dependency blocker stops that
increment for an owner decision; it does not silently authorize another core
language, duplicated workflow or CLI-based authentication fallback.

The authorized, credential-free spike is reproducible through
[swift-portability.yml](../../.github/workflows/swift-portability.yml) and
[its runner](../../spikes/swift-portability/run.sh). It uses native
`ubuntu-24.04` and `windows-2025` hosted runners as test environments, not a
promised desktop support matrix. It compiles the existing region validator and
AWS config parser unchanged, exercises a small Swift helper over private
stdin/stdout pipes, then builds/loads the currently locked AWS SDK modules and
YAML dependency in an isolated package.

This is not a GUI, complete extracted workflow or production IPC protocol.
Passing it does not prove SSO login/refresh, real SSM traffic, process
containment, filesystem security or native browser/editor integration. The
spike does not read AWS credentials or perform service calls. Q1 remains open
while the helper approach is evaluated.

### Behavior, identity and local state

Preserve all current supported capabilities, including single-user and
identity-only multi-user DCV, tunnel-only connections, web forwards, managed
browser consent/restore, native VS Code, authorization recovery, rolling leases
and explicitly confirmed workstation replacement.

Desktop, web and editor actions remain independent. Headless paths must not
fetch a DCV password, provision a desktop or launch Viewer. Unsupported required
capabilities produce an actionable refusal before AWS or local setup effects;
they never silently downgrade to a different connection mode.

Keep stable local profile and editor authority identities. Do not copy lease
ownership, browser paths or user consent from one machine to another. Preserve
v1/v2 profile reading, canonical-save consent, unknown-field handling, revision
conflict behavior and connected-profile staging. Use native ownership,
permission and atomic-file guarantees rather than translating POSIX checks
literally to Windows.

Authorization state and renewal decisions belong to the shared core.
Platform/UI adapters may open an approved sign-in URL and report interaction,
but do not own a parallel authentication state machine. Ordinary snapshots,
profiles and logs exclude credentials and tokens. Preserve explicit
password-copy behavior through a protected capability, not generic event logs.
Existing authorized SSO cache behavior is not a license to persist credentials
in profiles or new integration metadata.

### Preservation and selective reuse

The preservation snapshot is
`ce24cf25983f05c243d0f6218e719614a48d6845`, with tree
`116eb74004527f7fe741dbadd93077e1091113fe`.
It contains all 42 source changes from the old Windows follow-up worktree.
Its parent, `33b68c1365a2ad325068190ddeb098b49467cdfe`, retains the earlier
committed port. Preservation merge
`0a38c0eae8f526c825e2f0d30d4342bcf631df48` makes both reachable from this branch
without changing the active application source tree.

Read a preserved file with `git show ce24cf2:<path>`:

| Preserved path | Reuse |
| --- | --- |
| `SSMConnectKit/Package.swift` and `Sources/SSMConnectDomain`, `SSMConnectWorkflow`, `SSMConnectAWS`, `SSMConnectMacOS`, `SSMConnectUI` below that package | Earlier Swift boundaries, injected ports and composition. Reapply to current code; do not restore the stale implementation wholesale. |
| `windows/src/SSMConnect.App/` | WPF settings, tray, profile-file UI and Windows interaction experience, after removing ownership of connection rules. |
| `windows/src/SSMConnect.Windows/` | Native ACL/file identity, process containment, launch, clipboard and startup behavior. Adapt to the selected Swift boundary. |
| `contracts/fixtures/workflows/` and Windows tests | Historical behavioral cases, negative cases and native-adapter expectations. Extend for current behavior; old passing results are not fresh proof. |
| `packaging/` and Windows workflows | Installer prerequisites, license notices and install/upgrade/uninstall lessons. Rebuild around the new artifacts. |
| `windows/src/SSMConnect.Domain`, `SSMConnect.Workflow`, `SSMConnect.Aws` | Behavioral reference and test inputs only; no second production core. |

The current macOS source and tests remain the integration baseline. Historical
evidence stays in Git, including the old spec and handoffs. Do not copy their
completed criterion marks into this revision. Previous IDs AC-01 through AC-10
remain historical; this scope starts at AC-11.

Preservation merge `57a466ab723f444de27f1d20b5430f9075f54ece` also retains
the original macOS feature histories, the older replacement draft and the
replacement acceptance-note branch. The acceptance notes at `c9c38fb` were
already ancestors of the released recovery head `7aa7d52`; they are not an
unreleased application feature. This merge changed no active source.
The older local safety snapshot `fc2edd8`, explicitly marked not for publication,
remains local and was not added to the publishable branch.

### Migration, performance and release boundaries

Refactor in reviewed increments with a working macOS rollback point. Preserve
profiles and local integration metadata; do not perform irreversible migrations
or redirect healthy connections during extraction.

Measure startup, idle memory/CPU, UI responsiveness and connection latency.
Language choice does not establish performance parity. Q4 sets numeric budgets
and a reproducible baseline before this draft can be accepted.

Retain the existing macOS release path through
[release.yml](../../.github/workflows/release.yml),
[release.sh](../../scripts/release.sh), the GitHub release ZIP and the Homebrew
cask. New helper/framework artifacts, if selected, must be bundled, licensed and
signed with the application. Windows and Linux need native build/test/package
paths, prerequisite checks and install/upgrade/uninstall verification for the
chosen matrix. Do not resurrect old release workflows as if they publish the new
core, or change macOS signing claims through this refactor.

## Acceptance Criteria

- [ ] AC-11: Each supported desktop client performs its connection workflows through the same shared Swift core, without a second language implementation of those rules.
- [ ] AC-12: Single-user and multi-user desktop connections retain the current authentication, readiness, viewer-launch and no-shared-user-fallback behavior on each supported DCV target.
- [ ] AC-13: Tunnel-only, web and editor actions operate independently without unintended DCV password fetch, desktop provisioning or Viewer launch.
- [ ] AC-14: Existing profiles remain readable and retain identity, portable fields, checked attached-file saves, conflict recovery and explicit consent across the migration.
- [ ] AC-15: One shared authorization workflow preserves silent refresh, explicit sign-in recovery, pending-action context and cancellation without redirecting established connections.
- [ ] AC-16: Supported browser integrations retain consent, ownership, restore and fail-closed private-domain routing without modifying unrelated browser or system settings.
- [ ] AC-17: Native editor access preserves stable workspace authority, owned leases, unsaved windows and explicit replacement/recovery behavior without weakening host trust.
- [ ] AC-18: Disconnect, cancellation, app exit, crash and supported sleep/logoff transitions leave no unintended owned local processes or reusable unauthorized access.
- [ ] AC-19: Profiles, ordinary state/events, diagnostics and temporary artifacts do not expose credentials or tokens; local caches and integration artifacts enforce the target OS's ownership and permission rules.
- [ ] AC-20: The macOS application retains its current native interaction and documented desktop, browser, editor and recovery behavior while using the extracted core.
- [ ] AC-21: Every declared Windows/Linux artifact installs, starts with its required dependencies, upgrades and uninstalls correctly on its declared native OS/CPU/desktop matrix.
- [ ] AC-22: Each declared client meets the owner-approved numeric startup, idle-resource, responsiveness and connection-latency budgets established under Q4.
- [ ] AC-23: Supported Windows and Linux clients complete real SSO/refresh, AWS/SSM/plugin and native-integration scenarios; cross-compilation is not their sole support evidence.
- [ ] AC-24: macOS, Windows and Linux artifacts remain independently buildable and releasable, with all selected core/helper assets and required notices present in their final packages.

## Test Plan

| Criterion | Proof |
| --- | --- |
| AC-11 | Boundary checks and common-core tests on each OS, plus a native UI command/event drive-through proving all clients invoke the same Swift implementation. Inspect the built dependency graph for duplicate production workflows. |
| AC-12 | On each supported native DCV target, connect in both modes, exercise readiness failure/retry and agent rejection, and verify authenticated Viewer access plus cleanup. Rejection must not fall back to a shared identity. |
| AC-13 | Run headless, web-only and editor-only flows with DCV unavailable; assert zero password/provision/Viewer operations and verify an owned working transport. Repeat with concurrent capabilities. |
| AC-14 | Run current profile/codec/store tests with `swift test --package-path SSMConnectKit`; cross-import v1/v2 fixtures, change attached files externally, race Save, and verify identity, unknown fields, consent and original bytes on conflict. Repeat native file-permission/rename cases. |
| AC-15 | Controlled clock/expiry tests and native expiry/revocation scenarios: silent renewal, rejected refresh, one explicit login, pending-action resume, profile change, Stop and cancellation. Healthy established transports retain their target/auth context. |
| AC-16 | On each supported browser/OS combination, run consent/setup/restore, policy/ownership refusal and transport-loss scenarios. Selected private suffixes must fail closed while unrelated public browsing remains unchanged. |
| AC-17 | Native Remote-SSH scenarios cover concurrent windows, expired authorization/lease recovery, dirty buffers, app interruption and confirmed replacement. Reopen the original workspace authority and verify remote commands/editing without bypassing host-key checks. |
| AC-18 | Kill only the owned test client/process by PID, then check local child containment and server-session recovery; repeat disconnect/cancel, restart, sleep and logoff scenarios from a separate native test controller. |
| AC-19 | Seed synthetic secrets, then inspect profiles, state/events, logs and temp artifacts; exercise cross-user access, file substitution and stale-owner/generation cases using native OS permissions. Report unexecuted native cases separately. |
| AC-20 | Run the complete current macOS package suite and build the release artifact on its native runner. Execute the current documented native flows against the baseline, without replacing an installed app unless separately authorized. |
| AC-21 | Install the final packaged payload on a clean native target, verify dependencies and launch, upgrade over the prior candidate, uninstall and check owned residue. Record exact OS/CPU/desktop and artifact hash. |
| AC-22 | Before acceptance, record numeric limits in this document. On matched native targets measure repeated startup-to-ready, settled idle RSS/CPU, UI-command response and cold/warm connection timings under the recorded workload; compare every metric to its approved limit. |
| AC-23 | Native Windows/Linux feasibility records must include exact Swift/SDK/plugin versions, interactive SSO plus refresh, AWS response, usable SSM traffic, cancellation and owned-process cleanup. Later full native acceptance must use the final UI/core integration. |
| AC-24 | Rebuild through each actual release path; inspect the unpacked final artifact for selected core/helper/runtime assets, executable permissions or signatures as applicable, and licenses. Verify one platform's release does not require publishing another's. |

## Tasks

None yet. Resolve the questions, review the exact spec commit independently and
obtain owner acceptance before generating one-commit tasks through vh-adlc.
The branch preparation and historical snapshot are not implementation tasks or
evidence that the criteria above are met.

## Open Questions

### Q1: How should non-Swift native interfaces call the shared core?

**Recommendation:** A. Evaluate a bundled user-scoped helper first, preserving
Swift core ownership while avoiding foreign-language object and async ABI coupling.

| Option | You get | It costs |
| --- | --- | --- |
| **A. Bundled helper with private IPC** | One command/event interface usable by different native UI languages. | Another owned process, protocol/versioning, secure IPC and lifecycle packaging. |
| **B. Embedded library with a small C-compatible interface** | In-process calls without a separate core process. | Per-language bindings, async callback/cancellation and memory ownership work. |

**Why this is yours:** This changes deployment, debugging and the integration
contract. Neither option has been proven for this app on Windows/Linux.

### Q2: Which OS versions, CPUs and Linux desktops are required for the first supported release?

**Recommendation:** A. Name the owner's actual Windows/Linux targets and retain
the current macOS baseline; add other targets only with dependency and native proof.

| Option | You get | It costs |
| --- | --- | --- |
| **A. An explicit initial host matrix** | Bounded native acceptance and packaging. | Other distributions, desktops and architectures remain unsupported until added. |
| **B. A broader declared matrix immediately** | More initial supported environments. | Additional toolchains, dependency/Viewer checks, native runners and packaging. |

**Why this is yours:** Swift availability alone does not establish SDK, plugin,
browser, DCV or desktop integration support. No Fedora/Ubuntu or CPU choice has
been inferred from an unrelated tagged file.

### Q3: Which native interface should Linux use?

**Recommendation:** A. Select a desktop-native toolkit after Q2, while retaining
the existing macOS UI and evaluating reuse of the Windows WPF shell.

| Option | You get | It costs |
| --- | --- | --- |
| **A. A Linux-native shell over the shared core** | Native desktop integration without changing the existing macOS interface. | A separate presentation layer and its toolkit bindings. |
| **B. A shared Windows/Linux presentation toolkit** | More shared UI code. | Changes to the existing WPF shell and a separate native-integration assessment. |

**Why this is yours:** Core reuse does not decide the desktop toolkit or tray,
accessibility and Wayland/X11 experience.

### Q4: What measured performance budgets must the migration preserve?

**Recommendation:** A. Measure the current macOS app and approve numeric
tolerances plus explicit Windows/Linux limits before accepting this spec.

| Option | You get | It costs |
| --- | --- | --- |
| **A. Baseline-relative macOS limits and explicit new-platform budgets** | Evidence-based parity with the working app. | Native baseline collection and an owner budget decision before implementation. |
| **B. Fixed absolute limits for all platforms** | One initial pass/fail target independent of the old app. | Choosing limits without current measurements may exclude usable hosts or miss regressions. |

**Why this is yours:** Performance equivalence cannot be inferred from retaining
Swift. This branch preparation ran no application benchmarks.

## Review Log

| Date | Review | Kind | Commit | Model | Isolation | Outcome |
| --- | --- | --- | --- | --- | --- | --- |

No independent review or acceptance has been recorded for this revision.

## Sources

- Owner direction on 2026-11-12: preserve working Swift, share its core across
  macOS/Windows/Linux, permit component redesign, adopt vh-adlc and prepare a
  clean consolidation branch before implementation.
- [Current main baseline](https://github.com/vhco-pro/ssm-connect/commit/eb4f0bc0b8f98f206ed519feb461c70ba3614b41):
  application source and release behavior retained by this branch.
- `git show 2aa079d:docs/specs/cross-platform-client.spec.md`: the original
  two-core decision explicitly rejected Swift/.NET FFI for integration cost,
  not a demonstrated inability to run a refactored Swift core on Windows.
- `git show ce24cf2:SSMConnectKit/Package.swift`: the historical Swift target
  split; current macOS features still need to be retained during extraction.
- `git rev-parse ce24cf2^{tree}` returned
  `116eb74004527f7fe741dbadd93077e1091113fe`; the preservation commit matched
  the staged source tree, including all 18 previously untracked files.
- `git diff --exit-code 0a38c0e^1 0a38c0e -- .` passed: the archival merge
  changed no active source files.
- [Swift platform support](https://www.swift.org/platform-support/): Swift
  development/deployment support includes Windows and Linux.
- [AWS SDK for Swift setup](https://docs.aws.amazon.com/sdk-for-swift/latest/developer-guide/setting-up.html):
  SDK cross-platform/toolchain guidance; not native validation of this app.
- [Feature-document conventions](https://github.com/vhco-pro/docs/blob/d8f07c9dd69038375a535af8ad586086688f85ab/conventions/feature-documents.md)
  and [prose guide](https://github.com/vhco-pro/docs/blob/d8f07c9dd69038375a535af8ad586086688f85ab/guides/humanize-prose.md):
  the pinned format and authoring rules for this revision.
