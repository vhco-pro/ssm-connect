---
status: draft
status_description: "R-6 found one blocking overstatement about Linux install failures, raised as Q20. The Windows AWS CRT build remains the first increment's blocker."
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

The owner has decided the open design choices. Each Windows and Linux shell
runs its own private Swift helper as a child process over pipes, ending with the
shell; macOS keeps linking the core in-process. Nothing is replayed: if the
helper stops, its processes and editor channels end with it, in-flight actions
fail and one replacement starts before the app shows an error with Retry.
Installing over or removing a running app asks first on Windows and waits for
the user to quit on Linux. Browser support
matches macOS on every platform. The DCV desktop becomes optional: the editor,
web forwards and tunnels are the primary paths and work against targets with no
desktop and on clients without Viewer. The first release targets macOS
14+ on Apple silicon, Windows 11 x64, Fedora 43 x86-64 with KDE Plasma 6 and
Ubuntu 24.04 LTS x86-64. Linux gets a Qt 6 shell; Windows keeps WPF. Windows ships
a per-user, unsigned WiX MSI through WinGet; Linux ships `.rpm` and `.deb` files
on the GitHub Release. Code signing (SignPath Foundation) and apt/dnf
repositories on pkg.vhco.pro are later features. Performance is held to the
current macOS release: the refactored macOS app within 10% of it on every
metric, Windows and Linux within 1.5 times.

Native spikes execute unchanged Swift model/parser code and a small helper on
Windows and Linux. The locked SDK/YAML probe passes on Linux; the Windows AWS CRT
build fails with both build backends. The first implementation increment fixes
that through an upstream packaging fix or a compatible release, without a fork.
Full workflows, authentication, transports and native adapters are unverified,
and no criterion is met by these subset checks.

This draft replaces the old two-core scope; its historical acceptance and
passing tests do not carry over. The owner has authorized branch preparation,
preservation, specification and bounded credential-free spikes, not the
production rewrite, installation, live AWS, browser, editor or workstation
operations, or a release. Further work goes through vh-adlc review, acceptance,
tasks and implementation gates.

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

### Observed credential-free portability results

[Run 43134523059](https://github.com/vhco-pro/ssm-connect/actions/runs/43134523059)
tested commit `6c78b919ad64c36a0b5dcdc0cea78e698079dbff` with Swift 6.4.2.
The isolated package retained AWS SDK for Swift 1.7.62, aws-crt-swift 0.64.1
and Yams 6.2.2 from the application lockfile.

| Native test environment | Unchanged region/config code and helper protocol | Locked SDK/YAML build and load |
| --- | --- | --- |
| Ubuntu 24.04 x86-64 | Passed all eight command/error/shutdown responses. | Passed; six SDK client types linked and YAML decoded to the expected version. |
| Windows Server 2025 x86-64, build 26100 | Passed the same eight responses. | Failed while importing the AWS CRT C modules. YAML was not independently verified on Windows. |

The Windows failure reaches `aws-c-common/include/aws/testing/aws_test_harness.h`
through the generated `AwsCCommon` module includes. Diagnostics include
undeclared `EXCEPTION_EXECUTE_HANDLER`, `GetConsoleMode` and `SetConsoleMode`,
followed by inability to build `AwsCAuth`. This is a dependency/build
compatibility observation, not evidence that Swift or the reused model/parser
code cannot execute on Windows.

The first run used Swift 6.4.2's default `swiftbuild` backend.
[Follow-up run 43136183821](https://github.com/vhco-pro/ssm-connect/actions/runs/43136183821)
tested commit `588666555e691b6e5432879e535d20fe61ef2334` without changing pinned
dependencies:

- Linux repeated both passing checks.
- Windows repeated the passing model/helper checks with both backends.
- Windows `swiftbuild` reproduced the AWS CRT module-header errors.
- Windows `native` instead failed compiling
  `aws-c-io/source/bsd/kqueue_event_loop.c` because `sys/event.h` is absent.
  The pinned CRT manifest has Windows-specific exclusions but does not exclude
  `source/bsd` in that branch. The native backend is also deprecated.

Changing the backend alone therefore does not unblock the locked Windows
dependency build. This identifies dependency packaging/build work to investigate
before a production migration, rather than a reason to translate the Swift core.
The owner chose an upstream packaging fix or compatible release first (see Design). No dependency patch or upgrade was applied.

These are subset and dependency-loading checks. No full connection state
machine, real SSO/refresh, SSM session, native GUI or desktop integration has
been verified. No product acceptance criterion is marked met by this spike.

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
  independently releasable platform artifacts, including macOS upgrade from and
  rollback to the current release.
- Support this first-release matrix: macOS 14 or later on Apple silicon (the
  current release baseline), Windows 11 x64, Fedora 43 x86-64 with KDE Plasma 6,
  and Ubuntu 24.04 LTS x86-64 with its default desktop.
- Ship a per-user WiX MSI for Windows, attached to the GitHub Release and
  published through WinGet as `VHCo.SSMConnect`, and `.rpm` (Fedora) and `.deb`
  (Ubuntu) packages attached to the GitHub Release.

Not included:

- A second implementation of connection algorithms in C#, Go or Rust.
- Transpiling SwiftUI, replacing native desktop rendering with a web UI, or
  introducing a permanent system service without a separate decision.
- Replacing Session Manager plugin, OpenSSH, Amazon DCV or their wire protocols.
- Changes to remote workstation infrastructure, SSH policy, browser policy or
  the companion session agent merely to make a client test pass.
- Any OS, distribution, desktop or CPU outside the matrix above, including
  Windows on ARM64. A target is added later only with dependency and native proof.
- Code signing for Windows or Linux artifacts. Windows signing through SignPath
  Foundation is a later feature; the MSI ships unsigned.
- Hosted apt or dnf repositories. Signed repositories on pkg.vhco.pro are a later
  feature.
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
ownership. The Windows shell stays C#/WPF and the Linux shell is Qt 6, with its
tray icon through StatusNotifierItem. Neither justifies retaining the separate
C# core.

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

Windows and Linux shells drive the core through a private Swift helper. Each
shell starts its own helper, bundled beside it in the same package, as a child
process connected by anonymous stdin/stdout pipes; there is no named pipe,
socket or other endpoint. Each helper runs in its own container: on Windows a
job object created for that helper with kill-on-close, whose only handle the
shell holds; on Linux a transient systemd user service whose main process is the
helper, created with `BindsTo=` and `After=` on the shell's own systemd scope.
KDE and GNOME start each application in such a scope; a shell started outside
one creates it at start-up. The helper also exits when its stdin pipe closes.
When the shell ends, the job handle closes on Windows, and on Linux the shell's
scope stops, so systemd stops the helper's unit. Either way the operating
system ends every process in the container, including plugin and SSH
descendants, even when the helper is hung. When a helper stops
while the shell keeps running, the shell explicitly ends that helper's container
(`TerminateJobObject` on Windows, stopping the unit on Linux) and waits until it
reports no remaining processes before it starts any replacement. The shell is single-instance
per user session: a second launch focuses the running one. The macOS app links
the core in-process, as today. Nothing else needs the helper: the SSH proxy is a
separate executable that reads a lease file (`SSMConnectKit/Package.swift:14`,
`SSMConnectKit/Sources/SSMConnectKit/Tunnel/RemoteSSHBridge.swift:115`).

The helper exposes high-level commands, ordered state/events, typed failures,
cancellation and explicit shutdown, and UI updates stay responsive. The protocol
defines framing and a start-up handshake that refuses a helper from a different
build than its shell. Swift object layouts never cross a foreign-language
boundary. Diagnostics go to stderr or a log, never into the protocol stream.

Command delivery follows these rules:

- Each command carries a shell-chosen ID. The core alone owns state: before any
  side effect it admits the command or refuses it with a typed error against its
  current state, and answers each admitted command with exactly one terminal
  result: completed, failed with a typed error or cancelled. Generations stay
  internal to the core, per workflow, as `AuthorizationSession` keeps them today
  (`SSMConnectKit/Sources/SSMConnectKit/Auth/AuthorizationSession.swift:197-226`),
  so cancelling one workflow cooperatively never affects another. A cancel that
  times out (below) replaces the helper and so ends every workflow it owns.
- Pipes do not drop individual replies; a reply is lost only when the helper
  exits. The shell then fails every in-flight command with a "core stopped"
  result, ends the old helper's container as above, and then starts one
  replacement helper. Neither side ever resends a command; the user starts the
  action again if they want it.
- Every helper, including the first, must complete its handshake within 10
  seconds and answer a heartbeat every 15 seconds. A helper that misses either is
  killed and counts as stopped. The shell starts at most one automatic
  replacement; that allowance comes back after a helper has run healthy for 10
  minutes or when the user presses Retry. When no automatic replacement is
  available, including when the first helper fails, the shell starts no helper
  and shows "SSM Connect core unavailable" with a Retry action. Retry starts one
  new helper under the same rules.
- Any pending command can be cancelled from the UI. If the core does not confirm
  the cancel with a terminal result within 10 seconds, the helper counts as
  unresponsive and is handled as stopped. No command has a new overall deadline;
  an AWS call waits as it does on macOS today until it finishes or is cancelled.
- The helper owns its editor leases, as the macOS app process owns them today
  (`SSMConnectKit/Sources/SSMConnectKit/StateMachine/RemoteDevelopmentStateMachine.swift:62-65`).
  When a helper stops, its leases' owner is gone, so the SSH proxy ends those
  channels (`SSMConnectKit/Sources/SSMConnectKit/Tunnel/RemoteSSHBridge.swift:40-63`)
  just as a macOS app crash ends them. VS Code keeps unsaved windows, and the
  existing editor recovery flow reconnects them through the replacement helper.
- An AWS call whose response never arrives is handled inside the core exactly as
  the in-process macOS app handles it today. The client
  has no server-side session cleanup today
  (`SSMConnectKit/Sources/SSMConnectKit/Services/SSMClients.swift:7-10`) and gains
  none: an SSM session AWS started before a helper stop, whose ID the client never
  received, ends at the account's Session Manager idle timeout.

Before broad extraction, the first accepted implementation increment must prove
the helper and the exact Swift dependency stack on native Windows and Linux.
Exercise SSO authorization/refresh, an AWS service call, real SSM/plugin I/O,
cancellation and owned-child cleanup. On Windows it first removes the AWS CRT
build failure through an upstream aws-crt-swift packaging fix or a compatible
SDK/CRT release; the project does not maintain a fork. If neither is available
within that increment, it stops for an owner decision. A blocker never silently
authorizes another core language, a platform-specific AWS adapter, a duplicated
workflow or a CLI-based authentication fallback.

The authorized, credential-free spike is reproducible through
[swift-portability.yml](../../.github/workflows/swift-portability.yml) and
[its runner](../../spikes/swift-portability/run.sh). It uses native
`ubuntu-24.04` and `windows-2025` hosted runners as test environments, not a
promised desktop support matrix. It compiles the existing region validator and
AWS config parser unchanged, runs a small Swift helper with stdin redirected
from a request file and stdout/stderr redirected to files
(`spikes/swift-portability/run.sh:29-31`), then builds/loads the currently locked AWS SDK modules and
YAML dependency in an isolated package.

This is not a GUI, complete extracted workflow or production IPC protocol.
Passing it does not prove SSO login/refresh, real SSM traffic, process
containment, filesystem security or native browser/editor integration. It proves batch command processing, not interactive IPC. The spike does not
read AWS credentials or perform service calls.

### Behavior, identity and local state

Preserve all current supported capabilities, including single-user and
identity-only multi-user DCV, tunnel-only connections, web forwards, managed
browser consent/restore, native VS Code, authorization recovery, rolling leases
and explicitly confirmed workstation replacement.

Windows and Linux support the same browser matrix as macOS
(`SSMConnectKit/Sources/SSMConnectKit/Services/BrowserBootstrap.swift:33-38`):
Chrome in Separate Browser mode and Zen in both Separate Browser and Use My
Browser modes. As on macOS, each product and mode is pinned per platform to the
exact version its native tests passed on, and other versions are unavailable.
A required integration is never omitted; AC-25's refusal covers only a browser
that is not installed or not at a supported version.

The DCV desktop is optional. The editor, web forwards and tunnel-only
connections are the primary capabilities, and they work fully against targets
with no DCV server or desktop environment and on clients without DCV Viewer.
Desktop, web and editor actions remain independent. Headless paths must not
fetch a DCV password, provision a desktop or launch Viewer.

Before any AWS call, process launch or configuration write, the core checks the
capabilities the requested action cannot work without: the Session Manager
plugin for every action, OpenSSH and VS Code for editor actions, and a supported
browser for managed browsing. A missing one produces an actionable refusal
naming it, and the action never silently downgrades to a different connection
mode. DCV Viewer is not such a capability: a desktop connection on a client
without Viewer keeps its tunnel up and shows the current warning
(`SSMConnectKit/Sources/SSMConnectKit/StateMachine/ConnectionStateMachine.swift:489-502`).

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
or redirect healthy connections during extraction. The macOS stores keep their
keys and versions: `ssmconnect.profiles.v1`, `ssmconnect.attachments.v1`,
`ssmconnect.portableDocuments.v1` and the related settings keys
(`SSMConnectKit/Sources/SSMConnectKit/Services/ProfileStore.swift:21-25`), and the
version 1 editor recovery document
(`SSMConnectKit/Sources/SSMConnectKit/Services/EditorRecoveryStore.swift:35-39`).
State written by the refactored app stays readable by the current release, so
reinstalling it is a working rollback.

Language choice does not establish performance parity. The first implementation
task measures the current macOS release on its native host: startup to ready,
settled idle RSS and CPU, UI command response, and cold and warm connection
time, each repeated under a recorded workload. Those results are recorded here
as the baseline.

Every client is measured the same way. The measured processes are SSM
Connect's own: the macOS app, or a shell and its helper, excluding Session
Manager plugin, SSH, DCV Viewer, VS Code and browsers. Startup ends when the main
window or tray accepts input; a connection ends at its ready state. Each timing
is ten runs after one discarded warm-up, compared by median. Idle RSS is summed
across the measured processes after five settled minutes, and idle CPU averages
the next 60 seconds of one-second samples. Hardware and OS build are recorded
with every result. The baseline and the refactored macOS app run on the same
Mac and OS build, on mains power with Low Power Mode off and no other user apps
open. Windows and Linux are measured on named hosts recorded here before the
baseline is taken. Changing any of those hosts or OS builds means measuring the
baseline again. The refactored macOS app must stay within 1.10 times the
baseline on every metric; Windows and Linux clients within 1.5 times it.

Retain the existing macOS release path through
[release.yml](../../.github/workflows/release.yml),
[release.sh](../../scripts/release.sh), the GitHub release ZIP and the Homebrew
cask. New helper/framework artifacts, if selected, must be bundled, licensed and
signed with the application. Windows builds a per-user WiX MSI on a native
runner, attaches it to the GitHub Release and submits a WinGet manifest for
`VHCo.SSMConnect` whose SHA-256 matches that MSI. Linux builds `.rpm` and `.deb`
packages for the matrix and attaches them to the GitHub Release. Each needs
prerequisite checks and install/upgrade/uninstall verification on its target.

Installing, upgrading or removing never interrupts a running client without the
user agreeing. The Windows MSI uses Restart Manager to ask the user to close SSM
Connect; closing ends its connections cleanly, and declining ends the install
with nothing changed. On Linux a running shell and helper keep their old files
until the user quits. If such a shell needs a new helper after the upgrade, the
handshake refuses the newer build and the shell shows "SSM Connect was updated;
restart it" instead of the generic error. Removal follows the same rules: the
Windows uninstaller asks through Restart Manager, and on Linux a running client
keeps working until the user quits; if it then needs a helper, it shows "SSM
Connect was removed; quit it".

A failed MSI rolls back. The `.rpm` and `.deb` packages carry no maintainer
scripts that can fail after their files are unpacked: desktop and icon cache
refreshes are non-fatal. A failure therefore happens before or during unpacking,
which dnf and dpkg undo, and the previous version stays installed. Do not resurrect old release workflows as if they publish the new
core, or change macOS signing claims through this refactor.

## Acceptance Criteria

- [ ] AC-11: Each supported desktop client performs its connection workflows through the same shared Swift core, without a second language implementation of those rules.
- [ ] AC-12: Single-user and multi-user desktop connections retain the current authentication, readiness, viewer-launch and no-shared-user-fallback behavior on each supported DCV target.
- [ ] AC-13: Tunnel-only, web and editor actions operate independently without unintended DCV password fetch, desktop provisioning or Viewer launch, including against a target with no DCV server or desktop environment and on a client without DCV Viewer.
- [ ] AC-14: Existing profiles remain readable and retain identity, portable fields, checked attached-file saves, conflict recovery and explicit consent across the migration.
- [ ] AC-15: One shared authorization workflow preserves silent refresh, explicit sign-in recovery, pending-action context and cancellation without redirecting established connections.
- [ ] AC-16: Supported browser integrations retain consent, ownership, restore and fail-closed private-domain routing without modifying unrelated browser or system settings.
- [ ] AC-17: Native editor access preserves stable workspace authority, owned leases, unsaved windows and explicit replacement/recovery behavior without weakening host trust.
- [ ] AC-18: Disconnect, cancellation, app exit, crash and supported sleep/logoff transitions leave no unintended owned local processes or reusable unauthorized access.
- [ ] AC-19: Profiles, ordinary state/events, diagnostics and temporary artifacts do not expose credentials or tokens; local caches and integration artifacts enforce the target OS's ownership and permission rules.
- [ ] AC-20: The macOS application retains its current native interaction and documented desktop, browser, editor and recovery behavior while using the extracted core.
- [ ] AC-21: Every declared Windows/Linux artifact installs, starts with its required dependencies, upgrades and uninstalls correctly on its declared native OS/CPU/desktop matrix, including while a prior version is running, without interrupting it unless the user agrees.
- [ ] AC-22: Each declared client meets the startup, idle-resource, responsiveness and connection-latency budgets in Design against the recorded macOS baseline: 1.10 times for the refactored macOS app and 1.5 times for Windows and Linux.
- [ ] AC-23: Supported Windows and Linux clients complete real SSO/refresh, AWS/SSM/plugin and native-integration scenarios; cross-compilation is not their sole support evidence.
- [ ] AC-24: macOS, Windows and Linux artifacts remain independently buildable and releasable, with all selected core/helper assets and required notices present in their final packages.
- [ ] AC-25: An action whose required capability is unavailable on the platform is refused with a message naming that capability, before any AWS call, process launch or configuration write, and without switching to another connection mode.
- [ ] AC-26: Upgrading macOS from the current release to the refactored app, and reinstalling the current release afterwards, keeps profiles, attachments, editor recovery intent and integration metadata usable, with identity, consent and restore behavior unchanged.
- [ ] AC-27: On Windows and Linux, each shell's helper is reachable only through its own pipes and ends with its shell; every admitted command receives exactly one terminal result; and no command is ever repeated after a helper stop.

## Test Plan

| Criterion | Proof |
| --- | --- |
| AC-11 | Boundary checks and common-core tests on each OS, plus a native UI command/event drive-through proving the macOS app (in-process) and the Windows and Linux shells (through the helper) invoke the same Swift implementation. Inspect the built dependency graph for duplicate production workflows. |
| AC-12 | On each supported native DCV target, connect in both modes, exercise readiness failure/retry and agent rejection, and verify authenticated Viewer access plus cleanup. Rejection must not fall back to a shared identity. |
| AC-13 | On each platform, run headless, web-only and editor-only flows against a target with no DCV server or desktop environment, from a client with DCV Viewer not installed; assert zero password/provision/Viewer operations and verify an owned working transport. Repeat with concurrent capabilities. |
| AC-14 | Run current profile/codec/store tests with `swift test --package-path SSMConnectKit`; cross-import v1/v2 fixtures, change attached files externally, race Save, and verify identity, unknown fields, consent and original bytes on conflict. Repeat native file-permission/rename cases. |
| AC-15 | Controlled clock/expiry tests and native expiry/revocation scenarios: silent renewal, rejected refresh, one explicit login, pending-action resume, profile change, Stop and cancellation. Healthy established transports retain their target/auth context. |
| AC-16 | On each platform, for Chrome Separate Browser and Zen in both modes at that platform's pinned versions, run consent/setup/restore, policy/ownership refusal and transport-loss scenarios. Selected private suffixes must fail closed while unrelated public browsing remains unchanged. |
| AC-17 | Native Remote-SSH scenarios cover concurrent windows, expired authorization/lease recovery, dirty buffers, app interruption and confirmed replacement. On Windows and Linux, kill the helper during active editing: the editor channels end, unsaved windows remain, and editor recovery reconnects them through the replacement helper. Reopen the original workspace authority and verify remote commands/editing without bypassing host-key checks. |
| AC-18 | Kill only the owned test client/process by PID during an active transport, start no replacement client, and check that every owned descendant (helper, plugin, SSH) ends while unrelated processes keep running. On Linux, also suspend the helper with SIGSTOP before killing the shell and verify that systemd ends the helper's unit and all its processes within 10 seconds; repeat disconnect/cancel, restart, sleep and logoff scenarios from a separate native test controller. |
| AC-19 | Seed synthetic secrets, then inspect profiles, state/events, logs and temp artifacts; exercise cross-user access, file substitution and stale-owner/generation cases using native OS permissions. Report unexecuted native cases separately. |
| AC-20 | Run the complete current macOS package suite and build the release artifact on its native runner. Execute the current documented native flows against the baseline, without replacing an installed app unless separately authorized. |
| AC-21 | On a clean target for each matrix entry, install the final package (Windows 11 x64: `winget install` from a locally validated manifest for the MSI; Fedora 43: `dnf install` of the `.rpm`; Ubuntu 24.04: `apt install` of the `.deb`), verify dependencies and launch, upgrade over the prior candidate, uninstall and check owned residue. Repeat the upgrade with the prior candidate running an active connection: on Windows, declining the Restart Manager prompt leaves the prior version installed and connected, and accepting closes it cleanly before install; on Linux, the running pair keeps working, and killing its helper produces the "updated; restart it" message. Repeat uninstall with an active connection: on Windows, declining leaves the client installed and connected and accepting closes it cleanly first; on Linux the running client keeps working, killing its helper shows the "removed; quit it" message, and after the user quits no owned process or file remains. Force an install failure during unpacking for each format and verify the previous version remains installed and runs with its state intact. Inspect the `.rpm` and `.deb` and verify every post-unpack maintainer script action is non-fatal. Record exact OS/CPU/desktop and artifact hash. |
| AC-22 | First record the comparison hosts and then the current macOS release baseline in this document under the recorded workload. Then, on each matrix target, measure startup-to-ready, settled idle RSS/CPU, UI-command response and cold/warm connection timings under the same workload with the process set, runs, median and sampling defined in Design. Pass when every metric is at most 1.10 times the baseline for the refactored macOS app on the baseline Mac and at most 1.5 times for Windows and Linux on their recorded hosts. |
| AC-23 | Native Windows/Linux feasibility records must include exact Swift/SDK/plugin versions, interactive SSO plus refresh, AWS response, usable SSM traffic, cancellation and owned-process cleanup. Later full native acceptance must use the final UI/core integration. |
| AC-24 | Rebuild through each actual release path; inspect the unpacked final artifact for selected core/helper/runtime assets, executable permissions or signatures as applicable, and licenses. Check that the WinGet manifest's SHA-256 matches the released MSI. Verify one platform's release does not require publishing another's. |
| AC-25 | With fake ports recording every call, run each action with each required capability reported missing (Session Manager plugin for every action, OpenSSH and VS Code for editor actions, browser for managed browsing); assert the refusal names that capability and zero AWS calls, process launches and configuration writes were recorded. With DCV Viewer reported missing, a desktop connection keeps its tunnel up with the current warning, as `ConnectionStateMachineTests` requires today. Repeat natively on each matrix target with one capability removed, with every outbound connection from the client's process tree blocked and logged at the operating system (a network namespace whose only route is a logging proxy on Linux, an audited outbound firewall rule on Windows): no connection attempt is logged, no child process starts and no configuration file changes. A positive control build that sends the direct STS identity request (`STSIdentityResolver`) before refusing must make this check fail. |
| AC-26 | In an isolated macOS user account with representative profiles, attachments, editor recovery intent and integration metadata written by the current release: install the refactored build and verify identity, consent, restore and conflict behavior; then have it create or update state through every persisted-state writer: profiles, attachments, portable documents and settings (`ProfileStore`), editor recovery intent (`EditorRecoveryStore`), and browser routing and ownership records (`BrowserBootstrap`). Reinstall the current release and verify it reads each resulting artifact with the same identities, consent, conflict and restore behavior. |
| AC-27 | Helper protocol tests with fake ports: two concurrent commands each get one terminal result; a command conflicting with current state is refused before any recorded side effect; cancelling one workflow leaves a second running. Native tests on each Windows/Linux target: no named pipe or socket exists for the helper; a second launch focuses the first shell and starts no second helper; killing the shell ends the helper and all its descendants; killing only the helper during an established transport, with the shell running, ends every descendant before the replacement helper starts; killing the helper mid-StartSession fails that command with "core stopped", one replacement starts, and exactly one StartSession was recorded. A helper from a different build is refused at handshake. A replacement that exits at once, never completes its handshake, or stops answering heartbeats leads, within the stated limits, to "SSM Connect core unavailable" with Retry and no further automatic restart; a first helper that never handshakes leads there without any automatic restart; after ten healthy minutes one automatic restart is available again; a pending command whose cancel is not confirmed within 10 seconds leads to helper replacement. |

## Tasks

None yet. After a clean independent review and owner acceptance, generate
one-commit tasks through vh-adlc. The first are the macOS performance baseline
and the Windows/Linux helper and dependency increment. The branch preparation
and historical snapshot are not implementation tasks or evidence that the
criteria above are met.

## Open Questions

### Q20: What does a failed Linux package install promise?

**Recommendation:** A. RPM replaces files one at a time after unpacking and does
not restore them when a later step fails (R-6 F-01), so "the previous version
stays installed" would need recovery machinery the project would own. Using the
package manager's normal repair removes that promise instead.

| Option | You get | It costs |
| --- | --- | --- |
| **A. Repair with the package manager** | A failed MSI still rolls back. A failed `.rpm` or `.deb` install is repaired by installing the package again with dnf or apt, which the error output and install guide say. Profiles and other state live outside the package and are untouched either way. | After a rare failed Linux upgrade the app may not start until the user reruns the install. |
| **B. Guarantee the previous version** | A failed Linux upgrade always leaves a working app. | A project-owned backup and restore step around every install, with tests for failure after each file is replaced. |

**Why this is yours:** It decides what an install failure promises Linux users.
R-6 F-01 raised it.

## Review Log

| Date | Review | Kind | Commit | Model | Isolation | Outcome |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-11-17 | R-1 | spec | `c2507b1` | gpt-6.1-sol | procedural | No blocking findings; four should-fix and one nit |
| 2026-11-17 | R-2 | spec | `3040421` | gpt-6.1-sol | procedural | No blocking findings; six should-fix |
| 2026-11-17 | R-3 | spec | `4c4051c` | gpt-6.1-sol | procedural | One blocking (missing-Viewer conflict) and four should-fix |
| 2026-11-17 | R-4 | spec | `70c8856` | gpt-6.1-sol | procedural | One blocking (Windows job cleanup on helper exit) and four should-fix |
| 2026-11-17 | R-5 | spec | `4c1906f` | gpt-6.1-sol | procedural | No blocking findings; three should-fix and one nit |
| 2026-11-17 | R-6 | spec | `828865e` | gpt-6.1-sol | procedural | One blocking (rpm/deb failure recovery overstated) and one nit |

### R-1

FINDING: F-01
KIND: judgement
SEVERITY: should-fix
WHERE: Design / One implementation, several shells; Design / Integration and feasibility; Design / Behavior, identity and local state; Acceptance Criteria / AC-11, AC-15, AC-18; Test Plan / AC-11, AC-15, AC-18, AC-23; Open Questions / Q1
EVIDENCE: The new bridge promises ordered events, cancellation and shutdown, but defines no outcome for concurrent commands, late completion after cancellation, or retry after an uncertain result. For the helper option, an SSM session could start before the reply is lost; replay could then create another session. Existing authorization code rejects stale completions using a generation counter at SSMConnectKit/Sources/SSMConnectKit/Auth/AuthorizationSession.swift:197-226, but the document does not extend that protection across the new boundary. Q1 chooses the integration mechanism without deciding these semantics.
PROPOSAL: Extend Q1 with the command correlation, cancellation and recovery policy for the selected bridge, including replay and obsolete-session rejection where applicable. Add tests for concurrent commands, lost replies and late completions with explicit expected effects.

FINDING: F-02
KIND: factual
SEVERITY: should-fix
WHERE: Scope / profile compatibility and recovery; Design / Behavior, identity and local state; Design / Migration, performance and release boundaries; Acceptance Criteria / AC-14, AC-16, AC-17, AC-20; Test Plan / AC-14, AC-16, AC-17, AC-20, AC-21
EVIDENCE: Design requires preserving profiles and local integration metadata with a working macOS rollback point. AC-14 tests portable fixtures and current stores; AC-20 tests the current suite and native flows; the only explicit upgrade test, AC-21, covers Windows/Linux candidates. None establishes macOS persisted-state compatibility through upgrade and rollback. Existing state includes separate profile, attachment and document keys at SSMConnectKit/Sources/SSMConnectKit/Services/ProfileStore.swift:21-25 and versioned editor recovery intent at Services/EditorRecoveryStore.swift:35-39. Portable-profile round trips do not establish compatibility for those stores.
PROPOSAL: Add an isolated previous-release to refactored-release to recorded-rollback scenario using representative persisted profiles, attachments and integration metadata. State the expected identity, consent, restore and conflict behavior at each step.

FINDING: F-03
KIND: factual
SEVERITY: should-fix
WHERE: Design / Behavior, identity and local state, unsupported-capability refusal; Acceptance Criteria / AC-12, AC-13, AC-16, AC-17, AC-21, AC-23; Test Plan / corresponding rows
EVIDENCE: Design requires unsupported required capabilities to refuse before AWS or local setup effects and prohibits silently changing connection mode. No criterion explicitly establishes this cross-platform preflight invariant. AC-13 checks unwanted DCV operations during working headless flows, while AC-16 checks policy and ownership refusal without asserting that AWS calls, process launches and configuration writes remained absent. A client could start EC2 or write integration state before reporting an unsupported adapter and still satisfy those checks.
PROPOSAL: Add a criterion and negative native scenarios for unavailable or unsupported required capabilities. Assert actionable refusal, unchanged connection mode and zero AWS or local setup effects before refusal.

FINDING: F-04
KIND: judgement
SEVERITY: should-fix
WHERE: Context / Owner summary, retained Windows installer work; Scope / independently releasable artifacts; Design / Preservation and selective reuse, packaging row; Design / Migration, performance and release boundaries; Acceptance Criteria / AC-21, AC-24; Test Plan / AC-21, AC-24; Open Questions / Q2
EVIDENCE: Windows/Linux delivery is described only as needing native build/test/package paths. Artifact formats, installation scope, signing requirements and publication channels remain unspecified, and Q2 asks about OS/CPU/desktop coverage. The cited two-core predecessor at 2aa079d explicitly required a signed Windows installer and WinGet publication; this revision removes those requirements without identifying their replacement as an owner decision. The pinned conventions/delivery.md / Feature delivery requires naming affected artifacts and their build and publication paths.
PROPOSAL: Raise an owner question covering Windows/Linux packaging and distribution, explicitly deciding whether the earlier Windows delivery requirements remain. Fold the answers into named artifacts, build/publication paths and installation checks before acceptance.

FINDING: F-05
KIND: factual
SEVERITY: nit
WHERE: Design / Integration and feasibility, credential-free spike description
EVIDENCE: The document says the spike exercises the helper over private stdin/stdout pipes. spikes/swift-portability/run.sh:29-31 instead redirects stdin from requests.jsonl and stdout/stderr into regular files. The observed check establishes batch command processing rather than interactive pipe behavior.
PROPOSAL: Describe the spike as using redirected stdin/stdout files. Retain its existing limitation that production IPC remains unverified.

### R-2

FINDING: F-01
KIND: judgement
SEVERITY: should-fix
WHERE: Design / Integration and feasibility, command-delivery rules; Design / Behavior, identity and local state, independent actions and stable identities; Acceptance Criteria / AC-13, AC-15, AC-27; Test Plan / AC-13, AC-15, AC-27
EVIDENCE: Lines 255-263 attach a generation to commands but specify rejection only when a completion arrives. They do not define admission of an already obsolete command, generation changes during an outstanding AWS operation, or whether generations belong to individual workflows or the whole helper. An obsolete queued command could start an SSM session before its completion is discarded. Conversely, one global cancellation generation could invalidate an independent healthy workflow. The AC-27 proof checks discarded completions without checking obsolete commands before their effects. These gaps remain in the command-delivery rules addressing R-1 F-01.
PROPOSAL: Define generation scope, invalidation triggers, rejection before side effects and cleanup of effects already underway. Add scenarios for an obsolete queued command and cancellation of one workflow while another remains active; raise unresolved policy choices as Open Questions.

FINDING: F-02
KIND: judgement
SEVERITY: should-fix
WHERE: Context / Owner summary, lost-reply recovery; Design / Integration and feasibility, terminal results, reconnection and helper crashes; Acceptance Criteria / AC-18, AC-27; Test Plan / AC-18, AC-27; Sources / Q6
EVIDENCE: Lines 255-269 require exactly one terminal result per command, prohibit replay and recover lost replies through a state snapshot. They do not say whether snapshots retain command IDs and pending outcomes, who resolves a command when its helper dies, or what happens when AWS accepted an operation whose response was never received. A snapshot taken while StartSession is still pending cannot establish its final outcome. The AC-27 dropped-reply scenario checks the StartSession count but does not establish a terminal result for that command. This affects the new recovery policy addressing R-1 F-01.
PROPOSAL: Define how pending and uncertain outcomes appear after reconnection or helper replacement, including terminal-result ownership and treatment of later replies. Test a dropped reply before completion and a crash after AWS accepts an operation but before its response reaches the helper.

FINDING: F-03
KIND: judgement
SEVERITY: should-fix
WHERE: Design / Integration and feasibility, endpoint/process ownership, version negotiation and crash cleanup; Design / Migration, performance and release boundaries; Acceptance Criteria / AC-18, AC-21, AC-24, AC-27; Test Plan / AC-18, AC-21, AC-24, AC-27
EVIDENCE: Lines 248-249 say the protocol defines ownership and version negotiation, but give no behavior for simultaneous shell launches, a shell crash while its helper survives, or an upgrade encountering an older live helper. The user SID ACL and socket-directory permissions restrict access but do not select the legitimate helper or prevent competing helpers. The tests cover killing a helper and upgrading packages separately, without checking these ownership and mixed-version cases. Implementers could choose materially different behavior, including duplicate active cores or replacement of a helper still serving another shell.
PROPOSAL: Decide helper instance scope, concurrent-start arbitration, shell-loss behavior and incompatible-version handling during upgrade or rollback. Add native scenarios proving those decisions without taking over another live owner's processes or endpoint.

FINDING: F-04
KIND: judgement
SEVERITY: should-fix
WHERE: Context / Owner summary, performance budgets; Design / Migration, performance and release boundaries, baseline measurement; Acceptance Criteria / AC-22; Test Plan / AC-22; Tasks / first performance-baseline task; Sources / Q4
EVIDENCE: Lines 374-379 and the AC-22 row specify ratios and repeated measurements, but leave process accounting, measurement intervals and the statistic used for comparison undefined. Windows and Linux divide the client between a shell and a Swift helper, while macOS runs the core in-process. Measuring only shell RSS or CPU could satisfy the budget while excluding most core resource use. Different sample summaries and hardware selections could also produce different verdicts under the same stated workload.
PROPOSAL: Retain the accepted ratios and define the measured process set, hardware conditions, readiness boundaries, sampling intervals, repetition count and comparison statistic before collecting the baseline. Apply the same accounting to every client and record these conditions with the results.

FINDING: F-05
KIND: judgement
SEVERITY: should-fix
WHERE: Context / Owner summary, same application on each platform; Scope / retained macOS behavior and Windows/Linux interfaces; Design / Behavior, identity and local state, browser preservation and unavailable capabilities; Acceptance Criteria / AC-16, AC-23, AC-25; Test Plan / AC-16, AC-23, AC-25
EVIDENCE: The desktop matrix is explicit, but the required Windows/Linux browser product-by-mode matrix is not. AC-16 tests only combinations declared supported, while AC-25 permits refusal of unavailable capabilities. Consequently, those proofs do not distinguish a missing browser installation from an omitted browser adapter. The current implementation explicitly supports Chrome Separate Browser and both Zen modes at Services/BrowserBootstrap.swift:33-38; browser-bootstrap.spec.md:334-338 records that matrix. Two implementers could preserve different subsets on the new platforms and both run every declared combination.
PROPOSAL: Specify the minimum browser modes and products required on each new platform, with a version-selection rule and native proof for each required combination. Keep prerequisite refusal distinct from a scope decision to omit a required integration.

FINDING: F-06
KIND: factual
SEVERITY: should-fix
WHERE: Scope / macOS upgrade and rollback; Design / Migration, performance and release boundaries, persisted-state compatibility; Acceptance Criteria / AC-26; Test Plan / AC-26
EVIDENCE: AC-26 covers profiles, attachments, editor recovery intent and integration metadata through rollback. Its new proof addressing R-1 F-02 seeds all these from the old release but requires only one unspecified change before reinstalling it. That can verify old-state reading while leaving refactored writers untested. Editor recovery has its own writer at Services/EditorRecoveryStore.swift:50-59 and 74-77; browser routing and ownership records are written separately at Services/BrowserBootstrap.swift:230-256. An incompatible writer in either path could escape a scenario whose one change updates a profile.
PROPOSAL: Require the refactored build to create or update representative state through every persisted-state writer covered by AC-26 before rollback. Verify that the previous release can consume each resulting artifact with the required identity, consent, conflict and restore behavior.

### R-3

FINDING: F-01
KIND: judgement
SEVERITY: blocking
WHERE: Context / Owner summary and Existing workflow and baseline; Scope / preserved macOS behavior; Design / Behavior, identity and local state, capability preflight; Acceptance Criteria / AC-20, AC-25; Test Plan / AC-20, AC-25
EVIDENCE: AGENTS.md:27-28 requires preserving existing macOS behavior. ConnectionStateMachine.swift:489-502 treats missing DCV Viewer as a warning after establishing the tunnel. ConnectionStateMachineTests.swift:342-352 explicitly requires that connection to remain connected, and ssm-connect.spec.md:335 documents the same behavior. AC-25 and its proof instead require refusal before any AWS call when DCV Viewer is missing. Preserving the current suite under AC-20 and applying AC-25 to that case require incompatible outcomes.
PROPOSAL: Distinguish required capabilities from optional integrations so the preflight rule preserves the existing missing-Viewer behavior. If changing that behavior is intended, raise an owner Open Question covering the behavioral change and the conflicting repository instruction before revising either.

FINDING: F-02
KIND: judgement
SEVERITY: should-fix
WHERE: Context / Owner summary, helper recovery; Design / Integration and feasibility, command-delivery rules; Acceptance Criteria / AC-18, AC-27; Test Plan / AC-18, AC-27; Sources / Q6, Q8
EVIDENCE: The revision addressing R-2 F-02 replaces snapshot recovery with a fresh helper that reaps leftover SSM sessions. It still gives no recovery path when AWS accepts StartSession but the helper dies before receiving its response. SSMService.swift:60-84 obtains the session ID only from that response; SSMClients.swift:7-10 exposes no session reconciliation or termination operation. ConnectionStateMachine.swift:728-735 only terminates a known local handle. The cited macOS behavior therefore supplies no recovery mechanism for this case. AWS also requires a session ID for [TerminateSession](https://docs.aws.amazon.com/systems-manager/latest/APIReference/API_TerminateSession.html).
PROPOSAL: Raise the uncertain-session recovery policy as an Open Question, including ownership identification, required permissions and cleanup failure. Define and test recovery after AWS acceptance but before receipt of the session ID, without replaying StartSession or affecting another live client's sessions.

FINDING: F-03
KIND: judgement
SEVERITY: should-fix
WHERE: Context / Owner summary, helper lifetime; Design / Integration and feasibility, process containment and startup cleanup; Acceptance Criteria / AC-18, AC-27; Test Plan / AC-18, AC-27; Sources / Q8
EVIDENCE: The R-2 revision specifies a Linux parent-death signal for ending the helper with its shell. That does not contain the helper's descendants. An isolated native prctl check in this review reported signal 15 in the helper and 0 in its forked descendant, matching the [Linux manual](https://man7.org/linux/man-pages/man2/PR_SET_PDEATHSIG.2const.html). If the shell is killed, both shell and helper can disappear while an owned plugin or SSH process survives. Startup cleanup cannot resolve that path until another launch, and the document defines no containment mechanism that remains effective without a restart.
PROPOSAL: Define Linux containment for owned descendants when the shell and helper cannot execute cleanup. Add a native scenario that kills the shell during active transport, starts no replacement client, and verifies that unintended owned descendants terminate while unrelated processes remain untouched.

FINDING: F-04
KIND: judgement
SEVERITY: should-fix
WHERE: Context / Owner summary, helper failure recovery; Design / Integration and feasibility, handshake and command-delivery rules; Acceptance Criteria / AC-27; Test Plan / AC-27
EVIDENCE: The R-2 revision requires starting a fresh helper whenever the helper exits, but defines no outcome when the replacement repeatedly exits, refuses its handshake or remains alive without completing the handshake or an admitted command. An implementation could restart indefinitely; another could stop after one failure; another could leave commands pending indefinitely. AC-27 tests one successful replacement and a mismatched-build refusal, without establishing the resulting shell state or bounding recovery.
PROPOSAL: Decide bounded restart and unresponsive-helper behavior, including the visible failure state and how the user retries. Add scenarios for repeated startup failure, handshake timeout and a stalled admitted command, preserving the no-replay rule.

FINDING: F-05
KIND: judgement
SEVERITY: should-fix
WHERE: Context / Owner summary, performance budgets; Design / Migration, performance and release boundaries, measurement procedure; Acceptance Criteria / AC-22; Test Plan / AC-22; Tasks / performance baseline; Sources / Q4, Q9
EVIDENCE: The revision addressing R-2 F-04 defines process accounting, sampling and timing statistics, but only requires recording hardware and OS build with each result. It does not require baseline and refactored macOS measurements on the same host or fix the Windows/Linux comparison hosts before measurement. A slower implementation measured on faster hardware could pass the ratios, while the same implementation on another permitted host could fail. Recording the difference afterwards does not make those verdicts comparable.
PROPOSAL: Retain the accepted ratios and establish comparison conditions before collecting the baseline, including the same macOS host and fixed native comparison hosts, power settings and workload conditions. Record those conditions with the results and require a new baseline when they change.

### R-4

FINDING: F-01
KIND: factual
SEVERITY: blocking
WHERE: Context / Owner summary, helper recovery; Design / Integration and feasibility, Windows process containment and command-delivery rules; Acceptance Criteria / AC-18, AC-27; Test Plan / AC-18, AC-27
EVIDENCE: Design specifies a Windows job that terminates its processes when the shell's handle closes, then says the job has already ended the old helper's processes when that helper exits. These are different events: the shell survives helper failure and still holds its handle. Microsoft's [Job Objects documentation](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects) establishes that kill-on-close acts when the last job handle closes; helper termination alone does not trigger it. An active plugin or SSH descendant can therefore survive the stated recovery sequence. The AC-27 helper-kill scenario occurs mid-StartSession and does not require an existing descendant.
PROPOSAL: Specify explicit termination and verified cleanup of the old Windows job before starting its replacement. Add a native scenario that kills the helper during an established transport while the shell remains running, and verifies descendant termination before replacement begins.

FINDING: F-02
KIND: judgement
SEVERITY: should-fix
WHERE: Context / Owner summary, helper recovery; Design / Integration and feasibility, handshake and command-delivery rules; Acceptance Criteria / AC-27; Test Plan / AC-27; Sources / Q14
EVIDENCE: The revised rules addressing R-3 F-04 apply the 10-second handshake deadline and heartbeat failure handling only to a replacement. They leave an initial helper that never handshakes or stops responding without a defined transition. A helper that continues heartbeats while an admitted command stalls also escapes those checks. The claimed existing AWS stage-timeout protection does not establish that bound: ConnectionStateMachine.swift:419-427 awaits StartSession before entering the timeout at line 430, and withReauth at lines 680-710 adds no operation deadline. The restart budget is also unclear after a replacement survives 60 seconds: the general exit rule starts a replacement, while Q14 says one automatic restart, then an error.
PROPOSAL: Raise the remaining recovery choices as an Open Question covering initial startup, stalled commands and when the restart allowance resets. Define observable deadlines and terminal outcomes, and test these cases while preserving the no-replay rule.

FINDING: F-03
KIND: judgement
SEVERITY: should-fix
WHERE: Design / One implementation, several shells, lease ownership; Design / Integration and feasibility, separate SSH proxy and helper replacement; Design / Behavior, identity and local state, editor recovery and stable identities; Acceptance Criteria / AC-17, AC-18, AC-27; Test Plan / AC-17, AC-18, AC-27
EVIDENCE: The SSH proxy is explicitly outside the shell-helper pipe connection. RemoteSSHBridge.swift:115 makes it a ProxyCommand launched through the editor's SSH connection; lines 127-185 show that it independently authorizes and starts its plugin. Its lifetime depends on the lease's owner identity and generation at lines 40-63 and 188-203. Current leases use the app identity, supplied by RemoteDevelopmentStateMachine.swift:62-65 and written at lines 318-321. The new design does not decide whether Windows/Linux leases belong to the surviving shell or the replaceable helper. Helper containment therefore does not establish what happens to these external channels or their reusable leases when only the helper dies.
PROPOSAL: Decide lease ownership, invalidation and recovery across helper replacement, including treatment of existing editor channels and stale lease files. Add native helper-failure scenarios during active editor use that verify the chosen access policy and preserve unsaved windows.

FINDING: F-04
KIND: judgement
SEVERITY: should-fix
WHERE: Scope / compatibility and independently releasable artifacts; Design / Integration and feasibility, single-instance behavior and build handshake; Design / Migration, performance and release boundaries; Acceptance Criteria / AC-21, AC-24, AC-26, AC-27; Test Plan / AC-21, AC-24, AC-26, AC-27
EVIDENCE: Design requires a second launch to focus the running shell and requires matching shell/helper builds, but does not define installation, upgrade, rollback or uninstall while that shell and its helper remain active. The package checks do not require an active prior instance, and the mismatched-helper check does not cover replacing package files beneath a running pair. Deferring installation, preserving the old pair until exit and stopping it before replacement produce different connection and editor behavior. R-2 F-03 already requested the active upgrade case; private helpers and handshake rejection do not settle it.
PROPOSAL: Raise the live installation policy as an Open Question, including user consent for interruption and behavior after partial installation failure. Add native upgrade and rollback scenarios with an active prior shell/helper pair and verify the selected version, process ownership and connection outcome.

FINDING: F-05
KIND: factual
SEVERITY: should-fix
WHERE: Design / Behavior, identity and local state, capability preflight; Acceptance Criteria / AC-25; Test Plan / AC-25
EVIDENCE: The native AC-25 proof treats an empty recording endpoint under AWS_ENDPOINT_URL as evidence of zero AWS calls. That override does not cover every existing AWS request path. STSPresigner.swift:16 and 71 constructs a regional sts.amazonaws.com URL directly, and STSIdentityResolver.swift:15-25 and 42-46 sends it through URLSession without consulting the override. A native action that performs this request before refusing a missing capability can leave the recording endpoint empty. The fake-port check does not establish that the native composition uses only the observed transports.
PROPOSAL: Observe outbound request attempts across all native HTTP paths and owned processes, or explicitly route every such path through the recording transport. Include a positive control demonstrating that a direct STS request before refusal makes the native proof fail.

### R-5

FINDING: F-01
KIND: factual
SEVERITY: should-fix
WHERE: Design / Migration, performance and release boundaries, lines 455-462; Acceptance Criteria / AC-21; Test Plan / AC-21
EVIDENCE: The revision addressing R-4 F-04 promises that a failed rpm or deb transaction leaves the previous version installed. The selected apt installation path does not supply that guarantee: [Debian Policy, section 6.7](https://www.debian.org/doc/debian-policy/ch-maintainerscripts.html#details-of-configuration) specifies that configuration failures leave the new package Half-Configured without unwinding. No additional recovery mechanism is defined. Forcing only one unspecified failure per format can pass through a pre-unpack failure while missing this case.
PROPOSAL: Define recovery for failures before and after package replacement, with an owner question if automatic rollback is being replaced by explicit repair. Test a failure after unpacking and verify the selected package, application and persisted-state outcomes.

FINDING: F-02
KIND: factual
SEVERITY: should-fix
WHERE: Context / Owner summary, live installation policy; Design / Migration, performance and release boundaries, lines 455-461; Acceptance Criteria / AC-21; Test Plan / AC-21; Sources / Q18
EVIDENCE: Design applies its non-interruption guarantee to installing, upgrading and removing a running client. AC-21 likewise includes a running prior version. Its proof tests active upgrades but performs uninstall only in the earlier ordinary package sequence. An uninstaller that terminates an active client without consent could pass every specified scenario. The changes addressing R-4 F-04 therefore leave active removal unverified.
PROPOSAL: Add native uninstall scenarios with an active connection, including refusal of interruption and the selected Linux behavior while files are removed or retained. Verify process ownership, connection continuity and cleanup after the user finally quits.

FINDING: F-03
KIND: judgement
SEVERITY: should-fix
WHERE: Context / Owner summary, helper lifetime; Design / Integration and feasibility, lines 245-256 and 282-292; Acceptance Criteria / AC-18, AC-27; Test Plan / AC-18, AC-27; Sources / Q13, Q16
EVIDENCE: Linux cleanup depends on the helper reading stdin closure and exiting, or on the surviving shell stopping its unit. Neither path works when the helper is unresponsive and the shell then crashes. A transient service has the service manager as its parent, and its default lifetime follows its main process, as documented by [systemd-run](https://www.freedesktop.org/software/systemd/man/latest/systemd-run.html#Description) and [systemd.service](https://www.freedesktop.org/software/systemd/man/latest/systemd.service.html#ExitType=). Closing the shell's pipe does not itself stop that unit. The helper and active descendants can therefore survive without either specified cleanup actor.
PROPOSAL: Define supervision that ends the Linux unit even when the helper cannot process EOF and the shell is gone. Add a native scenario that suspends the helper, kills the shell, starts no replacement and verifies bounded cleanup of owned processes.

FINDING: F-04
KIND: factual
SEVERITY: nit
WHERE: Design / Integration and feasibility, cancellation rules at lines 270-299; Design / Behavior, identity and local state, independent actions; Test Plan / AC-27; Sources / Q16
EVIDENCE: The command rules say cancelling one workflow never affects another. The new cancellation deadline addressing R-4 F-02 instead terminates the entire helper after an unconfirmed cancel, ending its other transports and editor leases. The escalation behavior is already specified, but the unconditional isolation wording overstates it.
PROPOSAL: Qualify workflow isolation as applying to cooperative cancellation and state that timeout escalation ends every workflow owned by that helper.

### R-6

FINDING: F-01
KIND: factual
SEVERITY: blocking
WHERE: Design / Migration, performance and release boundaries, lines 471-475; Acceptance Criteria / AC-21; Test Plan / AC-21, line 511
EVIDENCE: The revision addressing R-5 F-01 assumes that non-fatal maintainer scripts restrict failures to unpacking, which package managers undo. RPM has a separate file-commit phase after unpacking: [lib/fsm.cc:1061-1101](https://github.com/rpm-software-management/rpm/blob/rpm-6.0.0-release/lib/fsm.cc#L1061-L1101) replaces destinations sequentially and handles failure without restoring the previous payload. A later rename failure can therefore leave previously replaced application files missing. The specified unpacking failure test does not establish the promised previous-version recovery.
PROPOSAL: Define recovery after partial file replacement and test failure after at least one destination has been replaced. Raise an owner Open Question if satisfying that guarantee requires an additional recovery mechanism or replacing it with explicit repair.

FINDING: F-02
KIND: factual
SEVERITY: nit
WHERE: Context / Owner summary, lines 52-53; Design / Migration, performance and release boundaries, lines 460-469; Acceptance Criteria / AC-21; Test Plan / AC-21; Sources / Q18
EVIDENCE: The summary says Linux installation and removal wait for the user to quit. Design and AC-21's proof instead allow package changes while the client remains running, with specific errors if its helper subsequently needs replacement. The detailed behavior is defined; the summary describes a different timing policy.
PROPOSAL: Say that Linux leaves the running client active during upgrade or removal until the user quits, and mention the restart or quit requirement if its helper is lost.

## Sources

- Owner direction on 2026-11-12: preserve working Swift, share its core across
  macOS/Windows/Linux, permit component redesign, adopt vh-adlc and prepare a
  clean consolidation branch before implementation.
- Owner decisions on 2026-11-17 in session: a bundled helper (Q1); the
  matrix of Windows 11 x64, Fedora 43 x86-64 KDE Plasma 6 and Ubuntu 24.04 LTS
  x86-64 (Q2); a Qt 6 Linux shell (Q3); baseline-relative budgets of 1.10 and 1.5
  times (Q4); an upstream SDK/CRT fix first (Q5); no automatic replay (Q6); an
  unsigned per-user MSI through WinGet, `.rpm` and `.deb` on the GitHub Release,
  with SignPath signing and pkg.vhco.pro repositories as later features (Q7);
  a private child helper per shell over pipes (Q8); app-process measurement by
  median of ten runs (Q9); the macOS browser matrix on every platform (Q10);
  refusal only without a hard requirement, with the DCV desktop optional and
  editor, web forwards and tunnels primary on targets without a GUI (Q11);
  orphaned SSM sessions left to the idle timeout (Q12); a transient systemd user
  service on Linux (Q13); one automatic restart, then a visible error (Q14); fixed
  named comparison hosts (Q15); the same failure rules for every helper with
  Cancel bounding a stall (Q16); helper-owned editor leases (Q17); asking before
  closing on Windows and running until quit on Linux during installs (Q18); the
Linux helper unit bound to the shell's systemd scope (Q19).
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
- [Pinned aws-crt-swift manifest](https://github.com/awslabs/aws-crt-swift/blob/d1678252cb3da2d34f70db43e402927360df4d8c/Package.swift):
  its Windows `aws-c-io` exclusions omit `source/bsd`, consistent with the native
  backend's observed attempt to compile the BSD kqueue source on Windows.
- [Feature-document conventions](https://github.com/vhco-pro/docs/blob/0c983f6793bfe35eb96ae95ad0c361c6200af44f/conventions/feature-documents.md)
  and [prose guide](https://github.com/vhco-pro/docs/blob/0c983f6793bfe35eb96ae95ad0c361c6200af44f/guides/humanize-prose.md):
  the pinned format and authoring rules for this revision.
