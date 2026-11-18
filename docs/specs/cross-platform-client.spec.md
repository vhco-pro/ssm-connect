---
status: draft
status_description: "Revised after T3 for one SSM Connect AWS client on every platform; spec review R-20 is clean. Awaiting owner re-acceptance."
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
helper stops, its processes and editor channels end with it and in-flight
actions fail. The app starts at most one automatic replacement, and none when
the first helper fails at startup; otherwise it shows an error with Retry.
Installing over or removing a running app asks first on Windows. On Linux the
running app keeps its established connections and never starts a file from a
different build, apart from a plugin swapped in the instant between its check
and its start: an action, including a new editor channel from an open VS Code
window, whose files were replaced or removed is refused with a request to
restart or quit. A failed Linux install is repaired by
installing again. Browser support
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

AWS's Swift SDK and its C runtime do not support Windows, and AWS treats
Windows as a backlog feature request. The core therefore reaches AWS through
its own small client on every platform, for the 12 AWS requests it makes: 11
through the SDK today and its direct STS identity request. The app already runs
SSO and its credential cache itself and passes the SDK fixed credentials, so the
SDK only signs, sends and parses those calls. The client retries with one fixed
policy equal to the SDK's defaults and always uses the regional endpoint; AWS
retry settings and configured endpoints no longer affect SSM Connect, and the
STS identity request reaches the correct host in China regions. With the shared
preflight that refuses an action missing a hard requirement before any AWS call,
these are the four named exceptions to preserving macOS behavior. The client is
proven on Linux and Windows first; macOS switches to it last, once its full
suite and native flows pass, and the SDK and its C runtime then leave every
build. Native spikes execute unchanged Swift model/parser code and a small
helper on Windows and Linux. Full workflows, authentication, transports and
native adapters are unverified, and no criterion is met by these subset checks.

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
dependency build, and no newer release does either. aws-crt-swift v0.64.3, the
latest, still compiles `aws-c-io/source/bsd` on Windows; AWS states on
[aws-crt-swift#289](https://github.com/awslabs/aws-crt-swift/issues/289) that
neither aws-crt-swift nor aws-sdk-swift supports Windows; and the one community
attempt, [aws-crt-swift#290](https://github.com/awslabs/aws-crt-swift/pull/290),
closed in 2024. The SDK signs and sends through those C libraries, so upstream
Windows support means porting several of them. The app uses 11 SDK operations
and passes the SDK static credentials it obtained itself
(`SSMConnectKit/Sources/SSMConnectKit/Services/SSMClients.swift:20-30`), and it
already signs its STS identity request without the SDK (`STSPresigner`).

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
- AWS operations beyond those the app uses today, a fork of aws-sdk-swift or
  aws-crt-swift, or contributing Windows support to them.
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
| `SSMConnectAWS` | The SSM Connect AWS client below: signing, the operations the app uses, retries and error translation. |
| Platform adapters | Native files, process containment, browser/editor integration, clipboard, notifications and startup. |
| UI/composition | Native presentation, user consent, event observation and dependency assembly. |

Names may be adjusted when tasks are written. Preserve compatibility through
the existing umbrella where needed; do not make current macOS callers migrate
unnecessarily. Domain/workflow boundaries must not import AppKit, SwiftUI,
Darwin, ServiceManagement, UserNotifications or expose AWS client or native UI types.
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
reports no remaining processes before it starts any replacement.

Only access channels live in that container: the Session Manager plugin, SSH
tunnels and other processes that carry a connection. Applications that hold the
user's work, VS Code, DCV Viewer and browsers, are never started inside it,
because Windows job membership and a systemd unit are inherited by every child,
including the app the `code` CLI hands off to
(`SSMConnectKit/Sources/SSMConnectKit/StateMachine/RemoteDevelopmentStateMachine.swift:637-643`).
The helper asks its shell to start them instead: on Windows the shell starts them
from its own process, which is outside every job; on Linux it starts each in its
own transient systemd user scope. They therefore survive a helper or shell
failure, as they survive an app crash on macOS today, while the channels they use
end with the helper. The shell is single-instance
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
  The proxy and the plugin it starts run under VS Code's SSH, outside the
  helper's container, as on macOS today; they end when the lease owner is gone
  or VS Code closes the SSH connection. A proxy that is itself suspended is
  outside this cleanup guarantee, as on macOS today.
- An AWS call whose response never arrives is handled inside the core exactly as
  the in-process macOS app handles it today. The client
  has no server-side session cleanup today
  (`SSMConnectKit/Sources/SSMConnectKit/Services/SSMClients.swift:7-10`) and gains
  none: an SSM session AWS started before a helper stop, whose ID the client never
  received, ends at the account's Session Manager idle timeout.

### AWS client

The core reaches AWS through one SSM Connect AWS client on every platform,
written in Swift on Foundation's `URLSession` (FoundationNetworking on Linux and
Windows) and an XML parser for EC2 and STS responses. It implements exactly the
AWS requests the app makes today, including the STS identity request that
currently bypasses the SDK
(`SSMConnectKit/Sources/SSMConnectKit/Auth/STSIdentityResolver.swift:16-25`):

| Service | Operations | Protocol |
| --- | --- | --- |
| SSO OIDC | RegisterClient, StartDeviceAuthorization, CreateToken | REST JSON, unsigned |
| SSO | GetRoleCredentials | REST JSON, SSO bearer token |
| EC2 | DescribeInstances, StartInstances, StopInstances | EC2 Query, Signature Version 4 |
| Systems Manager | DescribeInstanceInformation, StartSession | AWS JSON 1.1, Signature Version 4 |
| Secrets Manager | GetSecretValue | AWS JSON 1.1, Signature Version 4 |
| EC2 Instance Connect | SendSSHPublicKey | AWS JSON 1.1, Signature Version 4 |
| STS | GetCallerIdentity, sent directly and as the presigned token the agent receives | AWS Query, Signature Version 4 |

It reproduces what the current SDK configuration does for these calls: the
production endpoint the SDK's resolver selects for each region and partition
(standard, China and GovCloud), ignoring configured endpoint settings
(`AWS_ENDPOINT_URL` and its service-specific forms, shared-config endpoints and
the ignore flag); the SDK's retry behavior with nothing configured,
which becomes the client's one fixed policy (attempts, backoff, retryable errors
and retry-after handling), so retry environment variables and shared-config retry
settings no longer affect SSM Connect; and the error results the app's existing
translation receives, so the typed errors and messages users see stay the same.
The STS identity request keeps its current single attempt inside the client:
it is never retried and fails on any non-success response, as today's direct
path does (`SSMConnectKit/Sources/SSMConnectKit/Auth/STSIdentityResolver.swift:16-22`).
It takes its endpoint from the client's resolver like every other request.
Today it hardcodes `sts.<region>.amazonaws.com`
(`SSMConnectKit/Sources/SSMConnectKit/Auth/STSPresigner.swift:16`), so this
changes only China regions, where the correct suffix is `amazonaws.com.cn`.
Ignoring retry settings and configured endpoints, that China correction, and the
capability preflight below are the only intended differences from the current
macOS app, recorded as exceptions in `AGENTS.md`. Signature Version 4 signing is implemented
once and also produces the presigned STS token. Credentials and tokens never
appear in logs or errors. The client adds no operation the app does not use,
and the project does not fork aws-sdk-swift or aws-crt-swift.

Linux and Windows use the client from their first build. The macOS app keeps
aws-sdk-swift until its full package suite and documented native flows pass on
the client; it then switches, and aws-sdk-swift and aws-crt-swift are removed
from the package, so no shipped artifact contains them. Contributing Windows
support to aws-crt-swift is not part of this feature.

### First increment

Before broad extraction, the first accepted implementation increment must prove
the helper and the AWS client on native Windows and Linux. Exercise SSO
authorization/refresh, an AWS service call, real SSM/plugin I/O, cancellation
and owned-child cleanup. A blocker there stops the increment for an owner
decision; it never silently authorizes another core language, a duplicated
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
mode. This applies on macOS too, where a missing plugin is found today only after
sign-in, a possible instance start and an SSM session request
(`SSMConnectKit/Sources/SSMConnectKit/StateMachine/ConnectionStateMachine.swift:304-426`).
DCV Viewer is not such a capability: a desktop connection on a client
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

[release.yml](../../.github/workflows/release.yml) stays the one version
authority and release owner. It computes the version with GitVersion, then
creates the tag and the GitHub Release before any platform builds; today it
creates the release only after the macOS build
(`.github/workflows/release.yml:34-88`). Separate macOS, Windows and Linux jobs
then each build and upload only their own assets. A failed platform job leaves
its asset missing without blocking the others. Releases are created without GitHub's latest mark. The macOS job sets it after
uploading its ZIP, unless a newer release already has a macOS ZIP; that check
and the update run as one step in a repository-wide `release-latest`
concurrency group that queues rather than cancels, so a paused older run decides
only after a newer one has finished, so
Homebrew's sync, which reads the latest release, always finds a ZIP and a late
older macOS build never displaces a newer one. Published assets never change:
rerunning a job uploads only assets that are still missing, and a bad asset is
fixed by releasing a new version, so Homebrew and WinGet checksums stay valid.
The macOS job keeps
[release.sh](../../scripts/release.sh), the ZIP and the Homebrew cask. New
helper/framework artifacts must be bundled, licensed and signed with the
application. The Windows job builds a per-user WiX MSI on a native runner,
uploads it, and then submits a WinGet manifest for `VHCo.SSMConnect` whose
SHA-256 matches that MSI. The Linux job builds `.rpm` and `.deb` packages for
the matrix and uploads them. Each needs
prerequisite checks and install/upgrade/uninstall verification on its target.

Installing, upgrading or removing never interrupts a running client without the
user agreeing. The Windows MSI uses Restart Manager to ask the user to close SSM
Connect; closing ends its connections cleanly, and declining ends the install
with nothing changed. On Linux a package upgrade or removal does not stop a
running client: its established connections keep working until the user quits.
Before launching the helper, the plugin or the editor proxy, the launcher checks
the exact file it is about to start: each bundled executable carries its build
ID, and each build records the expected hash of its bundled plugin. A mismatched
or unreadable file is refused, so a half-replaced or interrupted install does not
start a mixed build, apart from the check-to-start instant described below. An action whose files were replaced is refused with "SSM
Connect was updated; restart it", and one whose files were removed with "SSM
Connect was removed; quit it", instead of failing on a replaced or missing file.
During a partial upgrade, an action that uses only unchanged files of its own
build may still proceed on that build. After the upgrade completes the same rule
holds: an action is refused exactly when a file it would start differs from its
build, so a new connection through the running old helper still proceeds when
the upgrade left the bundled plugin byte-identical. A running helper keeps
serving commands that launch nothing new. A file replaced in the instant between its check and
its start is outside this check: a helper swapped in then is refused at
handshake, the proxy checks its own build once it runs, and a plugin swapped in
then runs the newer bundled plugin, whose command-line interface the helper and
proxy already use. The editor proxy, which VS Code starts without the shell or helper,
applies the same rule: each lease records its owner's build, and a proxy whose
own build or plugin hash differs refuses a new channel before any AWS call and prints the
"updated; restart it" message for VS Code to show. After removal the proxy is
gone, so VS Code's SSH reports that it cannot start the connection. Established
channels continue. The Windows uninstaller asks through Restart Manager, like the
installer.

Uninstalling removes the installed program files and transient transport
artifacts (helper units, leases and temporary files). Profiles, settings,
browser profiles, routing and restore files stay, as the browser feature
requires after exit (`docs/specs/browser-bootstrap.spec.md:231-247`), so a
reinstall continues where the user left off.

A failed MSI rolls back. A failed `.rpm` or `.deb` install is repaired by
installing the package again with dnf or apt; the install guide says so, and
the packages' maintainer scripts only run non-fatal desktop and icon cache
refreshes. Profiles, settings and other persisted state live outside the
package, so neither a failed install nor its repair changes them. Do not resurrect old release workflows as if they publish the new
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
- [ ] AC-20: The macOS application retains its current native interaction and documented desktop, browser, editor and recovery behavior while using the extracted core, except that AWS retry settings and configured AWS endpoints no longer affect it, its STS identity request uses the correct China endpoint, and an action missing a hard requirement is refused before any AWS call.
- [ ] AC-21: Every declared Windows/Linux artifact installs, starts with its required dependencies, upgrades and uninstalls correctly on its declared native OS/CPU/desktop matrix, including while a prior version is running, without interrupting it unless the user agrees.
- [ ] AC-22: Each declared client meets the startup, idle-resource, responsiveness and connection-latency budgets in Design against the recorded macOS baseline: 1.10 times for the refactored macOS app and 1.5 times for Windows and Linux.
- [ ] AC-23: Supported Windows and Linux clients complete real SSO/refresh, AWS/SSM/plugin and native-integration scenarios; cross-compilation is not their sole support evidence.
- [ ] AC-24: macOS, Windows and Linux artifacts remain independently buildable and releasable, with all selected core/helper assets and required notices present in their final packages.
- [ ] AC-25: An action whose required capability is unavailable on the platform is refused with a message naming that capability, before any AWS call, process launch or configuration write, and without switching to another connection mode.
- [ ] AC-26: Upgrading macOS from the current release to the refactored app, and reinstalling the current release afterwards, keeps profiles, attachments, editor recovery intent and integration metadata usable, with identity, consent and restore behavior unchanged.
- [ ] AC-27: On Windows and Linux, each shell's helper is reachable only through its own pipes and ends with its shell; every admitted command receives exactly one terminal result; and no command is ever repeated after a helper stop.
- [ ] AC-28: Every client reaches AWS through the one SSM Connect AWS client, no shipped artifact contains aws-sdk-swift or aws-crt-swift, and each SDK operation the app uses sends the same requests, retries the same failures and yields the same user-facing errors as the current SDK-based app with no retry settings configured; the STS identity request sends the same request as today's direct path, except that in China regions it goes to the resolver's `amazonaws.com.cn` host, and keeps its single attempt.

## Test Plan

| Criterion | Proof |
| --- | --- |
| AC-11 | Boundary checks and common-core tests on each OS, plus a native UI command/event drive-through proving the macOS app (in-process) and the Windows and Linux shells (through the helper) invoke the same Swift implementation. Inspect the built dependency graph for duplicate production workflows. |
| AC-12 | On each supported native DCV target, connect in both modes, exercise readiness failure/retry and agent rejection, and verify authenticated Viewer access plus cleanup. Rejection must not fall back to a shared identity. |
| AC-13 | On each platform, run headless, web-only and editor-only flows against a target with no DCV server or desktop environment, from a client with DCV Viewer not installed; assert zero password/provision/Viewer operations and verify an owned working transport. Repeat with concurrent capabilities. |
| AC-14 | Run current profile/codec/store tests with `swift test --package-path SSMConnectKit`; cross-import v1/v2 fixtures, change attached files externally, race Save, and verify identity, unknown fields, consent and original bytes on conflict. Repeat native file-permission/rename cases. |
| AC-15 | Controlled clock/expiry tests and native expiry/revocation scenarios: silent renewal, rejected refresh, one explicit login, pending-action resume, profile change, Stop and cancellation. Healthy established transports retain their target/auth context. |
| AC-16 | On each platform, for Chrome Separate Browser and Zen in both modes at that platform's pinned versions, run consent/setup/restore, policy/ownership refusal and transport-loss scenarios. Selected private suffixes must fail closed while unrelated public browsing remains unchanged. |
| AC-17 | Native Remote-SSH scenarios cover concurrent windows, expired authorization/lease recovery, dirty buffers, app interruption and confirmed replacement. On Windows and Linux, start with VS Code closed, open a workspace through SSM Connect so it launches VS Code, create unsaved content, then kill the helper: VS Code keeps running with the unsaved content, its channels end, and editor recovery reconnects them through the replacement helper. Verify VS Code is outside the helper's job object or systemd unit. Reopen the original workspace authority and verify remote commands/editing without bypassing host-key checks. |
| AC-18 | Kill only the owned test client/process by PID during an active transport, start no replacement client, and check that every owned descendant (helper, plugin, SSH) ends while unrelated processes, and VS Code, DCV Viewer and browser windows SSM Connect launched, keep running. On Linux, also suspend the helper with SIGSTOP before killing the shell and verify that systemd ends the helper's unit and all its processes within 10 seconds; repeat disconnect/cancel, restart, sleep and logoff scenarios from a separate native test controller. |
| AC-19 | Seed synthetic secrets, then inspect profiles, state/events, logs and temp artifacts; exercise cross-user access, file substitution and stale-owner/generation cases using native OS permissions. Report unexecuted native cases separately. |
| AC-20 | Run the complete current macOS package suite and build the release artifact on its native runner. Execute the current documented native flows against the baseline, without replacing an installed app unless separately authorized. |
| AC-21 | On a clean target for each matrix entry, install the final package (Windows 11 x64: `winget install` from a locally validated manifest for the MSI; Fedora 43: `dnf install` of the `.rpm`; Ubuntu 24.04: `apt install` of the `.deb`), verify dependencies and launch, upgrade over the prior candidate, uninstall and check owned residue. Repeat the upgrade with the prior candidate running an active connection: on Windows, declining the Restart Manager prompt leaves the prior version installed and connected, and accepting closes it cleanly before install; on Linux, the running pair keeps its established connection; between builds whose bundled plugins differ, starting a new connection is refused with the "updated; restart it" message before any AWS call, and between builds that bundle a byte-identical plugin it proceeds on the running old helper; in both cases opening VS Code or requesting a new channel from an already open VS Code window is refused by the replaced proxy with that message before any AWS call, and killing the helper refuses its replacement launch. Repeat uninstall with an active connection: on Windows, declining leaves the client installed and connected and accepting closes it cleanly first; on Linux the running client keeps its established connection, a new connection or VS Code action shows the "removed; quit it" message without launching anything, a new channel from an open VS Code window fails with VS Code's SSH connection error and no AWS call, and after the user quits no program file or transient artifact (helper unit, lease, temporary file) remains while profiles, settings, browser profiles and routing and restore files are still present. Pause an `.rpm` and a `.deb` upgrade after only the helper executable is replaced: a new connection handled by the running old helper proceeds on the old build, a new channel from an open VS Code window proceeds on the old build, and killing the helper then refuses the replacement launch with the "updated; restart it" message. Repeat with only the plugin replaced: a new connection and a new VS Code channel are both refused with that message, and no launch whose files were replaced before its check starts files from two builds. Replace the helper between its check and its start and verify the handshake refuses it. Force a failed MSI upgrade and verify the previous version remains installed and runs with its state intact. For the `.rpm` and `.deb`, force a failure after at least one file has been replaced, reinstall the package with dnf or apt, and verify the client starts with its profiles and settings unchanged. Inspect both packages and verify every maintainer script action is non-fatal. Record exact OS/CPU/desktop and artifact hash. |
| AC-22 | First record the comparison hosts and then the current macOS release baseline in this document under the recorded workload. Then, on each matrix target, measure startup-to-ready, settled idle RSS/CPU, UI-command response and cold/warm connection timings under the same workload with the process set, runs, median and sampling defined in Design. Pass when every metric is at most 1.10 times the baseline for the refactored macOS app on the baseline Mac and at most 1.5 times for Windows and Linux on their recorded hosts. |
| AC-23 | Native Windows/Linux feasibility records must include exact Swift, AWS client commit and plugin versions, interactive SSO plus refresh, AWS response, usable SSM traffic, cancellation and owned-process cleanup. Later full native acceptance must use the final UI/core integration. |
| AC-24 | Rebuild through each actual release path; inspect the unpacked final artifact for selected core/helper/runtime assets, executable permissions or signatures as applicable, and licenses. Check that the WinGet manifest's SHA-256 matches the released MSI. Verify one platform's release does not require publishing another's. With the macOS job failing, the Windows and Linux jobs still publish their assets to the release; rerunning a platform job after its assets were published uploads nothing and leaves every published asset byte-identical, and Homebrew and WinGet installs still verify; platform jobs finishing at the same time leave one release holding every asset. A Windows/Linux-only release is not marked latest; a macOS ZIP uploaded to an older release after a newer one already has its ZIP leaves the newer release latest; the Homebrew sync then installs the latest macOS ZIP. Pausing an older run's macOS job just before its latest step, completing a newer release's publication, and then resuming the older run leaves the newer release latest, and Homebrew installs its ZIP. |
| AC-25 | With fake ports recording every call, run each action with each required capability reported missing (Session Manager plugin for every action, OpenSSH and VS Code for editor actions, browser for managed browsing); assert the refusal names that capability and zero AWS calls, process launches and configuration writes were recorded. With DCV Viewer reported missing, a desktop connection keeps its tunnel up with the current warning, as `ConnectionStateMachineTests` requires today. Repeat natively on each matrix target with one capability removed, with every outbound connection from the client's process tree blocked and logged at the operating system (a network namespace whose only route is a logging proxy on Linux, an audited outbound firewall rule on Windows): no connection attempt is logged, no child process starts and no configuration file changes. A positive control build that sends the direct STS identity request (`STSIdentityResolver`) before refusing must make this check fail. |
| AC-26 | In an isolated macOS user account with representative profiles, attachments, editor recovery intent and integration metadata written by the current release: install the refactored build and verify identity, consent, restore and conflict behavior; then have it create or update state through every persisted-state writer: profiles, attachments, portable documents and settings (`ProfileStore`), editor recovery intent (`EditorRecoveryStore`), and browser routing and ownership records (`BrowserBootstrap`). Reinstall the current release and verify it reads each resulting artifact with the same identities, consent, conflict and restore behavior. |
| AC-27 | Helper protocol tests with fake ports: two concurrent commands each get one terminal result; a command conflicting with current state is refused before any recorded side effect; cancelling one workflow leaves a second running. Native tests on each Windows/Linux target: no named pipe or socket exists for the helper; a second launch focuses the first shell and starts no second helper; killing the shell ends the helper and all its descendants; killing only the helper during an established transport, with the shell running, ends every descendant before the replacement helper starts; killing the helper mid-StartSession fails that command with "core stopped", one replacement starts, and exactly one StartSession was recorded. A helper from a different build is refused at handshake. A replacement that exits at once, never completes its handshake, or stops answering heartbeats leads, within the stated limits, to "SSM Connect core unavailable" with Retry and no further automatic restart; a first helper that never handshakes leads there without any automatic restart; after ten healthy minutes one automatic restart is available again; a pending command whose cancel is not confirmed within 10 seconds leads to helper replacement. |
| AC-28 | Signing tests pass the published Signature Version 4 test suite on macOS, Linux and Windows. For each of the 11 SDK operations, fixtures recorded from the current SDK-based app through a local recording endpoint (requests, a success response, a throttling response and each service error the app translates) show the client sending equivalent requests to the same endpoint, retrying the same responses the same number of times, and producing the same typed error and message. Under a controlled clock, with no retry settings configured, the delays between attempts match the pinned SDK's retry strategy options; closed connections, HTTP timeouts and transient transport failures are retried as the SDK's retry classifier retries them; and cancelling during a backoff wait ends the call without another attempt; the existing error-translation tests pass on the client. Separately, without an endpoint override, the SDK's endpoint resolver and the client's give the same production endpoint for every service in standard, China and GovCloud regions. With `AWS_MAX_ATTEMPTS`, `AWS_RETRY_MODE`, `AWS_NEW_RETRIES_2026` or a shared-config retry setting present, the client's attempts and delays are unchanged; with `AWS_ENDPOINT_URL`, a service-specific endpoint variable or a shared-config endpoint present, every request still goes to the resolver's regional endpoint. The STS identity request makes exactly one attempt: a throttling, 5xx or access-denied response fails at once with the same typed error as today. Outside China, the STS identity request recorded from today's direct path matches the client's request byte for byte after signing with the same time; in China regions it goes to the resolver's `amazonaws.com.cn` host. Each of the 12 requests succeeds once against AWS natively on every matrix target. Inspecting every built artifact and the resolved package graph finds no aws-sdk-swift, aws-crt-swift or Smithy module. |

## Tasks

Increment 1 measures the baseline, builds the AWS client and proves it with the
helper natively before broad extraction, as Design requires. T3 was dropped when
the SDK route proved blocked; its finding is in Context. Tasks that need live AWS, a native
host or an installed app run only under the owner's authority for that task.

- [ ] T1 `scripts/perf/measure.sh`, `scripts/perf/README.md` - measurement harness implementing the Design method (app process set, one warm-up and ten runs, medians, five settled minutes, 60 one-second idle samples, host and OS build header) for macOS, Windows and Linux; done: a run on the baseline Mac prints all five metrics under the host header (AC-22)
      Progress: harness committed; `scripts/perf/measure.sh scripts/perf/workloads/selftest.env` on fedora-43 gave startup 325, ui 164, cold 272, warm 223 ms against fake delays of 300, 100, 200, 200, and `--dry-run` with `workloads/macos.env` loaded on MacBook-Pro (macOS 26.6.2, app 0.7.0). The baseline-Mac run is pending: it needs v0.7.1 installed, a quiet Mac, Accessibility permission for the measuring process and a profile with a valid SSO session.
- [ ] T2 `docs/specs/cross-platform-client.spec.md` - record the named comparison hosts and the current macOS release baseline from T1 as an annotation under this task; done: the annotation names the Mac, Windows and Linux hosts with OS builds, the workload and every median (AC-22)
- [ ] T32 `SSMConnectKit/Tests/SSMConnectAWSClientTests/SigV4Tests.swift` - failing tests built from the published Signature Version 4 test suite and the existing STS presign cases; done: they fail because the signer does not exist (AC-28)
- [ ] T33 `SSMConnectKit/Sources/SSMConnectAWSClient/SigV4.swift` - the signer, used by the STS presign as well; done: T32 and the existing STS tests pass on macOS, Linux and Windows CI runners (AC-28)
- [ ] T34 `SSMConnectKit/Tools/FixtureRecorder/`, `SSMConnectKit/Tests/SSMConnectAWSClientTests/` - record, from the current SDK-based code through a local endpoint, the request, a success, a throttling response and each translated service error for all 11 SDK operations and the STS identity request from today's direct path (its China host excepted), and write failing parity tests for requests, retry counts, resolver-level endpoints in standard, China and GovCloud regions without an override, the fixed retry policy and regional endpoint unaffected by retry and endpoint settings in the environment and shared config, STS single-attempt failure scenarios, controlled-clock backoff delays, transport failures, cancellation during backoff and the resulting typed errors; done: the tests fail because the client does not exist (AC-28)
- [ ] T35 `SSMConnectKit/Sources/SSMConnectAWSClient/` - the client: REST JSON, EC2 Query, AWS Query and AWS JSON 1.1 encoding, endpoint resolution, the fixed retry policy and error results for the 12 requests, with `STSIdentityResolver` moved onto it; done: T34 passes on macOS, Linux and Windows CI runners (AC-28)
- [ ] T4 `spikes/helper-feasibility/` - minimal Swift helper built from the current SSO, SSM and plugin sources and the T35 AWS client behind stub UI ports, speaking over stdin/stdout; done: it builds natively on Windows 11 x64 and Fedora 43 x86-64 (AC-23, AC-28)
- [ ] T5 `docs/specs/cross-platform-client.spec.md` - run T4 on Windows 11 x64 and Fedora 43 and record exact Swift, AWS client commit and plugin versions, interactive SSO and refresh, an AWS response, usable SSM traffic, cancellation and owned-process cleanup as an annotation under this task; done: every item is recorded as observed (AC-23)
- [ ] T6 `scripts/check-boundaries.sh` - check that SSMConnectDomain and SSMConnectWorkflow sources import none of AppKit, SwiftUI, Darwin, ServiceManagement, UserNotifications or an AWS SDK module; done: it fails because those targets do not exist yet (AC-11)
- [ ] T7 `SSMConnectKit/Package.swift`, `SSMConnectKit/Sources/SSMConnectDomain/` - move models, validation, the profile codec and typed errors, re-exported by the umbrella; done: `swift test --package-path SSMConnectKit` and the Xcode app build pass, and T6 passes for Domain (AC-11, AC-20)
- [ ] T8 `SSMConnectKit/Sources/SSMConnectWorkflow/` - move the connection, authorization and remote-development state machines and their retry and cancellation rules onto injected ports, moving Darwin signal handling and browser opening into macOS adapters; done: package tests pass and T6 passes (AC-11, AC-15, AC-20)
- [ ] T9 `SSMConnectKit/Sources/SSMConnectAWS/` - move the AWS boundary into its own target: the T35 client for Linux and Windows, and the existing SDK adapters for macOS until T36, with STS presigning and error translation shared; done: package tests pass on macOS and the T34 parity tests pass on Linux and Windows (AC-11, AC-28)
- [ ] T10 `SSMConnectKit/Sources/SSMConnectMacOS/`, `SSMConnectKit/Sources/SSMConnectUI/` - move AppKit adapters, persistence, DCV, browser and editor launchers and SwiftUI, keeping the composition root in the umbrella; done: the complete package suite passes and `scripts/release.sh` builds the app on a native macOS runner (AC-20, AC-24)
- [ ] T11 `SSMConnectKit/Tests/SSMConnectKitTests/Services/PersistedStateCompatibilityTests.swift` - fixtures written by the current release are read, and written back by every writer (`ProfileStore`, `EditorRecoveryStore`, `BrowserBootstrap` records) in the current-release keys and versions; done: the tests pass (AC-26, AC-14)
- [ ] T12 `SSMConnectKit/Tests/SSMConnectKitTests/StateMachine/CapabilityPreflightTests.swift` - failing tests: each missing hard requirement refuses with its name and no recorded AWS call, process launch or configuration write; a missing DCV Viewer keeps the tunnel with the current warning; done: they fail because preflight does not exist (AC-25)
- [ ] T13 `SSMConnectKit/Sources/SSMConnectWorkflow/CapabilityPreflight.swift` - preflight before any effect; done: T12 and `ConnectionStateMachineTests` pass (AC-25, AC-13)
- [ ] T14 `SSMConnectKit/Tests/SSMConnectHelperTests/ProtocolTests.swift` - failing protocol tests with fake ports: framing, refusal of a different build at handshake, one terminal result per admitted command, refusal before side effects, cooperative cancel isolation, heartbeat; done: they fail because the helper targets do not exist (AC-27)
- [ ] T15 `SSMConnectKit/Sources/SSMConnectHelperProtocol/`, `SSMConnectKit/Sources/SSMConnectHelper/` - helper executable over stdin/stdout with diagnostics on stderr, exiting on stdin EOF; done: T14 passes on macOS, Ubuntu and Windows CI runners (AC-27, AC-11)
- [ ] T16 `SSMConnectKit/Sources/SSMConnectWorkflow/LeaseOwner.swift`, `SSMConnectKit/Sources/SSMConnectProxy/` - lease owner identity behind a port (the app process on macOS, the helper's PID and start time on Windows and Linux), so the proxy ends channels when the owner is gone, and record the owner's build in the lease so a proxy of a different installed build refuses new channels before any AWS call; done: new lease tests pass on all three platforms and existing Remote-SSH tests pass unchanged (AC-17)
- [ ] T17 `SSMConnectKit/Sources/SSMConnectWindows/` - core-side Windows adapters: per-user ACL atomic files, key-value store, plugin and SSH process launch, VS Code, Chrome and Zen discovery with per-platform pinned versions; done: adapter tests pass on the windows-2025 runner (AC-19, AC-16, AC-17)
- [ ] T18 `windows/tests/SSMConnect.App.Tests/HelperHostTests.cs` - failing tests for the helper host: a job object per helper, terminate and wait empty before a replacement, one automatic restart under the handshake, heartbeat and cancel limits with its re-arm, the error with Retry, single instance, user apps started outside the job, and the "updated; restart it" message on a build mismatch; done: they fail because the host does not exist (AC-18, AC-27, AC-21)
- [ ] T19 `windows/src/SSMConnect.App/HelperHost.cs` - the helper host; done: T18 passes (AC-18, AC-27)
- [ ] T20 `windows/src/SSMConnect.App/` - the WPF shell reapplied from `ce24cf2` without connection rules: settings, tray, profile files, clipboard, notifications, startup, and launching VS Code, DCV Viewer and browsers at the helper's request; done: a UI drive-through test shows every action reaching the helper as a command (AC-11, AC-14)
- [ ] T21 `packaging/windows/`, `.github/workflows/release.yml` - restructure the release workflow to create the tag and GitHub Release before platform jobs, with the macOS job uploading its existing assets, and add the Windows job: a per-user WiX MSI with the Restart Manager close prompt, WinGet manifest hashed from the built MSI, and notices; done: a dispatched run on a test tag creates the release first without the latest mark, the macOS job marks it latest after its ZIP unless a newer release has one, inside the queued `release-latest` concurrency group, the macOS and Windows jobs upload independently, a rerun of a job uploads only missing assets and changes no published one, the manifest validates, and the unpacked MSI holds the helper, runtime and notices (AC-21, AC-24)
- [ ] T22 `SSMConnectKit/Sources/SSMConnectLinux/` - core-side Linux adapters: user-only atomic files, key-value store, plugin and SSH process launch, VS Code, Chrome and Zen discovery with per-platform pinned versions, and the build-ID and plugin-hash check of the exact file before every launch; done: adapter tests pass on Fedora 43 and Ubuntu 24.04 (AC-19, AC-16, AC-17)
- [ ] T23 `linux/tests/helper_host_test.cpp` - failing tests for the helper host: a transient systemd user service bound to the shell's scope, creating that scope when missing, stop and wait empty before a replacement, the restart limits, single instance, and user apps in their own transient scopes; done: they fail because the host does not exist (AC-18, AC-27)
- [ ] T24 `linux/src/helper_host.cpp` - the helper host; done: T23 passes (AC-18, AC-27)
- [ ] T25 `linux/src/`, `linux/qml/` - the Qt 6 shell with a StatusNotifierItem tray, launching VS Code, DCV Viewer and browsers at the helper's request; done: a UI drive-through test shows every action reaching the helper as a command (AC-11, AC-14)
- [ ] T26 `packaging/linux/`, `.github/workflows/release.yml` - the Linux job: `.rpm` and `.deb` whose maintainer scripts only run non-fatal cache refreshes, with notices; done: the Linux job builds and uploads both on a test tag, publishes with the macOS job failed, and the package inspection in the AC-21 and AC-24 rows passes (AC-21, AC-24)
- [ ] T36 `SSMConnectKit/Package.swift`, `SSMConnectKit/Package.resolved`, `SSMConnectKit/Sources/SSMConnectAWS/` - switch macOS to the client and remove aws-sdk-swift and aws-crt-swift from the package; done: the complete macOS package suite and `scripts/release.sh` pass, the documented macOS flows run natively on the client, and the resolved package graph has no aws-sdk-swift, aws-crt-swift or Smithy module (AC-28, AC-20)
- [ ] T27 `docs/specs/cross-platform-client.spec.md` - macOS native acceptance: the AC-20 flows, the AC-26 upgrade and rollback scenario, and the macOS parts of the AC-12 to AC-19 and AC-25 rows, and each of the 12 AWS requests once against AWS on macOS; done: an evidence line under each criterion exercised (AC-28, AC-20, AC-26, AC-12, AC-13, AC-14, AC-15, AC-16, AC-17, AC-18, AC-19, AC-25)
- [ ] T28 `docs/specs/cross-platform-client.spec.md` - Windows 11 x64 native acceptance of the AC-12 to AC-19, AC-21, AC-23, AC-25 and AC-27 rows, and each of the 12 AWS requests once against AWS on Windows 11 x64; done: an evidence line under each criterion exercised (AC-28, AC-12, AC-13, AC-14, AC-15, AC-16, AC-17, AC-18, AC-19, AC-21, AC-23, AC-25, AC-27)
- [ ] T29 `docs/specs/cross-platform-client.spec.md` - Fedora 43 and Ubuntu 24.04 native acceptance of the same rows, and each of the 12 AWS requests once against AWS on Fedora 43 and Ubuntu 24.04; done: an evidence line under each criterion exercised (AC-28, AC-12, AC-13, AC-14, AC-15, AC-16, AC-17, AC-18, AC-19, AC-21, AC-23, AC-25, AC-27)
- [ ] T30 `docs/specs/cross-platform-client.spec.md` - measure the refactored macOS app and the Windows and Linux clients with T1 on the T2 hosts; done: every metric compared with its limit in an AC-22 evidence line (AC-22)
- [ ] T31 `docs/specs/cross-platform-client.spec.md` - inspect each built dependency graph and artifact for duplicate production workflows and for any aws-sdk-swift, aws-crt-swift or Smithy module, and rebuild each platform's release path on its own; done: AC-11 and AC-24 evidence lines, and an AC-28 evidence line combining the T34 parity results, the T27-T29 native operation results and these inspections (AC-11, AC-24, AC-28)

## Open Questions

None.

## Review Log

| Date | Review | Kind | Commit | Model | Isolation | Outcome |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-11-17 | R-1 | spec | `c2507b1` | gpt-6.1-sol | procedural | No blocking findings; four should-fix and one nit |
| 2026-11-17 | R-2 | spec | `3040421` | gpt-6.1-sol | procedural | No blocking findings; six should-fix |
| 2026-11-17 | R-3 | spec | `4c4051c` | gpt-6.1-sol | procedural | One blocking (missing-Viewer conflict) and four should-fix |
| 2026-11-17 | R-4 | spec | `70c8856` | gpt-6.1-sol | procedural | One blocking (Windows job cleanup on helper exit) and four should-fix |
| 2026-11-17 | R-5 | spec | `4c1906f` | gpt-6.1-sol | procedural | No blocking findings; three should-fix and one nit |
| 2026-11-17 | R-6 | spec | `828865e` | gpt-6.1-sol | procedural | One blocking (rpm/deb failure recovery overstated) and one nit |
| 2026-11-17 | R-7 | spec | `3b57fd0` | gpt-6.1-sol | procedural | No blocking findings; one should-fix |
| 2026-11-17 | R-8 | spec | `0936c83` | gpt-6.1-sol | procedural | NO FINDINGS |
| 2026-11-17 | R-8 | spec | `0936c83` | n/a | n/a | accepted by owner |
| 2026-11-17 | R-9 | spec | `457a178` | gpt-6.1-sol | procedural | One blocking (task list still targets the SDK) and one should-fix |
| 2026-11-17 | R-10 | spec | `a08d414` | gpt-6.1-sol | procedural | No blocking findings; three should-fix |
| 2026-11-17 | R-11 | spec | `5d97336` | gpt-6.1-sol | procedural | No blocking findings; two should-fix |
| 2026-11-17 | R-12 | spec | `a3da4a4` | gpt-6.1-sol | procedural | No blocking findings; three should-fix |
| 2026-11-17 | R-13 | spec | `d64f65e` | gpt-6.1-sol | procedural | No blocking findings; three should-fix |
| 2026-11-17 | R-14 | spec | `f5f70ba` | gpt-6.1-sol | procedural | One blocking (STS endpoint in China) and two should-fix |
| 2026-11-17 | R-15 | spec | `854a1ac` | gpt-6.1-sol | procedural | One blocking (AC-28 STS equality versus China) and two should-fix |
| 2026-11-17 | R-16 | spec | `0cedaa8` | gpt-6.1-sol | procedural | No blocking findings; four should-fix |
| 2026-11-18 | R-17 | spec | `5b63311` | gpt-6.1-sol | procedural | No blocking findings; two should-fix |
| 2026-11-18 | R-18 | spec | `0ffb4ce` | gpt-6.1-sol | procedural | One blocking (partial-upgrade scenario versus the persistent helper) and two should-fix |
| 2026-11-18 | R-19 | spec | `c7c2163` | gpt-6.1-sol | procedural | No blocking findings; two should-fix |
| 2026-11-18 | R-20 | spec | `654c59e` | gpt-6.1-sol | procedural | NO FINDINGS |

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

### R-7

FINDING: F-01
KIND: factual
SEVERITY: should-fix
WHERE: Context / Owner summary, helper failure; Scope / native integration adapters; Design / One implementation, several shells, platform adapters; Design / Integration and feasibility, containment and editor recovery; Acceptance Criteria / AC-17, AC-18, AC-27; Test Plan / AC-17, AC-18, AC-27
EVIDENCE: Design terminates every process in the helper's container after helper failure while promising that VS Code retains unsaved windows. The current editor launcher invokes the editor through Process at SSMConnectKit/Sources/SSMConnectKit/StateMachine/RemoteDevelopmentStateMachine.swift:70-71 and 637-643. Reusing that launch inside the helper can place a newly started editor inside its teardown container. Windows child processes inherit job membership by default, according to Microsoft's [Job Objects documentation](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects); Linux unit cleanup kills its contained processes, as documented by [systemd.kill](https://www.freedesktop.org/software/systemd/man/latest/systemd.kill.html). The specification does not define how editor UI escapes that lifetime. AC-17's helper-failure scenario does not require VS Code to be initially closed, so it can pass using an existing editor process while missing this failure.
PROPOSAL: Specify that editor UI survives outside the helper's teardown container while its owned access channels remain revocable. Require native tests that start with VS Code closed, launch it through SSM Connect, create unsaved content and kill the helper, then verify that the editor survives and reconnects through recovery.

### R-8

NO FINDINGS

### R-9

FINDING: F-01
KIND: factual
SEVERITY: blocking
WHERE: Context / Owner summary, lines 67-74; Scope / AWS exclusions; Design / AWS client and First increment; Acceptance Criteria / AC-28; Test Plan / AC-23, AC-28; Tasks / T3-T5, T9
EVIDENCE: The revision replaces the SDK with an application-owned client, requires Windows/Linux to use it first, and removes the SDK from shipped artifacts. The active task sequence still requires finding a Windows-compatible SDK release in T3, records the owner decision as pending, requests SDK versions in T5, and moves SDK clients in T9. No task implements or verifies AC-28. Under the pinned feature-document rules, this populated task list makes a planned feature proceed to implementation without requiring replanning. Following it therefore returns to the dependency blocker this revision resolves.
PROPOSAL: Replan the unchecked task sequence around the selected AWS client, with failing parity tests first, native feasibility before extraction, and macOS cutover and dependency removal last. Preserve T3's investigation as historical evidence while removing its superseded requirement from the executable plan.

FINDING: F-02
KIND: factual
SEVERITY: should-fix
WHERE: Design / One implementation, several shells, AWS boundary; Design / AWS client, lines 355-359; Acceptance Criteria / AC-28; Test Plan / AC-28
EVIDENCE: The new AC-28 proof compares retry counts for recorded responses but never checks retry delays or transport failures. The pinned SDK supplies [backoff configuration](https://github.com/smithy-lang/smithy-swift/blob/31336dfea2e448523630ea1fe4d83ddc1156de3c/Sources/SmithyRetriesAPI/RetryStrategyOptions.swift), and its [retry classifier](https://github.com/awslabs/aws-sdk-swift/blob/b60b2f0805a6177cf0bc181c973134281fbff972/Sources/Core/AWSClientRuntime/Sources/AWSClientRuntime/Retry/AWSRetryErrorInfoProvider.swift) handles closed connections and HTTP timeout and transient failures. A replacement that retries immediately and never retries a closed connection could pass the stated response-count comparisons and native success scenarios while violating the promised retry parity. This gap comes from the AWS-client replacement introduced in this revision.
PROPOSAL: Extend AC-28's proof with controlled-clock backoff checks and transport-failure scenarios against the pinned SDK behavior. Include cancellation during backoff and verify that it prevents another attempt.

### R-10

FINDING: F-01
KIND: factual
SEVERITY: should-fix
WHERE: Design / AWS client, lines 355-358; Acceptance Criteria / AC-28; Test Plan / AC-28; Tasks / T34, T35
EVIDENCE: AC-28 and T34 use a local recording endpoint to establish endpoint parity. The pinned SDK's [EC2 endpoint resolver](https://github.com/awslabs/aws-sdk-swift/blob/b60b2f0805a6177cf0bc181c973134281fbff972/Sources/Services/AWSEC2/Sources/AWSEC2/Endpoints.swift) returns the supplied custom endpoint before evaluating its regional and partition rules. Comparing requests sent to that recorder therefore does not establish the promised production endpoint selection. A client with incorrect regional resolution could pass those comparisons and the native success check in one region. The new T34 carries this gap into the task sequence added for R-9 F-01.
PROPOSAL: Capture the SDK's resolved production endpoint before transport redirection, or compare resolver outputs separately without an endpoint override. Cover the regional and partition cases the replacement must preserve.

FINDING: F-02
KIND: factual
SEVERITY: should-fix
WHERE: Design / AWS client, lines 355-358; Acceptance Criteria / AC-28; Test Plan / AC-28; Tasks / T34, T35
EVIDENCE: The retry checks added for R-9 F-02 cover delays, transport failures and cancellation, but do not check configuration resolution. The application leaves retry options unset in Services/EC2Clients.swift:33-36 and Services/SSMClients.swift:29-32. The pinned SDK's [AWSRetryConfig.swift](https://github.com/awslabs/aws-sdk-swift/blob/b60b2f0805a6177cf0bc181c973134281fbff972/Sources/Core/AWSClientRuntime/Sources/AWSClientRuntime/Retry/AWSRetryConfig.swift) resolves AWS_MAX_ATTEMPTS, AWS_RETRY_MODE and shared-config values, including invalid-mode errors. A replacement that always uses three attempts and the default mode could pass every specified parity scenario while changing the current application's behavior for configured users.
PROPOSAL: Add parity cases for retry settings from the environment and shared AWS config, including precedence and invalid settings. Any intended removal of that existing behavior needs an owner decision.

FINDING: F-03
KIND: factual
SEVERITY: should-fix
WHERE: Acceptance Criteria / AC-28; Test Plan / AC-28; Tasks / T5, T27, T28, T29, T31, T36
EVIDENCE: AC-28 requires each of the 11 operations to succeed against AWS natively on every platform. The revised tasks addressing R-9 F-01 do not schedule that complete check. T5 records one AWS response on Windows and Fedora. T27-T29 list the native acceptance rows to execute but omit AC-28. T36 requires documented macOS flows, while T31 names AC-28 evidence after dependency inspection and release rebuilds. Those checks do not establish all 11 native operation successes, particularly on Windows and Ubuntu.
PROPOSAL: Add AC-28's operation checks to the native acceptance tasks for every matrix target. Require the final AC-28 evidence to include those executed results alongside the parity tests and artifact inspections.

### R-11

FINDING: F-01
KIND: factual
SEVERITY: should-fix
WHERE: Design / AWS client, lines 355-359; Acceptance Criteria / AC-28; Test Plan / AC-28; Tasks / T34, T35
EVIDENCE: The configuration checks added for R-10 F-02 cover AWS_MAX_ATTEMPTS, AWS_RETRY_MODE and shared configuration, but omit AWS_NEW_RETRIES_2026. The pinned SDK reads that flag in [AWSRetryFeatures.swift](https://github.com/awslabs/aws-sdk-swift/blob/b60b2f0805a6177cf0bc181c973134281fbff972/Sources/Core/AWSClientRuntime/Sources/AWSClientRuntime/Retry/AWSRetryFeatures.swift). Its [configuration provider](https://github.com/awslabs/aws-sdk-swift/blob/b60b2f0805a6177cf0bc181c973134281fbff972/Sources/Core/AWSClientRuntime/Sources/AWSClientRuntime/AWSClientConfigDefaultsProvider.swift#L148-L159) passes the flag into retry strategy options. The pinned Smithy implementation changes backoff and retry quotas when it is enabled. A replacement that ignores this setting could pass the listed configuration cases while violating AC-28's retry-parity requirement.
PROPOSAL: Extend T34 and AC-28's proof to cover the flag enabled, disabled and unset, including its effects on backoff, retry-after handling and quotas. Preserve the SDK's behavior unless the owner explicitly decides otherwise.

FINDING: F-02
KIND: judgement
SEVERITY: should-fix
WHERE: Context / Owner summary, AWS client description; Design / AWS client, lines 341-364; Acceptance Criteria / AC-28; Test Plan / AC-28; Tasks / T34, T35, T27-T29, T31
EVIDENCE: The eleven-operation inventory covers SDK calls, but it does not cover every AWS request the application makes. Auth/STSIdentityResolver.swift:16-25 and 42-46 sends GetCallerIdentity directly through URLSession. ConnectionStateMachine.swift:529, WebForwardsStateMachine.swift:50 and RemoteDevelopmentStateMachine.swift:293 and 603 use that path. Design shares the STS signer but does not specify ownership of this HTTP request under the promise that every client reaches AWS through one client. The new AWS-client design and its eleven-operation proofs could therefore leave this existing request outside the required boundary.
PROPOSAL: Define whether the direct STS request moves into the common client or remains an explicit exception with its existing semantics. Add a check establishing the selected boundary for editor, web and multi-user desktop identity requests.

### R-12

FINDING: F-01
KIND: judgement
SEVERITY: should-fix
WHERE: AGENTS.md:27-28; Context / Owner summary; Scope / retained macOS behavior; Design / AWS client; Acceptance Criteria / AC-20, AC-28; Test Plan / AC-20, AC-28; Tasks / T34, T35, T36; Sources / Q21
EVIDENCE: AGENTS.md requires preserving existing macOS behavior. The fixed-policy revision addressing R-11 F-01 deliberately removes behavior controlled by retry environment variables and shared configuration. Services/EC2Clients.swift:33-36 leaves retry configuration unset, and the pinned SDK's [AWSRetryConfig.swift](https://github.com/awslabs/aws-sdk-swift/blob/b60b2f0805a6177cf0bc181c973134281fbff972/Sources/Core/AWSClientRuntime/Sources/AWSClientRuntime/Retry/AWSRetryConfig.swift) resolves those settings. Q21 records the owner's policy choice, but the repository instruction and unconditional preservation requirements retain the conflicting contract.
PROPOSAL: Raise an Open Question to authorize an explicit exception to the macOS preservation instruction for the selected retry-policy change. Fold the answer into the repository instruction and the affected preservation requirements without reopening the settled policy choice.

FINDING: F-02
KIND: factual
SEVERITY: should-fix
WHERE: Design / AWS client, endpoint preservation; Acceptance Criteria / AC-20, AC-28; Test Plan / AC-28; Tasks / T34, T35, T36
EVIDENCE: The current SDK also selects endpoints from configuration. Services/InstanceConnectProviding.swift:15-17 supplies no endpoint override or ignore flag; the pinned SDK client invokes configuredEndpoint before resolving its endpoint. Its [AWSEndpointConfig.swift](https://github.com/awslabs/aws-sdk-swift/blob/b60b2f0805a6177cf0bc181c973134281fbff972/Sources/Core/AWSClientRuntime/Sources/AWSClientRuntime/Endpoints/AWSEndpointConfig.swift) resolves service-specific and global environment endpoints, shared-config endpoints and the ignore setting. The regional comparisons explicitly run without an override, while recorder comparisons supply their own endpoint. A replacement that ignores configured endpoints can pass both checks while changing the current application's request destination.
PROPOSAL: Define and test configured-endpoint behavior, including precedence and the ignore setting, alongside regional resolution. Removing this existing behavior instead requires an owner decision and an explicit compatibility exception.

FINDING: F-03
KIND: factual
SEVERITY: should-fix
WHERE: Design / AWS client, STS retry policy; Acceptance Criteria / AC-28; Test Plan / AC-28; Tasks / T34, T35
EVIDENCE: The revision addressing R-11 F-02 adds the STS identity request to the shared client and requires it to follow the client's retry policy. The proof assigns response and retry comparisons to the 11 SDK operations; its explicit STS checks establish request bytes and one successful native call. Existing Auth/STSIdentityResolverTests.swift:16-28 replaces fetch with closures, so it cannot establish HTTP retry behavior. T34 calls the checks parity tests without distinguishing this newly required STS policy from today's direct path, which performs one fetch at Auth/STSIdentityResolver.swift:16-22 and 45.
PROPOSAL: Add explicit STS failure scenarios establishing the selected shared policy, including retryable responses, terminal rejection, backoff and cancellation. State that these expectations come from the new policy rather than retry parity with the old direct request.

### R-13

FINDING: F-01
KIND: judgement
SEVERITY: should-fix
WHERE: AGENTS.md:27-31; Context / Owner summary; Scope / macOS preservation; Design / Behavior, identity and local state; Design / AWS client; Acceptance Criteria / AC-20, AC-28; Test Plan / AC-20, AC-28; Tasks / T35, T36; Sources / Q21, Q22, Q23
EVIDENCE: STSIdentityResolver.swift:16-22 and 45 makes one HTTP request and rejects a non-success response. Design:371-375 explicitly introduces retries for that request, but then names ignoring retry settings and configured endpoints as the only intended differences. AGENTS.md and AC-20 name only those two exceptions. A 503 followed by 200 fails under the existing implementation and succeeds under AC-28's new STS policy, even with no settings configured. The STS failure checks added in response to R-12 F-03 make this additional behavior change explicit without reconciling the preservation contract.
PROPOSAL: Raise an Open Question authorizing the STS retry behavior as an additional compatibility exception, or deciding how to preserve the existing behavior. Apply the answer consistently to the repository instructions, summary, preservation requirements and proofs.

FINDING: F-02
KIND: judgement
SEVERITY: should-fix
WHERE: Context / Owner summary, helper failure; Design / Integration and feasibility, process containment and editor leases; Acceptance Criteria / AC-17, AC-18, AC-27; Test Plan / AC-17, AC-18, AC-27; Tasks / T16, T18, T19, T23, T24
EVIDENCE: Design:283-295 places VS Code outside the helper's container and preserves its separate SSH proxy. RemoteSSHBridge.swift:115 and 174-185 shows that the editor's ProxyCommand starts its own Session Manager plugin. Those processes therefore do not inherit the helper's job or systemd unit. Their cleanup instead depends on the proxy executing its polling loop at lines 188-203. Suspending that proxy before killing the shell leaves its plugin outside the container being terminated, with no specified independent cleanup actor. T16 changes lease ownership but does not settle this failure path, and the native containment checks primarily inspect helper descendants.
PROPOSAL: Define containment or independent supervision for editor proxy channels when the proxy cannot execute lease cleanup. Add a native scenario that suspends the proxy, terminates the shell or helper, and verifies bounded channel cleanup while VS Code and its unsaved content survive.

FINDING: F-03
KIND: judgement
SEVERITY: should-fix
WHERE: Scope / independently releasable artifacts and distribution; Design / Migration, performance and release boundaries; Acceptance Criteria / AC-24; Test Plan / AC-24; Tasks / T21, T26, T31
EVIDENCE: Design retains release.yml while adding Windows and Linux publication workflows. The existing workflow computes and creates the version tag at .github/workflows/release.yml:34-39, then creates the GitHub Release only after the macOS build succeeds at lines 68-88. AC-24's proof requires publishing one platform without publishing another. The document does not define how Windows or Linux obtains a release when macOS fails or does not run, who owns release creation across concurrent workflows, or what happens when macOS later encounters an existing release. The pinned delivery convention requires one version authority and one release publication owner.
PROPOSAL: Raise an Open Question selecting the release coordination policy, then name its version authority, release owner and retry behavior. Extend AC-24's proof to cover Windows or Linux publication without a macOS artifact, concurrent completion and retry after partial publication.

### R-14

FINDING: F-01
KIND: factual
SEVERITY: blocking
WHERE: AGENTS.md / macOS preservation exceptions; Context / Owner summary, AWS client; Scope / macOS behavior preservation; Design / AWS client; Acceptance Criteria / AC-20, AC-28; Test Plan / AC-28; Tasks / T34, T35, T36; Sources / Q22-Q24
EVIDENCE: STSPresigner.swift:16 hardcodes sts.<region>.amazonaws.com, and STSIdentityResolver.swift:43-45 sends that URL. For cn-north-1, the pinned SDK's [STS resolver](https://github.com/awslabs/aws-sdk-swift/blob/b60b2f0805a6177cf0bc181c973134281fbff972/Sources/Services/AWSSTS/Sources/AWSSTS/Endpoints.swift) instead uses the [China partition suffix](https://github.com/awslabs/aws-sdk-swift/blob/b60b2f0805a6177cf0bc181c973134281fbff972/Sources/Core/AWSSDKDynamic/Sources/AWSSDKDynamic/Partitions.swift), amazonaws.com.cn. AC-28's proof requires resolver parity for every service in China and byte-for-byte preservation of today's direct STS request. Both cannot hold there. The previous revision restores explicit STS request preservation while retaining the broader partition requirement.
PROPOSAL: Raise an Open Question deciding the STS endpoint policy for China. Reconcile the preservation contract, endpoint requirements and fixtures with that decision.

FINDING: F-02
KIND: judgement
SEVERITY: should-fix
WHERE: Scope / independently releasable artifacts and distribution; Design / Migration, performance and release boundaries, lines 527-539; Acceptance Criteria / AC-20, AC-24; Test Plan / AC-24; Tasks / T21, T26, T31; Sources / Q26
EVIDENCE: The release policy added for R-13 F-03 permits replacing an asset when its platform job is rerun. The retained [Homebrew sync at c2baa6738ba7e902fe0c3275ec24dbd06fa58497](https://github.com/vhco-pro/homebrew-tap/blob/c2baa6738ba7e902fe0c3275ec24dbd06fa58497/.github/workflows/sync-cask.yml#L26) exits when the release version already matches the cask. Replacing that version's ZIP with different bytes therefore leaves its recorded checksum stale. AC-24 checks replacement isolation and the WinGet checksum, but never verifies Homebrew installation after replacement.
PROPOSAL: Raise an Open Question choosing immutable published assets on retry or coordinated replacement of downstream checksums. Add a release retry scenario that verifies installation through the retained distribution paths after their manifests have already consumed the original assets.

FINDING: F-03
KIND: judgement
SEVERITY: should-fix
WHERE: Context / Owner summary, Linux installation behavior; Design / Migration, performance and release boundaries, lines 543-558; Acceptance Criteria / AC-21; Test Plan / AC-21; Tasks / T22, T26, T29; Sources / Q18
EVIDENCE: Linux installation and removal promise that the running client keeps working until quit, but define recovery only when its helper dies. A surviving helper still launches executables later: BundledPluginTunnel.swift:56-65 checks the plugin pathname before launch, and RemoteSSHBridge.swift:115 and 174-184 uses separate proxy/plugin paths. An isolated Linux executable-unlink probe observed that the running helper survived removal while a subsequent child launch failed with status 127. The document does not define retention of these files or the outcome of later actions; AC-21 exercises existing connection continuity and helper death only.
PROPOSAL: Define how later plugin and editor-channel launches work after Linux upgrade or removal, raising an Open Question for any narrower continuation guarantee. Extend AC-21 to request those actions while the original helper remains alive after each package operation.

### R-15

FINDING: F-01
KIND: factual
SEVERITY: blocking
WHERE: AGENTS.md:28-32; Context / Owner summary:73-76; Design / AWS client:376-385; Acceptance Criteria / AC-20, AC-28; Test Plan / AC-28; Tasks / T34, T35; Sources / Q27
EVIDENCE: The revision addressing R-14 F-01 adds the China endpoint exception to the repository instruction, Design, AC-20 and AC-28's proof, but AC-28 still requires the STS identity request to send “the same request as today's direct path” without that exception. STSPresigner.swift:16 and 71 constructs the original request with an amazonaws.com host. Design:379-382 and Test Plan:612 require an amazonaws.com.cn host in China. Both requests cannot satisfy AC-28's unconditional equality requirement.
PROPOSAL: Qualify AC-28's STS request-preservation clause with the already selected China endpoint exception. Apply that qualification consistently to the fixture and parity-test task descriptions.

FINDING: F-02
KIND: judgement
SEVERITY: should-fix
WHERE: Design / Integration and feasibility:294-296, 331-340; Design / Migration, performance and release boundaries:551-559; Acceptance Criteria / AC-17, AC-21; Test Plan / AC-17, AC-21; Tasks / T16, T22, T29; Sources / Q29
EVIDENCE: The revision addressing R-14 F-03 requires the shell and helper to check the installed build before launching executables and refuse every new action after Linux upgrade or removal. The editor proxy has an independent entry point: RemoteSSHBridge.swift:115 installs it as VS Code's SSH ProxyCommand, and lines 134-146 authorize a new channel through AWS before lines 174-184 launch its plugin. Neither launch requires a command through the shell or helper. The document does not define how this path enforces the new restriction, including when an upgraded proxy reads a surviving old helper's lease or removal deletes the configured proxy pathname. AC-21 exercises new connections and VS Code actions through the running client, without explicitly exercising a new channel requested by an existing VS Code window.
PROPOSAL: Define how VS Code-originated channel requests behave after upgrade and removal, including validation against the lease owner's build and treatment of missing executables. Add native scenarios using an existing VS Code window while the original helper remains alive.

FINDING: F-03
KIND: factual
SEVERITY: should-fix
WHERE: Context / Owner summary:52-54; Design / Migration, performance and release boundaries:554-559; Test Plan / AC-21; Tasks / T22, T29; Sources / Q29
EVIDENCE: The owner summary says the running Linux app “keeps working until the user quits” and asks for restart or quit if its helper dies. The revision addressing R-14 F-03 instead preserves established connections while refusing every new action immediately after upgrade or removal, even when the helper remains healthy. Design:554-559, Test Plan:605 and Sources:1045-1046 state that narrower continuation guarantee. The summary omits the newly selected restriction and still describes helper loss as the trigger.
PROPOSAL: Refresh the owner summary to distinguish continued established connections from refused new actions after Linux upgrade or removal, including when the helper remains healthy.

### R-16

FINDING: F-01
KIND: judgement
SEVERITY: should-fix
WHERE: Context / Owner summary:52-56; Design / Migration, performance and release boundaries:552-573; Acceptance Criteria / AC-21; Test Plan / AC-21; Tasks / T16, T22, T26, T29; Sources / Q29, Q30
EVIDENCE: The summary requires refusal from the moment the Linux package changes. Design specifies checking the installed build before launches, but does not define how that check establishes a consistent payload during replacement or after a failed replacement. RPM replaces destinations sequentially at [fsm.cc:1061-1087](https://github.com/rpm-software-management/rpm/blob/rpm-6.0.0-release/lib/fsm.cc#L1061), so an old build marker can coexist with replaced executables. AC-21 checks actions after upgrade or removal, and repairs a failed install before checking the client. It does not exercise a running client's actions during replacement or before repair. The restriction introduced for R-14 F-03 and extended for R-15 F-02 therefore leaves this concurrent path undefined.
PROPOSAL: Define how action admission establishes package consistency during replacement and after an interrupted install, within the maintainer-script restriction. Add native scenarios that pause replacement after one file changes and attempt actions through both the running client and an existing VS Code window.

FINDING: F-02
KIND: judgement
SEVERITY: should-fix
WHERE: Scope / preservation of profile compatibility and consent; Design / Behavior, identity and local state; Design / Migration, performance and release boundaries, uninstall behavior; Acceptance Criteria / AC-16, AC-21; Test Plan / AC-21; Tasks / T26, T29
EVIDENCE: AC-21's Linux uninstall proof requires that after quitting, “no owned process or file remains.” It does not distinguish package files and temporary access artifacts from retained profiles, browser data, routing files and restore journals. The preserved browser contract explicitly retains PAC/configuration artifacts after app exit and excludes silent deletion of managed browser data at docs/specs/browser-bootstrap.spec.md:231-247. A literal implementation of the uninstall proof would remove these artifacts; an implementation retaining them would fail that reading of the proof.
PROPOSAL: Define the uninstall residue scope and which user data and routing artifacts remain. Raise the deletion policy as an Open Question, then make AC-21's proof distinguish removable package and transport residue from intentionally retained state.

FINDING: F-03
KIND: judgement
SEVERITY: should-fix
WHERE: Scope / independently releasable artifacts; Design / Migration, performance and release boundaries:534-550; Acceptance Criteria / AC-24; Test Plan / AC-24; Tasks / T21, T26, T31; Sources / Q26, Q28
EVIDENCE: The release policy introduced for R-13 F-03 allows a published release without a macOS ZIP while retaining Homebrew distribution. The retained [sync-cask.yml](https://github.com/vhco-pro/homebrew-tap/blob/c2baa6738ba7e902fe0c3275ec24dbd06fa58497/.github/workflows/sync-cask.yml) selects only the latest release with `gh release view` and downloads that release's ZIP. A Windows/Linux-only latest release makes this sync fail. If an older release's macOS job later succeeds while the latest release still lacks its ZIP, that older macOS artifact is never selected. The document does not define this downstream outcome, and AC-24 does not test releases completing out of version order.
PROPOSAL: Define how Homebrew selects and discovers available macOS artifacts under partial publication, including late completion of an older release. Name any affected downstream workflow and add an out-of-order publication scenario to AC-24.

FINDING: F-04
KIND: factual
SEVERITY: should-fix
WHERE: Context / Owner summary:47-51; Design / Integration and feasibility, helper restart rules; Test Plan / AC-27; Tasks / T18, T23; Sources / Q14, Q16
EVIDENCE: The owner summary says that if the helper stops, “one replacement starts before the app shows an error with Retry.” Design limits automatic replacements and explicitly includes first-helper failure among cases where no replacement starts. AC-27 also requires an initial handshake failure to show the error without an automatic restart. The summary promises recovery in cases where the detailed policy deliberately refuses it.
PROPOSAL: State the bounded restart policy in the summary, including initial startup failure and an exhausted replacement allowance. Keep the already selected detailed policy unchanged.

### R-17

FINDING: F-01
KIND: judgement
SEVERITY: should-fix
WHERE: Context / Owner summary:53-56; Design / Migration, performance and release boundaries:556-574; Acceptance Criteria / AC-21; Test Plan / AC-21; Tasks / T16, T22, T26, T29; Sources / Q29-Q31
EVIDENCE: The per-executable checks addressing R-16 F-01 do not establish refusal from the moment any package file changes. Consider an upgrade paused after replacing only the helper executable. The old helper remains running, while the installed proxy and plugin still belong to its old build. A new channel from an existing VS Code window passes every specified proxy check: its build matches the lease owner and its plugin hash matches. No specified check examines the replaced helper pathname. RemoteSSHBridge.swift:134-146 independently authorizes that channel through AWS. The new AC-21 partial-upgrade scenario therefore requires a refusal that the defined checks do not establish.
PROPOSAL: Define how action admission detects package replacement across both client and independent proxy paths, including changes concurrent with admission, or raise an Open Question narrowing the immediate-refusal guarantee. Test replacement of the helper alone while the proxy and plugin remain unchanged.

FINDING: F-02
KIND: judgement
SEVERITY: should-fix
WHERE: Design / Migration, performance and release boundaries:535-546; Acceptance Criteria / AC-24; Test Plan / AC-24; Tasks / T21, T31; Sources / Q33
EVIDENCE: The latest-release policy addressing R-16 F-03 leaves concurrent workflow runs undefined. An older macOS job can check that no newer release has a ZIP, pause, then resume after a newer job uploads its ZIP and marks its release latest. The older job can then overwrite that mark using its earlier decision. The specified AC-24 scenario starts the older upload after the newer ZIP already exists, so it does not exercise this interleaving. The retained Homebrew sync reads the latest release, making this a distribution regression. The pinned conventions/delivery.md also requires serialization where competing publication runs could conflict.
PROPOSAL: Define serialization covering the latest-release eligibility check and update across workflow runs. Add a scenario that pauses the older job after its eligibility check, completes the newer publication, then resumes the older job and verifies that Homebrew still selects the newer ZIP.

### R-18

FINDING: F-01
KIND: factual
SEVERITY: blocking
WHERE: Design / Integration and feasibility:268-283, 307-339; Design / Migration, performance and release boundaries:565-574; Test Plan / AC-21; Tasks / T29; Sources / Q34
EVIDENCE: The partial-upgrade scenario added for R-17 F-01 says that starting a new connection “needs a new helper” and must refuse after only the helper executable is replaced. Design instead keeps one helper per shell, accepting commands until it stops. With that old helper still healthy and the plugin unchanged, another connection needs no helper launch and uses only its original build. The narrowed Design explicitly permits such actions during partial upgrade, but AC-21's proof rejects them.
PROPOSAL: Align the partial-upgrade scenario with the persistent helper and the selected unchanged-file policy. Test refusal of an actual helper replacement separately from a connection command handled by the surviving helper.

FINDING: F-02
KIND: judgement
SEVERITY: should-fix
WHERE: Context / Owner summary:53-57; Design / Migration, performance and release boundaries:565-578; Acceptance Criteria / AC-21; Test Plan / AC-21; Tasks / T16, T22, T26, T29; Sources / Q31, Q34
EVIDENCE: The revision addressing R-17 F-01 narrows the guarantee to never launching a mixed build, but specifies only checking an executable before launching it. Replacement between those operations remains undefined. An isolated Linux probe hashed a temporary copy of /usr/bin/true, replaced its pathname with /usr/bin/false, then launched that pathname. It observed checked_original_file=True, pathname_changed_after_check=True and launched_exit_status=1. Current launch paths likewise execute by pathname at BundledPluginTunnel.swift:87-93 and RemoteSSHBridge.swift:174-184. AC-21 pauses replacement before actions begin, so it does not exercise this interleaving.
PROPOSAL: Define how execution remains bound to the validated file during concurrent package replacement, raising the mechanism or guarantee change as an Open Question. Add scenarios that replace the helper or plugin after validation but before execution, including the independent editor proxy path.

FINDING: F-03
KIND: judgement
SEVERITY: should-fix
WHERE: AGENTS.md:27-32; Context / Owner summary:75-79; Scope / macOS behavior preservation; Design / AWS client:386-388; Design / Behavior, identity and local state:444-451; Acceptance Criteria / AC-20, AC-25; Test Plan / AC-20, AC-25; Tasks / T12, T13, T27; Sources / Q11
EVIDENCE: Repository instructions require preserving existing macOS behavior with three named AWS-client exceptions. Design and AC-25 additionally require refusing a missing plugin before any AWS call on macOS. Today's ConnectionStateMachine.swift authenticates at lines 304-312, can start the instance at lines 347-358, and requests an SSM session at lines 419-426 before BundledPluginTunnel.swift:56-64 detects the missing plugin. The proposed preflight therefore changes remote side effects and failure behavior beyond the three declared exceptions. The preservation contract and preflight requirement cannot both describe that case.
PROPOSAL: Raise an Open Question deciding whether early capability refusal is an additional authorized macOS behavior change. Reconcile AGENTS.md, the preservation clauses, AC-20 and the preflight proofs with the owner's decision.

### R-19

FINDING: F-01
KIND: judgement
SEVERITY: should-fix
WHERE: Context / Owner summary:53-57; Design / Migration, performance and release boundaries:569-585; Test Plan / AC-21; Tasks / T22, T29; Sources / Q29, Q31, Q34
EVIDENCE: Design requires every new action launching a file to refuse after a completed Linux upgrade, but specifies executable build checks and the bundled plugin's expected hash. An upgrade can retain the same upstream plugin bytes. The running old helper then passes the plugin hash check and can start another connection without launching the replaced helper or proxy. The existing plugin is independently pinned at scripts/fetch-plugin.sh:18-24; no requirement makes its bytes change with each application release. AC-21 nevertheless requires this connection to refuse without launching anything or calling AWS. The persistent-helper correction addressing R-18 F-01 resolves the partial-upgrade scenario but leaves this completed-upgrade case unresolved.
PROPOSAL: Define how completed upgrades are detected when the bundled plugin remains identical, or raise an Open Question narrowing the refusal policy. Add a native upgrade scenario whose two application builds contain the same plugin.

FINDING: F-02
KIND: factual
SEVERITY: should-fix
WHERE: Context / Owner summary:53-57; Design / Migration, performance and release boundaries:569-583; Test Plan / AC-21, no-mixed-build assertion; Sources / Q34, Q36
EVIDENCE: The summary promises that the running Linux app never starts a file from a different build, and Design says a partial install never starts a mixed build. Lines 579-583 explicitly permit a plugin replaced between validation and execution to run the newer bundled plugin. That exception, introduced in response to R-18 F-02 and recorded as Q36, permits the behavior the blanket guarantees prohibit. The owner summary therefore overstates the selected protection.
PROPOSAL: State the already selected plugin race exception in the owner summary and qualify the unconditional no-mixed-build clauses. Make the corresponding AC-21 assertion explicitly distinguish replacement detected before launch from the accepted check-to-start race.

### R-20

NO FINDINGS

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
  named comparison hosts (Q15); after T3 found no Windows support upstream, one
  SSM Connect AWS client on every platform, macOS switched last (replacing Q5);
  a fixed SDK-default retry policy (Q21); the STS identity request moved into
  the client (Q22); configured endpoints ignored too, with both differences
  recorded as exceptions in `AGENTS.md` and AC-20 (Q23); the STS request kept at
  one attempt (Q24); today's editor proxy cleanup kept (Q25); one release created
  before platform jobs that attach their own assets (Q26); STS on the client's
  resolver with the China correction as a third exception (Q27); published
  assets never change (Q28); a running Linux client keeps its connections but
  refuses new actions after an upgrade or removal (Q29); the editor proxy refuses
  new channels the same way (Q30); launches check the exact executable's build
  (Q31); uninstall keeps user data (Q32); only the macOS job marks a release
  latest (Q33); the Linux rule narrowed to never launching a mixed build (Q34);
  the latest step serialized in a queued concurrency group (Q35); the
  check-to-start race accepted where the handshake and proxy self-check catch it
  (Q36); the preflight applied on macOS as a fourth exception (Q37); the same failure rules for every helper with
  Cancel bounding a stall (Q16); helper-owned editor leases (Q17); asking before
  closing on Windows and running until quit on Linux during installs (Q18); the
Linux helper unit bound to the shell's systemd scope (Q19); a failed Linux
install repaired by reinstalling with dnf or apt (Q20).
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
