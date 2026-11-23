---
status: in-progress
status_description: "Implementing the accepted parity revision on feat/shared-swift-core: T50 to T52 (DCV window, AC-30) first, then T53 to T62 (macOS parity in the Windows and Linux shells, AC-29); T1, T2, T30 and T31 wait for the Mac baseline."
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
  - spikes/helper-feasibility/
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
build. The client also corrects a skewed local clock the way the SDK does,
learning a per-host offset from the server's `Date` header, for every request
the SDK sends today. This revision adds that after the T5 live run showed a
machine with a 9-hour clock error failing. The direct STS identity request keeps
today's behavior and still fails under such an error, as it does in today's app.

Progress is recorded in Tasks. The AWS client, the helper, both shells, the
adapters, the extraction and the packages are built (T4 to T26, T32 to T49), and
native acceptance has run on Windows 11, Fedora 43 and Ubuntu 24.04 (T28, T29),
finding and fixing defects along the way. No acceptance criterion is ticked yet.

This revision adds two owner decisions from that native acceptance
(2026-11-22). First, the Windows and Linux shells offer every user action and
setting the macOS menu, settings window and profile editor offer, not the
smaller set they have today. Each runs the shared workflow through a helper
command and keeps macOS's confirmations and availability rules. Controls that
interrupt work in progress, such as Cancel Recovery and Stop Remote Access,
cancel the running command, as Disconnect does (owner decision). A committed
inventory lists every macOS control with its helper command and its Windows and
Linux control, and tests on each platform fail when one is missing. Second, on
Windows and Linux the DCV connection file stays on disk for 120 seconds after
the Viewer is asked to open it, instead of 5: a cold Viewer start on Ubuntu took
about 70 seconds and found the file already gone. Connect does not wait for that
window, and the file is removed at Quit, and after a crash by a later connect's
sweep once its window has passed, both new in the helper. macOS keeps its 5 seconds unchanged, so its connect
timing and the four named exceptions to preserving macOS behavior stay as they
are (owner decision). The missing-Viewer message also stops naming the macOS
install path on Windows and Linux.

This draft replaces the old two-core scope; its historical acceptance and
passing tests do not carry over. Each task runs under the authority the owner
gives for it; the live AWS runs of T5 used the owner's own profile with their
approval. Installing or replacing the app, running workstation operations
beyond T5's read-only checks and port forward, and releasing still need separate
approval.

### Harm and the simplest alternative

The harm is observed, constant and does not resolve without work: SSM Connect
runs only on macOS, so the owner and colleagues on Windows 11 and Linux reach
the workstation through hand-assembled AWS CLI, Session Manager plugin, SSH and
DCV steps, or not at all. Every connection then repeats manual SSO sign-in,
instance lookup, port forwarding and editor and browser setup that the macOS app
does in one action, and each step can be skipped or done insecurely (for
example a long-lived SSH key, or a browser whose proxy setting routes all
traffic). The simplest alternative without new machinery is to document those
CLI steps per platform, or to keep the earlier separate C# core. Documentation
leaves every user to repeat and secure the steps by hand. A second core
duplicates every authorization, recovery and consent rule and has already
diverged from the macOS features added since August. One shared Swift core
behind native shells gives Windows and Linux the same behavior with one
implementation to keep correct, which is why this design is preferred.

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

At the pre-extraction baseline (`eb4f0bc`), the
[package manifest](../../SSMConnectKit/Package.swift) built one umbrella target,
and OS responsibilities were mixed into orchestration (both files have since
moved into the extracted targets that T7 to T13 record):
`SSMConnectKit/Sources/SSMConnectKit/StateMachine/ConnectionStateMachine.swift:1`
imported Darwin and owned shutdown signals;
`SSMConnectKit/Sources/SSMConnectKit/Auth/AWSAuthProvider.swift:1` imported AppKit
and opened the browser. These were boundaries to refactor, not a reason to translate
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
- Supply Windows and Linux interfaces backed by that same Swift core, offering
  every user action and setting of the macOS menu, settings window and profile
  editor (owner decision, 2026-11-22).
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

It also corrects a skewed local clock as the SDK does
(aws-sdk-swift `AWSClockSkewProvider`, smithy-swift `ClockSkewStore`). When a
signed request fails with `RequestTimeTooSkewed`, `RequestExpired` or
`RequestInTheFuture`, or with `AuthFailure`, `SignatureDoesNotMatch` or
`InvalidSignatureException`, the client compares the unadjusted local time taken
when it signed (not the offset signing time) with the response's `Date` header.
The result for that host follows the SDK's transitions: a difference over 300
seconds becomes the stored offset, unless one is stored and the new difference is
within 60 seconds of it, which keeps the stored one; a difference of 300 seconds
or less, or a missing or unparseable `Date` header, clears a stored offset. Any
other error leaves the stored value as it is. The store is process-wide, and each
host's comparison, update and "changed" result happen as one atomic step, so of
several requests that fail with the same skew at once, only the first sees a
change. Requests to a host are signed at the local time plus its stored offset,
and when a skew error changed the stored value (set, replaced or cleared) the
failed request is retried under the fixed policy, counting as an attempt and
waiting its backoff; otherwise the error is handled by the usual retry rules. The T5
live run met this case: a Windows machine with its clock 9 hours fast had every
signed request rejected with `AuthFailure`. The SDK-based app would correct and
retry its SDK requests; its direct STS identity request, sent first in that run,
would still fail, as it does today.

Retries also draw on a retry quota as the SDK's do (smithy-swift
`DefaultRetryStrategy`, `RetryQuota`, `RetryQuotaRepository`). Each client
instance holds one quota per service and region, as each SDK client holds one per
`<ClientName> - <region>`: capacity 500; a retry costs 5, or 10 after a timeout;
a successful call returns the cost of its last retry, or 1 when it made no retry,
capped at 500; a retry, including a clock-skew retry, that the remaining capacity
cannot cover is not made and the error is returned. Code that reuses one client,
as device-code polling does today, therefore shares its quota across calls.

The STS identity request keeps its current single attempt inside the client:
it is never retried and fails on any non-success response, as today's direct
path does (`SSMConnectKit/Sources/SSMConnectKit/Auth/STSIdentityResolver.swift:16-22`).
It takes its endpoint from the client's resolver like every other request, and,
as today, takes no part in clock-skew correction.
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

### Windows and Linux parity with the macOS interface

The owner decided on 2026-11-22 that the Windows and Linux shells offer every
user action and setting the macOS interface offers. Today they offer a subset:
the tray sends sign-in, connect, disconnect, stop workstation, open VS Code,
start and stop web forwards and open browser
(`linux/src/shell_controller.cpp:27-38`,
`windows/src/SSMConnect.App/Shell/ShellController.cs:57-67`), and the settings
window edits the name, SSO, account, role, region, tag and port fields with
Save, Use This Profile, Import and Set Up VS Code (`linux/qml/Settings.qml:95-107`,
`windows/src/SSMConnect.App/Shell/SettingsWindow.cs`). The helper has no command
for the rest (`SSMConnectKit/Sources/SSMConnectHelperCore/HelperRuntime.swift:146-168`).

The macOS surfaces are `SSMConnectKit/Sources/SSMConnectUI/MenuContentView.swift`,
`SettingsView.swift`, `ProfileEditorView.swift`, `LogView.swift` and
`AboutView.swift`. Their controls fall into these groups:

- **Connection:** Retry Authorization, the pending-changes and connection detail
  lines, the masked password with Copy Password, Reconnect, the Stop Workstation
  confirmation, and Set Up a Workstation when no profile exists
  (`MenuContentView.swift:48-103`).
- **Editor:** Open VS Code with its consent to add the SSH Include on first
  use, Reconnect Existing Workspace, Renew Editor Access, Cancel Recovery, Review Replacement
  Workstation with its confirmation, Cancel Replacement Recovery, the lease and
  recovery lines, the VS Code browser routing notes, Stop Remote Access and
  Restore Editor Setup, each with macOS's confirmation text
  (`MenuContentView.swift:105-178`).
- **Web forwards:** the state line, Turn On and Turn Off Web Forwards, Review
  Forwarding Replacement, Cancel Forwarding Recovery, Open for each local forward,
  Open Browser with its Separate Browser or Use My Browser choice, the Advanced items (Copy PAC
  URL, Reveal PAC File, Apply Browser Setup, Restore Browser Settings) and Apply
  Changes (`MenuContentView.swift:181-260`).
- **Settings:** connect automatically on launch, reconnect automatically,
  clipboard auto-clear seconds, add a blank profile, import from
  `~/.aws/config`, duplicate, delete (disabled while one profile is left; the
  first remaining profile becomes active when the active one goes,
  `SSMConnectWorkflow/ProfileStore.swift:122-133`), and the Files and attachment
  actions: Open Profile File, Export Profile, Save a Local Copy, Reload / Review
  Changes, Apply External Changes, Locate File and Detach
  (`SettingsView.swift:41-193`).
- **Profile editor:** every field of `ConnectionProfile`, including the DCV
  password secret, Open DCV Viewer automatically, connect mode, remote
  development with its remote folder, and web forwards with SSH user, SOCKS port,
  browser, browser mode, proxy suffixes and local forwards, with the same
  validation messages (`ProfileEditorView.swift:43-313`).
- **Log and About:** the connection log with Clear, and the About window.

`contracts/macos-parity.json` lists each control once with its macOS file and
symbol, the helper command it sends (or `shell` for presentation only, such as
opening the About or Log window) and the Windows and Linux control that offers
it. A check that reads the macOS views lists every control they declare (each
`Button`, `Toggle`, `Picker`, `Stepper`, `Menu`, `TextField`, `SecureField`,
`SettingsLink`, `Link`, `DisclosureGroup` and alert button, with its title or
title expression) and fails on a control type it does not know, so a new kind of
control cannot slip past it, and on a control with no inventory entry. It is
shown failing first by removing the clipboard auto-clear entry and by adding an
unlisted control to a copy of a view. A Swift test checks that every listed command is in the helper's command
table; the Windows xUnit and Linux Qt drive-through tests check that every
listed control exists and sends its command, with macOS's confirmation shown
first where macOS asks. A control added to the macOS views without an entry, or
an entry without its command or controls, fails those tests.

Each inventory entry also records when macOS offers the control and when it is
enabled, as the views decide it (for example Stop Workstation only while
connected, `MenuContentView.swift:94-103`; Reconnect Existing Workspace disabled
while opening and Cancel Recovery only while recovering, lines 117-122). The
shells show and enable each control from the workflow states the helper streams,
and a control that is not available cannot send its command.

Some macOS controls interrupt work in progress: Disconnect during a connect,
Cancel Recovery, Cancel Replacement Recovery, Cancel Forwarding Recovery, Stop
Remote Access and Restore Editor Setup. The helper runs one command per workflow
and refuses a second one as busy (`SSMConnectHelperProtocol/HelperSession.swift:108-110`),
so these controls use the protocol's cancel for the running command, as
Disconnect does since 8efc7dd (owner decision, 2026-11-22). When a command of
their workflow is running, the cancel controls send `cancel` for it; Stop Remote
Access and Restore Editor Setup cancel a running editor command first and then
run as their own command. Some of the work these controls end outlives any
command: a replacement waiting for review stays after Open VS Code has finished
(`SSMConnectWorkflow/RemoteDevelopmentStateMachine.swift:378-382`), and automatic
editor recovery starts on its own after the opening command ends (lines 412-439),
while a cancel frame only reaches a running command
(`SSMConnectHelperProtocol/HelperSession.swift:78-79`). With no command of their
workflow running, the controls therefore send a command that calls the
workflow's own cancellation, as macOS does: `cancelEditorRecovery` (Cancel
Recovery and Cancel Replacement Recovery, `remoteDevelopment.cancelRecovery()`),
`cancelForwardingRecovery` (`webForwards.stop()`), and Stop Remote Access and
Restore Editor Setup as themselves. This is how Disconnect already behaves: it
cancels a running Connect, and otherwise sends `disconnect`.

The command can finish in the helper while the shell's cancel is on its way: the
helper removes a command before it sends the result
(`HelperSession.swift:140-142`) and ignores a cancel for a command it no longer
runs (lines 78-79). So when the shell has sent `cancel` and the result that
arrives is not `cancelled`, it sends the control's no-command form once, which
ends whatever the finished command left running, such as a replacement waiting
for review. The original command is never sent again, and the follow-up runs
under the same admission rules as any other command. The helper's cancel ends what the command started
and sends the workflow's resulting state before the command's one cancelled
result. The inventory marks these entries as cancel-type, naming the workflow
whose running command they cancel and the command they send otherwise; the
command-table check requires that command.

Every new command runs the same shared workflow macOS calls, under the
existing admission rules: one command per workflow at a time, a command that
conflicts with the current state refused before any side effect, and exactly
one terminal result (AC-27). Profile and settings commands share the
`profiles` workflow, so a delete cannot race a save. Deleting a profile removes
its attachment record but never the attached file, as on macOS. Shell-side
requests the commands need already exist: clipboard, open URL and launch
(`SSMConnectHelperCore/ShellRequests.swift:9-28`); revealing the PAC file adds a `reveal` request
that the shell serves with the platform file manager. Shell and helper always
share a build (the handshake refuses any other), so no command reaches a helper
that lacks it, and rolling back installs an older shell and helper together.

### DCV connection file lifetime

SSM Connect deletes the DCV connection file 5 seconds after asking the Viewer to
open it, on macOS (`SSMConnectMacOS/DCVLauncher.swift:15-57`) and in the helper
(`SSMConnectHelperCore/ShellRequests.swift:47-72`). On ubuntu-sandbox the first
Viewer start in a fresh session took about 70 seconds and found no file (T29).
On Windows and Linux the window becomes 120 seconds (owner decision,
2026-11-22). The helper already schedules the deletion on its own task and
reports the connect at once, so Connect does not wait for the window. The file
stays `0600` in the user's own folder during the window. Two cleanup paths are
new work in this revision, because the helper has neither today: its delayed
deletion is the only removal (`SSMConnectHelperCore/ShellRequests.swift:60-77`),
its quit work runs the registered quit handlers, which clean up the desktop
tunnel, editor and forwarding resources but no waiting DCV file
(`SSMConnectHelperCore/HelperRuntime.swift:422-424`,
`SSMConnectWorkflow/ConnectionStateMachine.swift:131-140`,
`RemoteDevelopmentStateMachine.swift:83`, `WebForwardsStateMachine.swift:65`), and the orphan sweep
runs only from the macOS launch hook (`ConnectionStateMachine.swift:170-172`).
The helper's quit work removes any file still waiting, and the helper's connect
first sweeps connection files it is not itself keeping and whose modification
time is more than 120 seconds old. The helper keeps the names of its own files
until their windows end, so a clock correction cannot make the sweep delete one
early, and a killed helper's leftovers are removed by a later connect. macOS keeps its 5 seconds: its launcher waits for
the window before Connected (`SSMConnectMacOS/DCVLauncher.swift:55-57`,
`SSMConnectWorkflow/ConnectionStateMachine.swift:380-395`), and its behavior
stays within the four named preservation exceptions. The missing-Viewer message comes from
the shared workflow and names the macOS path on every platform
(`SSMConnectWorkflow/DCVLaunching.swift:22`). Windows and Linux name their own
install instead; macOS keeps its message.

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
- [ ] AC-28: Every client reaches AWS through the one SSM Connect AWS client, no shipped artifact contains aws-sdk-swift or aws-crt-swift, and each SDK operation the app uses sends the same requests, retries the same failures, corrects a skewed clock the same way and yields the same user-facing errors as the current SDK-based app with no retry settings configured; the STS identity request sends the same request as today's direct path, except that in China regions it goes to the resolver's `amazonaws.com.cn` host, and keeps its single attempt.
- [ ] AC-29: On Windows and Linux, every user action and setting of the macOS menu, settings window and profile editor is offered by the shell, runs the shared workflow through a helper command, and keeps macOS's confirmations and availability rules; controls that interrupt work in progress cancel the running command of their workflow; and the parity inventory lists none as missing.
- [ ] AC-30: On Windows and Linux the DCV connection file stays readable for 120 seconds after the Viewer is asked to open it, without delaying Connected, and is removed at the end of that window, at Quit, or after a crash by the sweep of a later connect once its window has passed; a Viewer that takes up to that long to start opens the desktop; the missing-Viewer message names the platform's own install; and macOS keeps its current window and message.

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
| AC-28 | Signing tests pass the published Signature Version 4 test suite on macOS, Linux and Windows. For each of the 11 SDK operations, fixtures recorded from the current SDK-based app through a local recording endpoint (requests, a success response, a throttling response and each service error the app translates) show the client sending equivalent requests to the same endpoint, retrying the same responses the same number of times, and producing the same typed error and message. Under a controlled clock, with no retry settings configured, the delays between attempts match the pinned SDK's retry strategy options; closed connections, HTTP timeouts and transient transport failures are retried as the SDK's retry classifier retries them; and cancelling during a backoff wait ends the call without another attempt; the existing error-translation tests pass on the client. Separately, without an endpoint override, the SDK's endpoint resolver and the client's give the same production endpoint for every service in standard, China and GovCloud regions. With `AWS_MAX_ATTEMPTS`, `AWS_RETRY_MODE`, `AWS_NEW_RETRIES_2026` or a shared-config retry setting present, the client's attempts and delays are unchanged; with `AWS_ENDPOINT_URL`, a service-specific endpoint variable or a shared-config endpoint present, every request still goes to the resolver's regional endpoint. The STS identity request makes exactly one attempt: a throttling, 5xx or access-denied response fails at once with the same typed error as today. Outside China, the STS identity request recorded from today's direct path matches the client's request byte for byte after signing with the same time; in China regions it goes to the resolver's `amazonaws.com.cn` host. Each of the 12 requests succeeds once against AWS natively on every matrix target. Inspecting every built artifact and the resolved package graph finds no aws-sdk-swift, aws-crt-swift or Smithy module. Fixtures recorded from the SDK show the clock-skew behavior: a signed request answered with `AuthFailure` or `RequestTimeTooSkewed` and a `Date` header 9 hours ahead is retried once, signed at local time plus that offset, and succeeds; a 4-minute difference is not corrected. Controlled-clock client tests check the offset is computed from the unadjusted local time and applied to later requests to that host only, the 300-second and 60-second thresholds, that a skew error with a near, missing or unparseable `Date` header clears a stored offset and retries once (a client whose local clock was repaired after an offset was learned recovers), a retry only when the stored value changed, that the retry counts as an attempt and waits its backoff, that a non-skew error with a far-off `Date` header is not treated as skew, and that two requests failing with the same skew at the same time yield one skew retry, as the SDK's store does. Retry-quota tests on one reused client check that 100 failed retries exhaust the 500 capacity so the next retryable failure is returned without a retry, that a timeout retry costs 10, that a success returns its retry's cost or 1, and that a clock-skew retry is refused when the quota is exhausted, matching recorded SDK behavior on a reused client. |
| AC-29 | The view-reading check fails for the removed clipboard auto-clear entry, for an unlisted control added to a copy of a view and for an unknown control type, then passes on the real views. `contracts/macos-parity.json` is then checked three ways: a Swift test that every listed helper command is in the command table, and Windows xUnit and Linux Qt drive-throughs that operate every listed control and assert its command frame and, where macOS asks, the confirmation shown first; in disconnected, connecting, connected and recovering states they assert each control's visibility and enabled state from the inventory and that an unavailable control sends nothing; and for each cancel-type control, with its workflow's command running, they assert one cancel frame for that command, its cancelled result after the resulting state, and an unrelated workflow left running. Helper command tests with fake services also cover the states that outlive a command: with a replacement waiting for review after Open VS Code finished, and with automatic editor recovery running with no command, Cancel Replacement Recovery and Cancel Recovery send `cancelEditorRecovery`, which leaves the editor workflow idle with no replacement or recovery pending, and web forwards and the desktop keep running; Cancel Forwarding Recovery does the same for web forwards. A shell test with the fake helper delays the result of a running Open VS Code until after the cancel frame and returns it as completed with a replacement pending: the shell sends `cancelEditorRecovery` once, the replacement clears, Open VS Code is not sent again, and the desktop workflow is untouched. Helper command tests with fake services cover each new command's macOS rules, including delete refused for the last profile, the active profile moving to the first remaining one, and the attached file left untouched. A native pass on w11-sandbox, Fedora 43 and Ubuntu 24.04 exercises each new control once against the owner's profile. |
| AC-30 | Helper tests with an injected delay: the default window is 120 seconds, connect reports connected while the file still exists, the file is gone after the window, stdin EOF through `HelperExit` removes a waiting file before the 120-second timer, a connect through the helper's command removes a leftover file older than the window that a killed helper left, two connects 10 seconds apart leave the first file in place until its own deadline, and with the system clock moved five minutes forward between them the first file still stays until its deadline. A message test for the missing Viewer on Windows and on Linux, and the existing macOS launcher and message tests unchanged. Natively on ubuntu-sandbox, after logging the session out and back in so the Viewer starts cold, Connect opens the desktop with no copied file. |

## Tasks

Increment 1 measures the baseline, builds the AWS client and proves it with the
helper natively before broad extraction, as Design requires. T3 was dropped when
the SDK route proved blocked; its finding is in Context. T34 was split into
T37-T40, one per kind of parity evidence. Tasks that need live AWS, a native
host or an installed app run only under the owner's authority for that task.

- [ ] T1 `scripts/perf/measure.sh`, `scripts/perf/README.md` - measurement harness implementing the Design method (app process set, one warm-up and ten runs, medians, five settled minutes, 60 one-second idle samples, host and OS build header) for macOS, Windows and Linux; done: a run on the baseline Mac prints all five metrics under the host header (AC-22)
      Progress: harness committed; `scripts/perf/measure.sh scripts/perf/workloads/selftest.env` on fedora-43 gave startup 325, ui 164, cold 272, warm 223 ms against fake delays of 300, 100, 200, 200, and `--dry-run` with `workloads/macos.env` loaded on MacBook-Pro (macOS 26.6.2, app 0.7.0). The baseline-Mac run is pending: it needs v0.7.1 installed, a quiet Mac, Accessibility permission for the measuring process and a profile with a valid SSO session.
- [ ] T2 `docs/specs/cross-platform-client.spec.md` - record the named comparison hosts and the current macOS release baseline from T1 as an annotation under this task; done: the annotation names the Mac, Windows and Linux hosts with OS builds, the workload and every median (AC-22)
The AWS client lives in its own Foundation-only package, `SSMConnectKit/AWSClient`, so its tests run on Linux and Windows before the extraction tasks make the main package portable; SwiftPM on Linux builds every test target of a package into one bundle, and `SSMConnectKitTests` imports AppKit.

- [x] T32 `SSMConnectKit/AWSClient/Package.swift`, `SSMConnectKit/AWSClient/Tests/SSMConnectAWSClientTests/SigV4Tests.swift` - failing tests built from the published Signature Version 4 test suite and the existing STS presign cases; done: they fail because the signer does not exist (AC-28)
      Evidence: `swift test` in swift:6.4.2-noble (Linux x86-64) on SSMConnectKit/AWSClient, 2026-11-18: the build fails with `cannot find type 'SigV4' in scope` and `cannot find type 'AWSCredentialSet' in scope`, the stated reason. The 38 vectors are vendored from aws-c-auth cf69fb7 with its Apache-2.0 license.
- [x] T33 `SSMConnectKit/AWSClient/Sources/SSMConnectAWSClient/SigV4.swift` - the signer, used by the STS presign as well; done: T32 and the existing STS tests pass on macOS, Linux and Windows CI runners (AC-28)
      Evidence: `swift test` on SSMConnectKit/AWSClient passes all 4 tests (38 header and 38 query vectors, the STS known answer, suite presence) on Linux x86-64 (swift:6.4.2-noble, local), MacBook-Pro (macOS 26.6.2, Apple Swift 6.4, local) and the `aws-client` jobs of run https://github.com/vhco-pro/ssm-connect/actions/runs/44688246120 on windows-2025 (vs2026 image 20261116), ubuntu-24.04 and macos-15 at 6a94518; `swift test --package-path SSMConnectKit` on the Mac passes 298 tests in 36 suites with `STSPresigner` delegating to the signer. Windows needs `-D_ALLOW_COMPILER_AND_STL_VERSION_MISMATCH` because that image's MSVC STL requires Clang 22 and Swift 6.4.2 ships Clang 21; the vendored vectors needed `-text` to stay byte-exact on Windows checkouts.
- [x] T37 `SSMConnectKit/Tools/FixtureRecorder/`, `SSMConnectKit/AWSClient/Tests/SSMConnectAWSClientTests/Fixtures/endpoints.json`, `SSMConnectKit/AWSClient/Tests/SSMConnectAWSClientTests/EndpointParityTests.swift` - a recorder executable on the pinned aws-sdk-swift that writes each client's resolver output, without an override, for SSO OIDC, SSO, EC2, Systems Manager, Secrets Manager, EC2 Instance Connect and STS in standard, China and GovCloud regions, and failing tests that compare the client's resolver with it and check that endpoint settings in the environment and shared config change nothing; done: the tests fail because the client has no resolver (AC-28)
      Evidence: `FixtureRecorder endpoints` (aws-sdk-swift 1.7.62, built with `--build-system native` in swift:6.4.2 with libssl-dev, Linux x86-64) wrote 98 resolutions for 7 services and 14 regions, all https: China on `amazonaws.com.cn`, GovCloud and standard on `amazonaws.com`. `swift test` on SSMConnectKit/AWSClient then fails with `cannot find 'AWSEndpoints' in scope` and `cannot find type 'AWSService' in scope`, the stated reason, 2026-11-20.
- [x] T38 `SSMConnectKit/Tools/FixtureRecorder/`, `SSMConnectKit/AWSClient/Tests/SSMConnectAWSClientTests/Fixtures/requests/`, `SSMConnectKit/AWSClient/Tests/SSMConnectAWSClientTests/RequestParityTests.swift` - record, through a local endpoint, the request each of the 11 SDK operations sends and the STS identity request from today's direct path, with a success response for each, and write failing tests that the client sends equivalent requests (the China STS host excepted) and decodes those responses to the same values; done: the tests fail because the client has no operations (AC-28)
      Evidence: `FixtureRecorder requests` (aws-sdk-swift 1.7.62, Linux x86-64) recorded 14 cases (four SSO OIDC, SSO GetRoleCredentials, four EC2, three SSM, Secrets Manager, EC2 Instance Connect) with the app's inputs; the STS case asserts the presigned GET URL STSPresignerTests pins today. Building the tests then fails with `cannot find type 'AWSClient'`, `'HTTPTransport'`, `'HTTPRequest'`, `'HTTPResponse'`, `'SSOToken'`, `'InstanceSummary'` and `'SessionStart'`, the stated reason, 2026-11-20 (checked in a copy without EndpointParityTests, whose missing resolver otherwise stops the build first).
- [x] T39 `SSMConnectKit/Tools/FixtureRecorder/`, `SSMConnectKit/AWSClient/Tests/SSMConnectAWSClientTests/Fixtures/retries/`, `SSMConnectKit/AWSClient/Tests/SSMConnectAWSClientTests/RetryParityTests.swift` - record the SDK's attempts for throttling, 5xx, closed-connection, timeout and transient transport failures with nothing configured, derive its backoff bounds from the pinned retry strategy options, and write failing controlled-clock tests for attempt counts, delays, retry settings in the environment and shared config changing nothing, cancellation during backoff, and the STS request's single attempt; done: the tests fail because the client has no retry policy (AC-28)
      Evidence: `FixtureRecorder retries` (aws-sdk-swift 1.7.62, Linux, no AWS_* variables) recorded 14 scenarios: throttling, 500, 503, 408, RequestLimitExceeded, InternalError and a dropped connection retried, at most 3 attempts, first delays 0.18-0.99 s and second delays 1.17-1.64 s, within random()*2^n; a 5000 ms x-amz-retry-after ignored (0.19 s); AccessDenied, UnauthorizedOperation, SlowDown and AuthorizationPending not retried. The bounds come from smithy-swift 0.242.0 DefaultRetryStrategy, ExponentialBackoffStrategy (r = 2, max 20 s) and AWSRetryErrorInfoProvider. Building the tests then fails with `cannot find type 'AWSClient'`, `'HTTPTransport'`, `'HTTPRequest'` and `'HTTPResponse'`, the stated reason, 2026-11-20.
- [x] T40 `SSMConnectKit/Tools/FixtureRecorder/`, `SSMConnectKit/AWSClient/Tests/SSMConnectAWSClientTests/Fixtures/errors/`, `SSMConnectKit/AWSClient/Tests/SSMConnectAWSClientTests/ErrorParityTests.swift` - on macOS, record the typed error and message the app's current translation produces for each service error the app translates, per operation, and write failing tests that the client's errors translate to the same; done: the tests fail because the client has no error results (AC-28)
      Evidence: the recorder lives in the main package as `SSMConnectKit/Tests/SSMConnectKitTests/Support/ErrorFixtureRecording.swift`, because the translation is internal to that macOS-only package; it runs only with SSM_ERROR_FIXTURES set and uses a stub SDK HTTP engine. On MacBook-Pro (macOS 26.6.2, Apple Swift 6.4) it recorded 27 errors across all six services, 2026-11-20: SSO OIDC errors carry no message, EC2 Instance Connect reports `Forbidden` and `EC2InstanceNotFound`, unmodeled errors arrive as UnknownAWSHTTPServiceError with type name, message and status. The full suite then passes 299 tests in 37 suites with the recorder skipped. ErrorParityTests fails to build with `cannot find type 'AWSClient'`, the stated reason.
- [x] T35 `SSMConnectKit/AWSClient/Sources/SSMConnectAWSClient/` - the client: REST JSON, EC2 Query, AWS Query and AWS JSON 1.1 encoding, endpoint resolution, the fixed retry policy and error results for the 12 requests, with `STSIdentityResolver` moved onto it; done: T37-T40 pass on macOS, Linux and Windows CI runners (AC-28)
      Evidence: `swift test` on SSMConnectKit/AWSClient passes 21 tests in 5 suites (98 endpoints and 98 configured-endpoint cases, 14 requests, 14 retry scenarios plus bounds, 27 errors, 76 SigV4 vectors, STS direct path, China host and single attempt, cancellation, transport classification) in swift:6.4.2-noble on Linux and in the `aws-client` jobs of https://github.com/vhco-pro/ssm-connect/actions/runs/44824516033 on windows-2025, ubuntu-24.04 and macos-15 at 86bfb71, 2026-11-20.
      Correction (R-24 F-01): the main package's `STSIdentityResolver` still sends through its own URLSession and `STSPresigner` keeps the hardcoded `amazonaws.com` host; only signing delegates to the client. Moving the production resolver is T46.
- [x] T41 `SSMConnectKit/AWSClient/Sources/SSMConnectAWSClient/HTTP.swift`, `SSMConnectKit/AWSClient/Tests/SSMConnectAWSClientTests/TransportTests.swift` - share one process-wide ephemeral URLSession across transports, after the T5 helper crashed on Linux in FoundationNetworking (`_MultiHandle deallocated with non-zero retain count`) when per-client sessions were released mid-run; done: TransportTests fails first (`'session' is inaccessible`) and then passes with the full suite (AC-28)
      Evidence: `swift test` on SSMConnectKit/AWSClient in swift:6.4.2-noble, 2026-11-21: the new test failed to build before the change and the suite passed 22 tests in 6 suites after it. A 200-iteration loop of short-lived default clients did not reproduce the crash on its own, so the test pins the design rather than the race; the live T5 runs after the change completed on Linux and Windows.
- [x] T42 `SSMConnectKit/Tools/FixtureRecorder/`, `SSMConnectKit/AWSClient/Tests/SSMConnectAWSClientTests/Fixtures/skew/`, `SSMConnectKit/AWSClient/Tests/SSMConnectAWSClientTests/ClockSkewTests.swift` - record the SDK's response to skew errors with far-off and near `Date` headers (attempts, the retried request's signing time relative to local time, outcome), including a corrected client whose clock is then repaired and missing or invalid `Date` headers, and write failing controlled-clock tests for the per-host offset from unadjusted local time, both thresholds, clearing, retry only on a changed value, the retry counting as an attempt with backoff, non-skew errors ignored, and concurrent same-host failures yielding one skew retry; done: the tests fail because the client has no skew correction (AC-28)
  - Evidence: `FixtureRecorder skew` (aws-sdk-swift 1.7.62, native build backend) wrote 10 scenarios to `Fixtures/skew/`: far ahead and far behind `AuthFailure`, far `RequestExpired` and SSM `InvalidSignatureException` each retry once with the signing time moved by the server's offset; near (240 s), missing `Date` and a far `UnauthorizedOperation` make one attempt and fail; a learned offset is reused on the next call and cleared then retried once the clock is repaired; two concurrent failing calls make three attempts, one success and one error. With a temporary no-op `ClockSkewStore` (not committed) so the suite compiles, `swift test --filter ClockSkew` in `swift:6.4.2-noble` failed 25 issues across 7 of 8 tests: every skew scenario stops after its first `AuthFailure` ("Caught error: m (AuthFailure, HTTP 401)", attempt count 1 against the SDK's 2 to 4), because the client has no skew correction. The near, missing-`Date`, non-skew and 290 s cases already pass, as they assert no retry.
- [x] T45 `SSMConnectKit/Tools/FixtureRecorder/`, `SSMConnectKit/AWSClient/Tests/SSMConnectAWSClientTests/RetryQuotaTests.swift` - record the SDK's retry quota on one reused client (exhaustion after repeated failed retries, timeout cost, replenishment on success) and write failing quota tests, including a skew retry refused when exhausted; done: the tests fail because the client has no retry quota (AC-28)
  - Evidence: `FixtureRecorder quota` (aws-sdk-swift 1.7.62, stub HTTP engine, one reused EC2 client per scenario) wrote 5 scenarios to `Fixtures/quota/`: 50 calls failing with HTTP 500 make 3 attempts each and the 51st makes 1; 25 timing-out calls (`URLError.timedOut`) spend the same quota; 50 lost-connection calls cost the ordinary 5 per retry; after exhaustion 5 successes allow exactly one retry, a success after it refunds that retry, and the next failing call makes 2 attempts; a far `AuthFailure` after exhaustion makes 1 attempt. With the temporary no-op `ClockSkewStore` (not committed), `swift test --filter RetryQuota` in `swift:6.4.2-noble` failed the exhausted, timeout, lost-connection and refill scenarios and the per-client test ("Expectation failed: attempts == step.attempts"): calls keep retrying after the quota is spent, because the client has no retry quota. The skew-refused scenario passes for now only because the client makes no skew retry yet; it constrains T43's skew retry.
- [x] T43 `SSMConnectKit/AWSClient/Sources/SSMConnectAWSClient/` - the process-wide clock-skew store with atomic per-host updates, the signing offset and the corrected retry, and the per-client retry quota; done: T42, T45 and the rest of the client suite pass on macOS, Linux and Windows CI runners (AC-28)
  - Evidence: at 4d200df, `swift test` on SSMConnectKit/AWSClient in swift:6.4.2-noble passed 33 tests in 8 suites, the T42 skew parity and controlled-clock tests and the T45 quota tests included; the helper spike still built against it. GitHub Actions run 44898603627 (Swift portability spikes, push of 4d200df) passed the `aws-client` job on ubuntu-24.04, macos-15 and windows-2025. The same run's two Windows `portability` jobs failed compiling aws-crt-swift (`aws_test_harness.h`: undeclared `EXCEPTION_EXECUTE_HANDLER`, `GetConsoleMode`), as they did in run 44887308300 before this change: that spike builds the SDK itself on Windows, which this client replaces.
- [x] T44 `spikes/helper-feasibility/Sources/HelperSpike/main.swift`, `spikes/helper-feasibility/drive.py` - a `cancel` command that ends the action in progress (device-code polling or tunnel start) while further commands are read, and a tunnel check that sends a TLS ClientHello through the forwarded port and receives the workstation's ServerHello; done: rerunning T5 on Windows 11 and Fedora 43 records a ServerHello received through the tunnel and a cancelled sign-in poll and tunnel start, each reporting cancellation with no plugin left running (AC-23)
  - Evidence: 2026-11-21, `drive.py` against the owner's Identity Center profile on Fedora 43 x86-64 (11:30 UTC) and Windows 11 Pro 10.0.26300 x64 (11:40 UTC), same results on both. A first sign-in was started and cancelled while it polled: `cancelling`, then `cancelled` with no plugin running, and its code was never approved. After a tunnel opened, a TLS handshake through the forwarded port completed: ServerHello received, TLSv1.3 TLS_AES_256_GCM_SHA384, the workstation certificate with the same SHA-256 fingerprint on both platforms. A tunnel start cancelled right after its plugin started reported `cancelled` with no plugin running, and the driver found that plugin process gone. The first Fedora run exposed a hang on `quit`: `exit()` waited for the stdio lock that the stdin thread held in `readLine()`, so the driver timed out after `bye`; the helper now reads standard input through `FileHandle`, and with stdin still open it exits 0 straight after `bye`. Transcripts are kept outside the repository because they carry the owner's account identifiers.
- [x] T4 `spikes/helper-feasibility/` - a feasibility harness on the T35 AWS client and three reused portable types (`SSMSessionResponse`, `AWSRegion`, `IdentityMapper`), with its own SSO and plugin orchestration, speaking over stdin/stdout; it is subset evidence, not the final workflow integration; done: it builds natively on Windows 11 x64 and Fedora 43 x86-64 (AC-23, AC-28)
      Evidence: 2026-11-21. Windows 11 Pro 10.0.26300 x64 (w11-sandbox; Swift 6.4.3, Build Tools 2022 17.14 with MSVC 14.44, installed by PDS `Install-SwiftToolchain`, https://github.com/michielvha/PDS/pull/61): `run.ps1` built HelperSpike.exe natively, and it answered ready, an unknown command, `identity` before sign-in (`notSignedIn`) and `quit`. Fedora 43 x86-64: `run.sh` built it with `--static-swift-stdlib` in swift:6.4.2-noble on the Fedora host, and the binary ran natively on Fedora 43 (linking Fedora's libcurl and libxml2) with the same answers. The Linux build used the official container rather than a Fedora-packaged toolchain. Live AWS behaviour is T5.
- [x] T5 `docs/specs/cross-platform-client.spec.md` - run T4 on Windows 11 x64 and Fedora 43 and record exact Swift, AWS client commit and plugin versions, interactive SSO and refresh, an AWS response, usable SSM traffic, cancellation and owned-process cleanup as an annotation under this task; done: every item is recorded as observed (AC-23)
      Evidence: `spikes/helper-feasibility/drive.py` against the owner's Identity Center profile, 2026-11-21, the second device code of each run approved through auth-refresh's admin lane. Versions: AWS client at 4d200df (clock-skew correction and retry quota included), helper at 4f5bb88; Swift 6.4.2 for the Linux build (official container, `--static-swift-stdlib`, run natively on the Fedora host) and Swift 6.4.3 on Windows (native build, VS Build Tools 2022, MSVC 14.44); Session Manager plugin 1.2.814.0, AWS's published builds, hashed. Fedora 43 x86-64 at 11:30 UTC and Windows 11 Pro 10.0.26300 x64 at 11:40 UTC, same results: a sign-in poll cancelled with `cancelled` and no plugin; interactive SSO device authorization returned a token with a refresh token, then role credentials; STS identity resolved and mapped to the Linux username; DescribeInstances found the workstation by tag, running; StartSession plus the plugin opened a port forward within a second, and a TLS 1.3 handshake with the workstation completed through it (ServerHello received, the same certificate fingerprint on both platforms), which is SSM traffic reaching the workstation; the SSO token refresh returned new credentials; `stop` ended the plugin; a tunnel start cancelled after its plugin started left no plugin running; after `quit` with a tunnel open the plugin was gone and the helper exited 0. The earlier runs of this task found and fixed per-client URLSessions crashing on Linux (T41), an HTTP readiness probe (now a TCP connect), stdout writes trapping on a closed pipe on Windows, the missing clock-skew correction (T42, T43) and a hang on quit (T44). Not covered: the final workflow integration and packaged shells, which are later tasks; this is subset evidence.
- [x] T6 `scripts/check-boundaries.sh` - check that SSMConnectDomain and SSMConnectWorkflow sources import none of AppKit, SwiftUI, Darwin, ServiceManagement, UserNotifications or an AWS SDK module; done: it fails because those targets do not exist yet (AC-11)
  - Evidence: `scripts/check-boundaries.sh` exits 1 with "target SSMConnectDomain does not exist" and the same for SSMConnectWorkflow. Against a scratch tree it passed a Domain file importing Foundation and SSMConnectAWSClient (with `import AppKit` only in a comment) and flagged a Workflow file's `@preconcurrency import struct AppKit.NSImage`, `import Darwin` inside `#if canImport(Darwin)`, `@_spi(X) import AWSSSO` and `import SmithyHTTPAPI`, while leaving `import SwiftUIExtras` alone.
- [x] T7 `SSMConnectKit/Package.swift`, `SSMConnectKit/Sources/SSMConnectDomain/` - move models, validation, the profile codec and typed errors, re-exported by the umbrella; done: `swift test --package-path SSMConnectKit` and the Xcode app build pass, and T6 passes for Domain (AC-11, AC-20)
  - Evidence: 2026-11-21. SSMConnectDomain holds the former `Models/` files plus `AWSConfigParser`, `IdentityMapper`, `SSOToken`, `ProfileEditorValidation` and `ProfileDocumentCodec` (depending only on Yams), and the remote-folder rule as `RemoteFolder`, which `RemoteSSHConfiguration.folderURI` now calls with the same error. The umbrella re-exports the target (`Exports.swift`). Declarations that were internal are `package`, with explicit `package` memberwise initializers matching the synthesized ones, so nothing new became public. The target builds alone on Linux (swift:6.4.2-noble). `scripts/check-boundaries.sh` reports SSMConnectDomain ok, and still fails for the missing SSMConnectWorkflow. On MacBook-Pro (macOS 26.6.2), from a copy of the tree in /tmp: `swift test --package-path SSMConnectKit` passed 302 tests in 37 suites, and `scripts/release.sh` (XcodeGen 2.48.0 run from /tmp) built and verified the ad-hoc signed Release app and packaged it. The helper and portability spikes copy their files from the new paths and still build; the portability spike's `swiftc` call passes `-package-name`, and the portability workflow's path filter follows the move.
- [x] T8 `SSMConnectKit/Sources/SSMConnectWorkflow/` - move the connection, authorization and remote-development state machines and their retry and cancellation rules onto injected ports, moving Darwin signal handling and browser opening into macOS adapters; done: package tests pass and T6 passes (AC-11, AC-15, AC-20)
  - Evidence: 2026-11-21. SSMConnectWorkflow holds the connection, authorization, remote-development and web-forwards state machines, their service, tunnel, DCV, readiness, clipboard, notification and key-value ports with the mocks, the connection log, editor recovery, the SSH setup, lease and key types, private-file writes and the app launch and quit hooks. Each state machine's designated initializer takes a `WorkflowPlatform`: ending a child process at quit (the SIGTERM, 0.3 s, SIGKILL sequence), the SDK error text, the rejected-authorization, permission-denied and expired-credential checks, STS username and token, and `OwnerOnlyFiles` (owner and permission checks and the `fcntl` publication lock). The umbrella supplies `WorkflowPlatform.macOS` and keeps every previous initializer as a convenience initializer with the same defaults, so the app shell and tests construct the machines unchanged. The macOS pieces stay in the umbrella: `os.Logger` mirroring (`ConnectionLog.unified()`), `UNUserNotificationCenter`, the `NWConnection` and HTTPS readiness probes, the state colours, the Carbon launch check, NSPasteboard, the editor CLI preflight and the lease owner's `NSRunningApplication` check. The target builds alone on Linux (swift:6.4.2-noble), and `scripts/check-boundaries.sh` reports both SSMConnectDomain and SSMConnectWorkflow ok. On MacBook-Pro (macOS 26.6.2), from a copy of the tree in /tmp: `swift test --package-path SSMConnectKit` passed 302 tests in 37 suites, and `scripts/release.sh` built and verified the Release app. The one C call left in the shared targets is `rename` for atomic private writes, which Windows provides with different overwrite rules; the Windows adapters (T17) decide how private files are written there.
- [x] T9 `SSMConnectKit/Sources/SSMConnectAWS/` - move the AWS boundary into its own target: the T35 client for Linux and Windows, and the existing SDK adapters for macOS until T36, with STS presigning and error translation shared; done: package tests pass on macOS and the T37-T40 parity tests pass on Linux and Windows (AC-11, AC-28)
  - Evidence: 2026-11-21. SSMConnectAWS holds the AWS boundary. On every platform: the service ports on SSM Connect's client (`ClientEC2Service`, `ClientSSMService`, `ClientSecretsService`, `ClientInstanceConnectService`, each making one client per call as the SDK services do), the STS presigner and identity resolver, and the shared error rendering `AWSErrorText`, which the SDK path's `ConnectionStateMachine.message(from:httpStatus:)` now also uses. On macOS only (`#if os(macOS)`, with the aws-sdk-swift products conditioned on macOS): the existing SDK services, the SSO provider and token cache, and `SDKErrorText`, still the macOS defaults until T36. The target builds on Linux with the client path alone (swift:6.4.2-noble). On MacBook-Pro, from a copy of the tree in /tmp, `swift test --package-path SSMConnectKit` passed 310 tests in 38 suites, including `ClientServicesTests`: tag resolution with the SDK service's no-match and several-match errors, state mapping, polling to running and terminated, port-forward session parameters, waiting for PingStatus Online, missing and empty secrets, a refused or failed key push, and the error rendering. The T37-T40 parity suites are in the unchanged AWS client package and passed on ubuntu-24.04, windows-2025 and macos-15 in run 44898603627. Not yet on the client: the SSO sign-in provider, which reads the SSO cache with CryptoKit and stays SDK-based on macOS; the Windows and Linux helper composition (T15) is where it gets a client implementation.
- [x] T10 `SSMConnectKit/Sources/SSMConnectMacOS/`, `SSMConnectKit/Sources/SSMConnectUI/` - move AppKit adapters, persistence, DCV, browser and editor launchers and SwiftUI, keeping the composition root in the umbrella; done: the complete package suite passes and `scripts/release.sh` builds the app on a native macOS runner (AC-20, AC-24)
  - Evidence: 2026-11-21. SSMConnectMacOS holds the macOS adapters: the app delegate, DCV launching and viewer settings, the `NWConnection` and HTTPS readiness probes, unified logging, browser bootstrap and Firefox proxy setup, the login item, NSPasteboard, profile file IO and the profile store, notifications, the bundled plugin and SSH tunnels with the plugin process, the editor preflight, the remote SSH bridge, and `OwnerOnlyFiles.posix`. SSMConnectUI holds the SwiftUI views and the state colours. The umbrella keeps only the composition root (`MacOSWorkflow.swift`: `WorkflowPlatform.macOS` and the state machines' macOS initializers), the re-exports and the notices resource. On MacBook-Pro (macOS 26.6.2), from a copy of the tree in /tmp: `swift test --package-path SSMConnectKit` passed 310 tests in 38 suites, and `scripts/release.sh` (XcodeGen 2.48.0 from /tmp) built, signature-verified and packaged the ad-hoc signed Release app. `scripts/check-boundaries.sh` still reports both shared targets ok. That Mac is the native macOS host used here; the hosted macos-26 release job runs the same script on the next release from `main`.
- [x] T11 `SSMConnectKit/Tests/SSMConnectKitTests/Services/PersistedStateCompatibilityTests.swift` - fixtures written by the current release are read, and written back by every writer (`ProfileStore`, `EditorRecoveryStore`, `BrowserBootstrap` records) in the current-release keys and versions; done: the tests pass (AC-26, AC-14)
  - Evidence: 2026-11-21. `Tools/PersistedStateRecorder/PersistedStateRecorder.swift`, run inside a v0.7.1 checkout on MacBook-Pro, used the release's own `ProfileStore`, `EditorRecoveryStore` and `BrowserBootstrap` to write two profiles (multi-user desktop; tunnel-only with web forwards, a local forward, Zen Separate Browser and remote development), the active profile, non-default settings, an editor recovery intent, and a Separate Browser launch. It produced `Fixtures/persisted-state/`: all six `ssmconnect.*.v1` keys, the routing record and `user.js`. `PersistedStateCompatibilityTests` read them with the refactored code: every key present; the profiles, active profile, settings and nested configuration decoded; the editor intent read; `ProfileStore` and `EditorRecoveryStore` writing the same keys back with the same JSON content and version 1; `BrowserBootstrap` writing the same routing record and preferences for the same profile (paths compared relative to the browser root), and the release's routing record decoding and re-encoding unchanged. `swift test --package-path SSMConnectKit` passed 315 tests in 39 suites. Not recorded: the running-browser instance record, which only the real NSWorkspace launch path writes; its private type and encoding are unchanged from v0.7.1 apart from access modifiers.
- [x] T12 `SSMConnectKit/Tests/SSMConnectKitTests/StateMachine/CapabilityPreflightTests.swift` - failing tests: each missing hard requirement refuses with its name and no recorded AWS call, process launch or configuration write; a missing DCV Viewer keeps the tunnel with the current warning; done: they fail because preflight does not exist (AC-25)
  - Evidence: 2026-11-21. `CapabilityPreflightTests` with recording fakes. A missing plugin refuses dcvViewer and tunnel-only connections with no sign-in, EC2, SSM, tunnel, DCV or instance-ID write. A missing plugin or OpenSSH refuses web forwards with no sign-in, session, key, key push, SSH or PAC write. A missing browser refuses managed browsing before connecting or launching. A missing plugin, OpenSSH or VS Code refuses the editor with no sign-in, editor CLI preflight, launch or lease write and no new file under its root (VS Code keeps the current `RemoteSSHError.unavailable` message). A missing DCV Viewer keeps the desktop tunnel connected with the current warning. The web-forwards test doubles gained a reported-missing capability and a preflight error. On MacBook-Pro, `swift test --package-path SSMConnectKit --filter CapabilityPreflight` failed to build: "cannot find 'CapabilityError' in scope", "cannot find type 'Capability' in scope" and "extra argument 'sshAvailable' in call", because preflight does not exist.
- [x] T13 `SSMConnectKit/Sources/SSMConnectWorkflow/CapabilityPreflight.swift` - preflight before any effect; done: T12 and `ConnectionStateMachineTests` pass (AC-25, AC-13)
  - Evidence: 2026-11-21. `CapabilityPreflight.swift` defines the four capabilities and their refusal messages. The connection workflow refuses a missing plugin (the tunnel provider's existing availability check, now run first) before region checks and sign-in. Web forwards ask the SSH tunnel port's new `unavailableCapabilities()` (plugin and `/usr/bin/ssh` on macOS) before sign-in. The editor checks its plugin path and a new `sshAvailable` port before sign-in, the editor CLI or a lease write, keeping VS Code's existing message. Managed browsing keeps the browser preflight that already ran before connecting. Three existing editor tests that had no plugin path now pass one, because the plugin is required for every action. On MacBook-Pro, `swift test --package-path SSMConnectKit` passed 320 tests in 40 suites, `CapabilityPreflightTests` and `ConnectionStateMachineTests` included. SSMConnectWorkflow still builds alone on Linux, and the boundary check passes.
- [x] T14 `SSMConnectKit/Tests/SSMConnectHelperTests/ProtocolTests.swift` - failing protocol tests with fake ports: framing, refusal of a different build at handshake, one terminal result per admitted command, refusal before side effects, cooperative cancel isolation, heartbeat; done: they fail because the helper targets do not exist (AC-27)
  - Evidence: 2026-11-21. `ProtocolTests` with fake ports covers: newline-delimited JSON frames split across reads with CRLF tolerated, a 1 MiB limit and malformed frames; every frame type round-tripping; a different build refused at handshake with nothing admitted afterwards; a command before the handshake rejected; two concurrent commands each getting exactly one terminal result; a command whose admission check fails, a busy workflow, an unknown command and a reused ID all rejected with no side effect; cancelling one workflow leaving another running to completion; a failure as one failed result with its typed error; heartbeats answered while a command runs; ordered events; shutdown cancelling in-flight commands with one terminal result each. Two executable tests check that the helper reports its build, writes only frames to stdout, diagnoses a malformed frame on stderr and exits 0 on stdin EOF, and exits non-zero after refusing another build. The manifest gained the `SSMConnectHelperTests` target. `swift build --target SSMConnectHelperTests` in swift:6.4.2-noble failed: "product 'SSMConnectHelperProtocol' required by package 'kit' target 'SSMConnectHelperTests' not found", because the helper targets do not exist.
- [x] T15 `SSMConnectKit/Sources/SSMConnectHelperProtocol/`, `SSMConnectKit/Sources/SSMConnectHelper/` - helper executable over stdin/stdout with diagnostics on stderr, exiting on stdin EOF; done: T14 passes on macOS, Ubuntu and Windows CI runners (AC-27, AC-11)
  - Evidence: 2026-11-21. SSMConnectHelperProtocol (frames, codec, reader, `HelperSession`) and the SSMConnectHelper executable (`--build`, frames on stdout through FileHandle, diagnostics on stderr, stdin read on its own thread, exit 0 on EOF and 1 after refusing a handshake). The manifest declares the macOS adapters, SwiftUI, the umbrella, the proxy and aws-sdk-swift only when evaluated on macOS, so the shared layers and the helper build and test on Linux and Windows. GitHub Actions run 44934635180 (push of 04d17af): the new `helper` job ran `swift test --package-path SSMConnectKit --filter SSMConnectHelperTests` and passed on ubuntu-24.04, windows-2025 and macos-15. The 14 tests also passed in swift:6.4.2-noble, natively on w11-sandbox (Windows 11, Swift 6.4.3), and on MacBook-Pro alongside the 320-test package suite. The same run's Ubuntu portability spike failed when swiftbuild itself crashed (SIGSEGV in its `Process.run` while building the aws-sdk-swift probe from the unchanged pins), and its two Windows portability jobs failed as before on aws-crt-swift. The helper registers no commands yet; the shells' workflows add them.
- [x] T16 `SSMConnectKit/Sources/SSMConnectWorkflow/LeaseOwner.swift`, `SSMConnectKit/Sources/SSMConnectProxy/` - lease owner identity behind a port (the app process on macOS, the helper's PID and start time on Windows and Linux), so the proxy ends channels when the owner is gone, and record the owner's build in the lease so a proxy of a different installed build refuses new channels before any AWS call; done: new lease tests pass on all three platforms and existing Remote-SSH tests pass unchanged (AC-17)
  - Evidence: 2026-11-21. `LeaseOwner.swift` adds `InstalledBuild`, `LeaseOwnerIdentity`, the `LeaseOwnerProbing` port and, for Windows and Linux, `ProcessLeaseOwner`: the helper's PID with its kernel start time (`GetProcessTimes`; field 22 of `/proc/<pid>/stat`), so a finished or reused PID is not active. On macOS, `ApplicationLeaseOwner` wraps the existing NSRunningApplication check, which the proxy and the editor's default owner closures now use. Leases record `ownerBuild` (optional, omitted when nil so earlier leases still decode), renewal keeps it, and continuation requires it unchanged. The editor proxy calls `requireSameBuild()` right after validating the lease and before any AWS call, refusing with "SSM Connect was updated; restart it." (`RemoteSSHError.updated`). The proxy executable target is unchanged; its runtime lives in SSMConnectMacOS. The new `SSMConnectWorkflowTests` target (`LeaseOwnerTests`) passed in swift:6.4.2-noble (5 tests with the process owner), natively on w11-sandbox (Windows 11, 5 tests) and on MacBook-Pro (4 tests; the process owner is Windows and Linux only). The full macOS suite passed 320 tests in 40 suites, with no existing Remote-SSH test file changed. The CI `helper` job now runs these tests too.
- [x] T17 `SSMConnectKit/Sources/SSMConnectWindows/` - core-side Windows adapters: per-user ACL atomic files, key-value store, plugin and SSH process launch, VS Code, Chrome and Zen discovery with per-platform pinned versions; done: adapter tests pass on the windows-2025 runner (AC-19, AC-16, AC-17)
  - Evidence: 2026-11-21. SSMConnectWindows, declared only when the manifest is evaluated on Windows, holds:
    - `WindowsPrivateFiles`: owner-only directories and files created with a protected DACL whose single ACE grants the current user, written to a temporary sibling and replaced with `MoveFileExW`, refusing junctions and symbolic links; an owner-only check (owner is the current user, no allow ACE for another SID); an unshared lock handle; and `OwnerOnlyFiles.windows`.
    - `WindowsKeyValueStore`: an owner-only JSON file under `%LOCALAPPDATA%\SSM Connect`.
    - `WindowsTools`: the bundled plugin beside the helper, `%SystemRoot%\System32\OpenSSH`, and per-user or machine VS Code, reporting missing capabilities; `WindowsProcessLauncher` with the plugin command line now shared as `PluginArguments` in SSMConnectWorkflow, which the macOS tunnel also calls.
    - `WindowsBrowserDiscovery`: Chrome (versioned folder holding chrome.dll) and Zen (application.ini). A browser is offered only at a version in `pinnedVersions`, which stays empty until the Windows acceptance run records the versions that passed, and Chrome only in Separate Browser.

    The owner-only port now receives the file URL, which Windows needs to read the ACL. Found on the way: Win32 calls need the native path form, not Foundation's "/C:/...". `SSMConnectWindowsTests` (8 tests: private files and replacement, a widened ACL, a junction, the lock, the key-value store, tool discovery, process launch, browser discovery and pinning) passed natively on w11-sandbox and in GitHub Actions run 44937686805 on windows-2025, whose test step succeeded; that job is marked failed only by the checkout action's post-job cleanup while it terminated orphaned git processes. The macOS (320) and Linux (19) suites still pass.
- [x] T18 `windows/tests/SSMConnect.App.Tests/HelperHostTests.cs` - failing tests for the helper host: a job object per helper, terminate and wait empty before a replacement, one automatic restart under the handshake, heartbeat and cancel limits with its re-arm, the error with Retry, single instance, user apps started outside the job, and the "updated; restart it" message on a build mismatch; done: they fail because the host does not exist (AC-18, AC-27, AC-21)
  - Evidence: 2026-11-21. `HelperHostTests` (xUnit v3, `FakeTimeProvider`) uses an in-process fake helper that speaks the real line protocol over anonymous pipes, plus real job objects with cmd.exe children. It covers: handshake and one terminal result; a build mismatch showing "SSM Connect was updated; restart it." with no replacement; a first helper that never handshakes leading to "SSM Connect core unavailable" without a restart; one automatic restart that terminates and empties the old job before starting the next, then Retry; ten healthy minutes re-arming the restart; a missed heartbeat counting as stopped; an in-flight command failing with "core stopped" and never resent; a confirmed cancel; an unconfirmed cancel replacing the helper after 10 s; each helper and its descendants in a kill-on-close job, empty after terminate; user apps started outside the job; and a second launch signalling the first. The scaffolding is new: `windows/Directory.Build.props` (from ce24cf2), `SSMConnect.slnx`, `nuget.config` and a minimal WPF `SSMConnect.App` project. On w11-sandbox (.NET SDK 10.0.404, installed by PDS `Install-DotnetSdk`), `dotnet test windows\SSMConnect.slnx` failed to compile: "The type or namespace name 'Helper' does not exist in the namespace 'SSMConnect.App'" and "'HelperHost' could not be found", because the host does not exist.
- [x] T19 `windows/src/SSMConnect.App/HelperHost.cs` - the helper host; done: T18 passes (AC-18, AC-27)
  - Evidence: 2026-11-21. `Helper/HelperHost.cs`:
    - The handshake limit starts before `hello` is written.
    - Heartbeats run on the injected `TimeProvider`, and an unanswered one counts as a stop. A cancel unconfirmed within its limit counts as a stop too.
    - Each helper stops once. Its in-flight commands fail with "core stopped" and are never resent, and its container is terminated and empty before anything else happens.
    - Only a helper that completed its handshake earns the single automatic replacement, which is re-armed after ten healthy minutes or by Retry. Otherwise the host shows "SSM Connect core unavailable".
    - A `differentBuild` refusal shows "SSM Connect was updated; restart it."
    - An exit counts once the reader has drained stdout, or after a second when a descendant holds the pipe open.

    Beside it: `JobObject` (kill-on-close; assign, contains, active count, terminate and wait empty), `JobHelperSpawner` (the bundled helper on anonymous pipes in a new job, stderr to the log), `UserApplications` (started from the shell's process, outside every job) and `SingleInstance` (a session mutex, with a second launch signalling the first). Found on the way: an exit notice could resolve the handshake before the `refused` frame was read, and two tests advanced the fake clock ahead of the host. On w11-sandbox (.NET SDK 10.0.404), `dotnet test windows\SSMConnect.slnx` passed all 12 `HelperHostTests` in three consecutive runs.
- [x] T47 `SSMConnectKit/Sources/SSMConnectAWS/`, `SSMConnectKit/Tests/SSMConnectAWSTests/` - SSO sign-in, silent refresh and role credentials on SSM Connect's client for Windows and Linux, with the same `~/.aws/sso/cache` file names and contents and the same refresh and rejection rules as `AWSAuthProvider` on macOS; done: tests with a scripted transport pass on macOS, Linux and Windows, and for the same start URL write the cache file `AWSAuthProvider` writes (AC-15, AC-28)
  - Evidence: 2026-11-21. `ClientAuthProvider` (SSMConnectAWS, every platform) applies `AWSAuthProvider`'s steps on SSM Connect's client: cache reuse outside the renewal lead time, silent refresh written back with a rejected refresh falling back to sign-in, and the device authorization grant (open the URL, wait while pending, five seconds more on slow_down, InvalidGrant rechecking the cache). It also matches role credentials from epoch milliseconds, "not assigned this role" on 403 or ForbiddenException, and the same rejected-authorization and permission type names. `SSOCacheReader` is now portable (swift-crypto SHA-1, the version the AWS client pins), so both providers write the same AWS CLI cache file. The new portable `SSMConnectAWSTests` (`ClientAuthProviderTests`, 7 tests, scripted SSO endpoints) check reuse with no OIDC call, refresh into the same file, fallback after a rejected refresh, the device grant with its URL, waits and cache keys, the file named by the start URL's SHA-1 (`aa477ced...json`, computed independently), sign-in required, role access denied, and the error rules. They passed in swift:6.4.2-noble, on w11-sandbox and on MacBook-Pro, where the 320-test package suite, with the SDK provider's cache tests, also passed. The CI `helper` job runs them too.
- [x] T48 `SSMConnectKit/Sources/SSMConnectHelper/`, `SSMConnectKit/Tests/SSMConnectHelperTests/` - the helper's command table: compose the workflows with the SSMConnectAWS client services, the T47 provider and the Windows adapters (T22 adds Linux), map each shell action (sign in, connect, disconnect, stop workstation, open the editor, start and stop web forwards, open the managed browser, import and save profiles) to its workflow, stream workflow state as ordered events, and ask the shell to start VS Code, DCV Viewer and browsers through an event; done: helper tests with fake services drive every command to its terminal result and event sequence on macOS, Linux and Windows (AC-11, AC-12, AC-13, AC-15, AC-27)
  - Evidence: 2026-11-21.
    - **Runtime:** a new library target, SSMConnectHelperCore, so tests import it on every platform including Windows; the executable stays a thin `main.swift`. `HelperRuntime` composes the shared profile store, authorization session and the desktop, web-forwards and editor workflows from `HelperServices`, and its table maps each shell action to one workflow, with admission checks (configured profile, connected, editor or web forwards on) before any effect, workflow state streamed as ordered events, and cancel tearing the workflow down. `ShellRequests` sends the sign-in URL, launches of DCV Viewer (a written connection file), VS Code (the workflow's arguments) and the managed browser, clipboard text and notifications to the shell as events.
    - **Moved to SSMConnectWorkflow:** `ProfileStore` behind a new `ProfileFileAccessing` port (macOS keeps POSIX `ProfileFileIO`; Windows and Linux get `PortableProfileFiles`); the SSH command line as `SSHArguments` (POSIX and Windows quoting); `WebForwardsPAC`; and the Windows ACL private-file writer, so `BrowserPrivateFiles` is owner-only on Windows too and no longer hits `rename`'s refusal to replace there, which made the editor fail with CocoaError 512.
    - **Windows composition:** client services and `ClientAuthProvider`, a process tunnel with TCP readiness, the OpenSSH tunnel, ssh-keygen, a TLS ClientHello readiness probe (the plugin accepts locally before the workstation listens), Windows private files, the key-value store and browser discovery.

    `HelperCommandTests` (10 tests, fake services) drives every command to its terminal result and event sequence: profiles saved, listed, activated, imported and an unknown ID failed; connect refused while unconfigured, then streamed to connected with a DCV Viewer launch request; stop refused while disconnected, then stopped; cancelled connect; sign-in; editor setup and open with a VS Code launch request; web forwards on and off; the managed browser opened, or refused by name when unsupported; and the full command set. They passed in swift:6.4.2-noble (36 tests in 4 suites), natively on w11-sandbox (24 helper tests with the Windows composition compiled), and on MacBook-Pro with the 320-test package suite. Not yet working on Windows: the editor's SSH proxy, which is still a macOS-only executable. Linux joins with T22.
- [x] T49 `SSMConnectKit/Sources/SSMConnectProxy/`, `SSMConnectKit/Sources/SSMConnectWorkflow/`, `SSMConnectKit/Tests/SSMConnectWorkflowTests/` - make the editor's SSH proxy build and run on Windows and Linux: its lease validation, owner and build checks, channel authorization and plugin supervision move to the shared layer on the lease owner port (T16), the client services and the platform's private files, with the macOS proxy unchanged in behavior; done: proxy tests with fake services pass on macOS, Linux and Windows, including refusal of an expired lease, a lease of another build and a lease whose owner is gone before any AWS call (AC-17)
  - Evidence: 2026-11-21. `EditorProxy` (SSMConnectWorkflow) holds the proxy's rules in their original order, all before any AWS call: validate the owner-only lease against the lease-owner port, require the owner's build, refuse an expired lease with a recovery request. Then it authorizes the channel (silent refresh, the same running instance, the key push, the SSH session), runs the plugin on its own stdio while the lease stays current, and keeps the failure messages. On macOS, `RemoteSSHProxyRuntime` keeps its API as a facade with `ApplicationLeaseOwner`, POSIX files and the SDK services. `OwnerOnlyFiles.posix` moves to the shared layer (no Darwin import; lock fields set by name, so Glibc's layout works). `ssm-connect-proxy` is now built on every platform: on Windows and Linux with `ProcessLeaseOwner`, the platform's owner-only files and the client services, never signing in interactively. `EditorProxyTests` (5 tests: expired lease with a recovery request, another build and an unrecorded build, owner gone, all with no AWS call; a valid lease authorized in order with the plugin run; the restart message) passed in swift:6.4.2-noble with the proxy linked, on w11-sandbox and on MacBook-Pro, where the 320-test package suite passed and `scripts/release.sh` built the app with `Contents/Helpers/ssm-connect-proxy`.
- [x] T20 `windows/src/SSMConnect.App/` - the WPF shell reapplied from `ce24cf2` without connection rules: settings, tray, profile files, clipboard, notifications, startup, and launching VS Code, DCV Viewer and browsers at the helper's request; done: a UI drive-through test shows every action reaching the helper as a command (AC-11, AC-14)
  - Evidence: 2026-11-21. The shell holds no connection rules: `ShellController` sends each tray action (sign in, connect, disconnect, stop workstation, open VS Code, start and stop web forwards, open the browser) and each settings action (list, save, use, import profiles, install editor setup) to the helper as its command through `HelperHost`, shows the helper's failure text on a failed, rejected or stopped command, and turns the helper's shell events into Windows calls behind `IShellPlatform`: open an https URL, launch VS Code, DCV Viewer or the browser, set the clipboard and clear it after a delay, and notify. `TrayIcon` and `TrayIcons` are reapplied from `ce24cf2`, with the state names the helper sends; `StartupRegistration` writes the per-user Run value from the settings window. `dotnet test windows\SSMConnect.slnx` on w11-sandbox (Windows 11, .NET SDK 10.0.404): 15 passed, 0 failed, including `ShellDriveThroughTests.EveryTrayAndSettingsActionReachesTheHelperAsItsCommand` (clicks every menu item and invokes every settings button through UI Automation peers on an STA dispatcher; the fake helper received all 13 commands and no error was shown), `HelperRequestsReachWindowsThroughTheShell` and `StartupRegistrationTests`. Untested here: a real desktop session with Explorer's notification area (T27 acceptance); the browser launch request starts Chrome only, with the SOCKS proxy and a private profile, until T28 adds the other managed browsers.
- [x] T21 `packaging/windows/`, `.github/workflows/release.yml` - restructure the release workflow to create the tag and GitHub Release before platform jobs, with the macOS job uploading its existing assets, and add the Windows job: a per-user WiX MSI with the Restart Manager close prompt, WinGet manifest hashed from the built MSI, and notices; done: a dispatched run on a test tag creates the release first without the latest mark, the macOS job marks it latest after its ZIP unless a newer release has one, inside the queued `release-latest` concurrency group, the macOS and Windows jobs upload independently, a rerun of a job uploads only missing assets and changes no published one, the manifest validates, and the unpacked MSI holds the helper, runtime and notices (AC-21, AC-24)
  - Evidence: 2026-11-22.
    - **Workflow:** `release.yml` resolves the version (GitVersion, or a manual `test_tag` built as a prerelease), tags it, reusing a tag already on the commit, and creates the GitHub Release with `--latest=false` before any platform job. Then `macos` (unchanged build, `release.sh`), `windows` and `macos-latest` run. `macos-latest` sits in the `release-latest` concurrency group with `cancel-in-progress: false` and marks the newest non-prerelease release that has a macOS ZIP. Choosing the newest release with a ZIP, rather than "mine unless a newer one has a ZIP", gives the same result, and a pending run that GitHub replaces with a later one loses nothing. `scripts/release/release-assets.sh` holds the shared steps; `upload-missing` skips names the release already holds and never passes `--clobber`. `bash scripts/release/test-release-assets.sh` (fake `gh`, 12 checks) passes, and fails when the version sort or the `--latest=false` flag is broken.
    - **Windows package:** `packaging/windows/Build-Release.ps1` stamps one build ID into the shell (assembly metadata), the helper and the proxy (`InstalledBuild.swift`, restored afterwards). It builds both Swift products in release mode and copies the Swift runtime DLLs they import (20, found by walking PE import tables; static linking fails for want of curl and libxml2). It publishes the shell self-contained and adds the hash-verified plugin, `LICENSE.txt` and `ThirdPartyNotices.txt` (Swift, ICU, SwiftCrypto, Yams, LibYAML, .NET). Then WiX 6.0.2 builds the per-user MSI, and `Write-ReleaseMetadata.ps1` writes the SHA-256 file and the WinGet manifest from that exact file and runs `winget validate`. With the full UI, the MSI's Restart Manager dialog offers only "Close SSM Connect" or Cancel. Without it, `util:CloseApplication` detects the running shell and the install stops before changing anything. The shell answers Restart Manager through `SessionEndWindow` and stops its helper with `HelperHost.ShutdownAsync`; `SessionEndWindowTests` and `ShutdownAsksTheHelperToEndThenEmptiesItsJobAndStartsNoReplacement` pass among 17 shell tests on w11-sandbox and on the hosted runner. These were written together with the change and not first seen failing.
    - **Dispatched runs on test tags** (prereleases, deleted afterwards): run 44949116397 (`v0.0.0-t21.1`) created the release with no assets while both platform jobs were still building, with v0.7.1 still latest. Its ZIP arrived from the macOS job, and `macos-latest` left v0.7.1 latest because a newer release has a ZIP. The Windows jobs of the next runs found four defects, each fixed in its own commit: a pwsh pipeline hang on build servers (6e67e70), the settings selection race (f7ccab3, test seen failing first), a leaked native exit code (4a80eb7), and a rerun's checksum and manifest describing its non-reproducible rebuild instead of the published MSI (f383788, f9653b9).
    - **Final run 44963791951** (`v0.0.0-t21.6`, f9653b9): every job passed. The Windows job uploaded the MSI and checksum independently of the macOS ZIP. `Test-Package.ps1` passed on the runner: the unpacked MSI holds the shell, helper, proxy, runtime, plugin and every notice; the helper starts with only System32 on PATH and reports `0.0.0-t21.6+f9653b91c8ef`; the manifest pins the MSI's hash; a silent install works, a silent reinstall while SSM Connect runs is refused with 1603 and leaves it running, the helper ends with the shell, and reinstall and uninstall leave no folder. After the `.sha256` asset was deleted, a rerun of the Windows job rebuilt an MSI with SHA-256 EF4747DB… but continued with the published one (25D6BC85…). It kept the MSI ("Kept the published …") and uploaded only the checksum, which came out byte-identical to the deleted one (digest 2319c3a3…). The manifest artifact pins 25D6BC85…, and the ZIP and MSI assets kept their IDs and timestamps.
    - **Untested:** marking a new latest release on GitHub (only the "a newer release has a ZIP" branch ran live; the marking itself is covered by the fake-`gh` checks and first runs on the next real release); the interactive Restart Manager dialog and an upgrade over a running older version (AC-21, T28); WinGet submission, which waits for a `WINGET_TOKEN` secret and until then keeps the validated manifest as a run artifact.
- [x] T22 `SSMConnectKit/Sources/SSMConnectLinux/` - core-side Linux adapters, composed into the helper's command table (T48): user-only atomic files, key-value store, plugin and SSH process launch, VS Code, Chrome and Zen discovery with per-platform pinned versions, and the build-ID and plugin-hash check of the exact file before every launch; done: adapter tests pass on Fedora 43 and Ubuntu 24.04 (AC-19, AC-16, AC-17)
  - Evidence: 2026-11-22.
    - **Linux adapters:** SSMConnectLinux holds `LinuxPaths` (settings in `$XDG_CONFIG_HOME/ssm-connect`, state in `$XDG_STATE_HOME/ssm-connect`, relative values ignored), `LinuxKeyValueStore`, `LinuxTools` (plugin and proxy beside the helper; ssh, ssh-keygen, `code` and `dcvviewer` on PATH, then their install folders) and `LinuxBrowserDiscovery` (Chrome from Google's packages through `--version`, Zen's tarball install through application.ini). The pinned versions stay empty until T29. User-only files are `LinuxPrivateFiles` in SSMConnectWorkflow, beside the Windows writer: folders mode 0700 owned by the user, files through an exclusive mode-0600 temporary that is synced and renamed, and a symbolic link or another user's file refused. `BrowserPrivateFiles` uses it on Linux; macOS keeps its writer. The JSON key-value store is shared as `FileKeyValueStore` (Windows and Linux), and Zen's version reader as `BrowserVersions.zen`.
    - **Installation check:** `InstalledBuild.marker` holds the build ID in one literal, so it appears in every executable, and `InstalledBuild.pluginSHA256` records the bundled plugin's hash (nil in development builds). Before each launch, `InstallationCheck` refuses an executable without this build's marker, or a plugin with another hash, as "SSM Connect was updated; restart it", and a missing file as "SSM Connect was removed; quit it". The helper applies it to the plugin before the port-forward and web-forward tunnels start, and to the proxy and plugin before opening VS Code; the proxy applies it to the plugin before starting it. `HelperComposition.production` now composes Windows and Linux from one body with a per-platform `Adapters` value, and the helper registers its command table on Linux. `Build-Release.ps1` fetches the plugin first and stamps its hash with the build, and `Test-Package.ps1` checks that the helper and proxy carry both. On w11-sandbox the package build passed with them.
    - **Tests:** written first and seen failing on swift:6.4.2-noble for want of `InstallationCheck`, `InstallationChange`, `InstalledBuild.marker`, `LinuxPrivateFiles`, `LinuxPaths` and `LinuxKeyValueStore`. `scripts/linux/test-in-containers.sh all` (committed; Fedora 43 from `fedora43.Containerfile` with swift.org's signature-checked 6.4.2 Fedora 41 build, which runs on Fedora 43, since swift.org publishes no Fedora 43 build of 6.4.2) passed 62 tests in 8 suites on Ubuntu 24.04.5 and on Fedora Linux 43: 12 Linux adapter tests, 6 installation-check tests, 3 launch tests (a replaced or removed plugin is refused before anything starts, and the built helper carries its marker), and the existing helper, workflow and AWS suites. The Windows suites passed on w11-sandbox (58 tests), and the macOS package suite on MacBook-Pro (320 tests, plus the helper, workflow and AWS suites). The CI helper job now runs SSMConnectLinuxTests on Ubuntu.
    - **Untested here:** a real Fedora or Ubuntu desktop session (T29). The check of the helper file before the shell starts it belongs to the shell hosts: T24 on Linux, and the Windows host, which today relies on the handshake's build refusal and reports a missing helper as core unavailable rather than removed.
- [x] T23 `linux/tests/helper_host_test.cpp` - failing tests for the helper host: a transient systemd user service bound to the shell's scope, creating that scope when missing, stop and wait empty before a replacement, the restart limits, single instance, and user apps in their own transient scopes; done: they fail because the host does not exist (AC-18, AC-27)
  - Evidence: 2026-11-22. `linux/tests/helper_host_test.cpp` (Qt Test) holds two suites. `HelperHostTest` drives the host with a fake spawner and a manual clock, as the Windows host's tests do: the handshake and one terminal result, the build refusal with no replacement, a first helper that never handshakes leading to "SSM Connect core unavailable" with no restart, one automatic restart that empties the old unit before the replacement starts and Retry after it, the re-arm after ten healthy minutes, a missed heartbeat, an in-flight command failing with "core stopped" and never resent, a confirmed cancel, an unconfirmed cancel replacing the helper after ten seconds, and shutdown. `SystemdContainmentTest` runs against the user's systemd instance, with `fake_helper` and `scope_probe` built beside it. It checks the helper is the main process of an `ssm-connect-helper-*.service` with `BindsTo=` and `After=` on the shell's scope, that a shell started in a service creates its own `app-ssm-connect-*.scope`, that stopping the unit ends the helper's child before it reports empty, that killing a shell whose helper is SIGSTOPped ends the helper's unit within 10 seconds, single instance through a D-Bus name, and user applications in their own `app-ssm-connect-*.scope`. `scripts/linux/shell-tests.sh` builds `linux/` in the Fedora 43 image (`fedora43-shell.Containerfile`: gcc-c++, CMake, Ninja, Qt 6.10 development packages) and runs the tests on the host; it fails at CMake generation because `src/helper_host.cpp` and the other host sources do not exist.
- [x] T24 `linux/src/helper_host.cpp` - the helper host; done: T23 passes (AC-18, AC-27)
  - Evidence: 2026-11-22.
    - **Host:** `HelperHost` (`linux/src/helper_host.cpp`) keeps the Windows host's rules on Qt's event loop: a handshake limit running from before the hello, a heartbeat each interval, one automatic restart for a helper that completed its handshake, re-armed after ten healthy minutes or by Retry, "core stopped" for in-flight commands, a cancel that replaces an unconfirming helper after ten seconds, and shutdown.
    - **Containment:** `SystemdHelperSpawner` starts each helper through `systemd-run --user --pipe` as the main process of `ssm-connect-helper-<uuid>.service`, with `BindsTo=` and `After=` on the shell's scope and `TimeoutStopSec=5`. The shell's pipes are the helper's stdin and stdout. It ends a helper with `systemctl --user stop` and reports empty once the unit is inactive or gone. `ensureOwnScope` moves a shell that is not in a scope into a new `app-ssm-connect-<uuid>.scope` through `Manager.StartTransientUnit`. `SingleInstance` owns a session-bus name and has a second launch call `Activate`. `UserApplications` starts programs with `systemd-run --user --scope`.
    - **Defect found:** the tests found that the `systemd-run --pipe` client, which waits in the shell's scope, outlived a killed shell, so the scope never emptied and a SIGSTOPped helper survived. It now gets `PR_SET_PDEATHSIG`, so it ends with the shell.
    - **Tests:** `scripts/linux/shell-tests.sh` on this Fedora 43 workstation (Qt 6.10.3, the user's systemd instance) passed 10 of 10 host-logic tests and 6 of 6 native containment tests, three runs in a row. The SIGSTOPped helper's unit and processes were gone within 10 seconds of killing its shell. No `ssm-connect-*` or `app-ssm-connect-*` unit remained afterwards.
    - **Untested here:** Ubuntu 24.04 natively, and the shell's own use of these pieces (T25).
- [x] T25 `linux/src/`, `linux/qml/` - the Qt 6 shell with a StatusNotifierItem tray, launching VS Code, DCV Viewer and browsers at the helper's request; done: a UI drive-through test shows every action reaching the helper as a command (AC-11, AC-14)
  - Evidence: 2026-11-22.
    - **Shell:** like the WPF shell, it holds no connection rules. `ShellController` (`linux/src/shell_controller.cpp`) sends each tray action (sign in, connect, disconnect, stop workstation, open VS Code, start and stop web forwards, open the browser) and each settings action (list, save, use and import profiles, set up VS Code) to the helper as its command, and shows the helper's failure text on a failed, rejected or stopped command. It turns the helper's shell events into calls on `ShellPlatform`.
    - **Platform:** `LinuxShellPlatform` starts xdg-open (https only), VS Code, DCV Viewer and Chrome, each in its own `app-ssm-connect-*.scope`. It sets the clipboard and clears it after a delay, and notifies through the tray.
    - **Tray, settings and entry point:** `Tray` uses `QSystemTrayIcon`, which registers a StatusNotifierItem on Linux desktops, with Settings, Retry Core and Quit. `linux/qml/Settings.qml` is the settings window, and `StartupRegistration` writes an XDG autostart entry. `main.cpp` takes the single-instance name, ensures the shell's scope, and starts the helper from `libexec/ssm-connect` through `SystemdHelperSpawner`.
    - **Tests:** `scripts/linux/shell-tests.sh` (Fedora 43, Qt 6.10.3, offscreen) passed 3 of 3 shell tests, beside the 16 host tests. `everyTrayAndSettingsActionReachesTheHelperAsItsCommand` triggers every menu item and clicks every settings button through QML. The fake helper received all 13 commands in order, the saved profile kept its ID with the edited role, Use sent that ID after the reload kept it selected, and no error was shown. `helperRequestsReachLinuxThroughTheShell` checks the six shell requests and a state event, and `startingAtSignInIsAnXdgAutostartEntry` checks the autostart file. The test fakes moved to `linux/tests/fakes.h`, shared with the host tests.
    - **Untested here:** the shell with the real helper in a desktop session (T29). Zen and Use My Browser start from the shell only after T29; until then the shell reports that they are not available on Linux, as the Windows shell does.
- [x] T26 `packaging/linux/`, `.github/workflows/release.yml` - the Linux job: `.rpm` and `.deb` whose maintainer scripts only run non-fatal cache refreshes, with notices; done: the Linux job builds and uploads both on a test tag, publishes with the macOS job failed, and the package inspection in the AC-21 and AC-24 rows passes (AC-21, AC-24)
  - Evidence: 2026-11-22.
    - **Packages:** `packaging/linux/build-packages.sh` fetches the Session Manager plugin through `scripts/fetch-plugin-linux.sh` (version 1.2.835.0, package and binary SHA-256 pinned), stamps the build and the plugin's hash into a copy of the Swift package, and builds the helper and proxy with the static Swift runtime on each distribution. Each distribution gets its own build because the system libcurl's symbol versions differ: a binary built on Ubuntu required `libcurl.so.4(CURL_OPENSSL_4)`, which Fedora does not provide. It then builds and tests the Qt shell against each distribution's Qt (6.10 on Fedora 43, 6.4 on Ubuntu 24.04, which needed `setpriv --pdeathsig` instead of a Qt 6.6 API) and packages `SSMConnect-<version>-fedora43-x86_64.rpm` and `SSMConnect-<version>-ubuntu24.04-amd64.deb`. Both carry the shell, the helper, the proxy, the plugin, the desktop entry, the icon, `LICENSE`, `ThirdPartyNotices.txt` and the plugin's notices, and neither has maintainer scripts: the distributions' own triggers refresh the desktop database and icon cache.
    - **Package checks:** `packaging/linux/test-packages.sh` checks that there are no scriptlets and that every file and notice is present, that both executables carry the marker and the plugin hash, and that the helper reports the build. It installs each package over an older one on a clean Fedora 43 and Ubuntu 24.04 container with the distribution resolving the dependencies, checks that no library is missing and that the shell starts and keeps running on a session bus, and then uninstalls, checking that the program files are gone and the user's settings remain.
    - **Release job:** `release.yml` gains the `linux` job, which reuses published packages on a rerun, and a test-only `fail_job` input.
    - **Dispatched run 44973381483** (`v0.0.0-t26.1`, `fail_job=macos`, 8653fb9): the macOS job failed on request and `macos-latest` was skipped, while the Windows and Linux jobs published the MSI, RPM and DEB with their checksums, and v0.7.1 stayed latest. The Linux job's shell tests passed on both distributions (16 host and 3 shell tests each, with the 6 systemd tests skipped in the containers), and every package check passed. After the RPM's checksum was deleted, a rerun of the Linux job reused both published packages ("Using the published …"), ran the checks on them, kept the RPM, DEB and DEB checksum, and uploaded only the RPM checksum, byte-identical to the deleted one (digest a072884a…).
    - **Untested here:** the packages on a Fedora or Ubuntu desktop, with a systemd user instance and a tray (T29).
- [x] T46 `SSMConnectKit/Sources/SSMConnectKit/Auth/STSIdentityResolver.swift`, `SSMConnectKit/Sources/SSMConnectKit/Auth/STSPresigner.swift`, `SSMConnectKit/Tests/SSMConnectKitTests/Auth/STSIdentityResolverTests.swift` - the production STS identity resolver sends through the AWS client's `getCallerIdentityARN` and its presigned URL; done: a resolver test with an injected transport shows the client's transport in use, the `amazonaws.com.cn` host in a China region, and a single attempt on 503 and on a lost connection, and the full macOS package suite passes (AC-28, AC-20)
  - Evidence: 2026-11-21 on MacBook-Pro (macOS 26.6.2), from a copy of the tree in /tmp. Before the change `swift test --package-path SSMConnectKit --filter STSIdentityResolver` failed to build ("extra argument 'transport' in call"): the resolver had no client transport and sent through its own URLSession. After it, `swift test --package-path SSMConnectKit` passed 302 tests in 37 suites. The resolver tests show one GET to `sts.eu-central-1.amazonaws.com` through the injected transport, `sts.cn-north-1.amazonaws.com.cn` for cn-north-1, one attempt on HTTP 503 (`stsRejected`) and on a lost connection, and `noArn` without an `<Arn>`; the presigner's known-answer URL is unchanged and a China region presigns for the `.cn` host. Beyond the listed files: the test target depends on SSMConnectAWSClient to inject the transport, and the presigner now throws for a region the client's resolver refuses, so its two callers in `ConnectionStateMachine.swift` gained `try` inside blocks that already handle errors, after `resolve` has used the same region.
- [x] T36 `SSMConnectKit/Package.swift`, `SSMConnectKit/Package.resolved`, `SSMConnectKit/Sources/SSMConnectAWS/` - switch macOS to the client and remove aws-sdk-swift and aws-crt-swift from the package; done: the complete macOS package suite and `scripts/release.sh` pass, the documented macOS flows run natively on the client, and the resolved package graph has no aws-sdk-swift, aws-crt-swift or Smithy module (AC-28, AC-20)
  - Evidence: 2026-11-22.
    - **Switch:** the macOS composition (`MacOSWorkflow.swift`) and the editor bridge now use `ClientAuthProvider.macOS()` (the device authorization page opens with NSWorkspace), the client EC2, SSM, Secrets Manager and Instance Connect services, `AWSErrorText`, and the client's authorization rules. The SDK-backed services, `AWSAuthProvider` and `SDKErrorText` are deleted, and Package.swift no longer names aws-sdk-swift. On the Mac, `swift package resolve` removed 24 pins and changed none, leaving swift-asn1, swift-crypto and Yams. The fixture recorder in `SSMConnectKit/Tools/FixtureRecorder` keeps its own SDK pin as a development tool outside the app's graph.
    - **Ported tests:** before deleting the SDK tests, their scenarios were ported to the client tests, which run on every platform: offline and cancelled refresh, a revoked token, an invalid refresh or role request, an adopted shared sign-in, a rejected device grant, missing role credentials, a 401 role failure, renewal inside the lead time, start and stop, the pending deadline, SSH session parameters, the SSM online timeout, an incomplete session and a binary-only secret. The client services tests moved from the macOS-only target to `SSMConnectAWSTests`.
    - **Differences found:** three ported tests failed first, each for a difference from the SDK path: a GetRoleCredentials reply without credentials, an incomplete StartSession reply, and an invalid region, whose error rendered as "…ResolveError error 0". The client now reports `AuthError.missingRoleCredentials`, `SSMError.malformedSessionResponse` and "Invalid region: <region>", as the SDK path did.
    - **Suites:** the macOS package suite passed on MacBook-Pro (macOS 26.6.2): 275 tests in 35 suites, with 31, 27 and 15 tests in the AWS, workflow and helper suites. Linux passed 86 tests in 9 suites on Ubuntu 24.04 and Fedora 43, Windows passed all its suites on w11-sandbox, and the AWSClient package passed 34 tests.
    - **Release build:** `scripts/release.sh` built, verified and packaged the app (9.6 MB ZIP). Neither the app executable nor the editor proxy contains an aws-sdk-swift, aws-crt-swift or Smithy string or symbol, and the app links no non-system library. The app's ThirdPartyNotices gains SwiftCrypto, and the README's architecture section describes the client.
    - **Live run:** `scripts/live-macos-flows.sh` ran the documented flows natively on the client against the owner's IAM Identity Center profiles, with the device code approved through auth-refresh's admin lane after one Okta Verify tap. Results: sign-in returned role credentials; a desktop connect to the multi-user workstation resolved it by tag, waited for SSM, started a session, opened the plugin tunnel on a free port, passed the HTTPS readiness check, received DCV credentials from an identity token, and disconnected cleanly; web forwards pushed the key, opened SSH over SSM, and listened on SOCKS and one local forward until stopped; and the editor channel probe carried three concurrent SSH command channels through the editor proxy with a lease the running app owns, a channel after 65 seconds, the end of a held channel when its lease was removed, and a reconnect with a renewed lease. The probe's leases now record the owner's build, which T16 made required.
    - **Untested here:** the single-user desktop, whose workstation no longer resolves by its tag, so its Secrets Manager password path ran only against fakes; the interactive app UI (T27).
- [ ] T27 `docs/specs/cross-platform-client.spec.md` - macOS native acceptance: the AC-20 flows, the AC-26 upgrade and rollback scenario, and the macOS parts of the AC-12 to AC-19 and AC-25 rows, and each of the 12 AWS requests once against AWS on macOS; done: an evidence line under each criterion exercised (AC-28, AC-20, AC-26, AC-12, AC-13, AC-14, AC-15, AC-16, AC-17, AC-18, AC-19, AC-25)
      Progress: 2026-11-22, on MacBook-Pro (macOS 26.6.2) with the owner's profiles, the device code approved through auth-refresh's admin lane.
      - **AC-26:** with SSM Connect's preferences, Application Support folder, `~/.ssh/config` and the 0.7.0 app backed up, `brew upgrade --cask ssm-connect` installed the current release (0.7.1), and its menu showed the multi-user profile authorized, the editor lease, Reconnect Existing Workspace with its recovery notice, Restore Editor Setup and web forwards off. The build from e574f96 replaced it and showed the same menu state.
      - **AC-20 flows in the upgraded app, driven through its own menu with System Events:** Connect took the multi-user desktop through authenticating, resolving, waiting for SSM and tunneling, the agent ensured the user's DCV session, and the app reached connected in 8.7 seconds; Disconnect ended it; web forwards connected and were turned off; Open VS Code ran VS Code's SSH channel through the app's own `ssm-connect-proxy` and its plugin on `AWS-StartSSHSession`. Quitting the app ended the proxy and plugin.
      - **Rollback:** `brew reinstall --cask ssm-connect` restored 0.7.1, which showed the same menu state, and its Open VS Code carried the editor channel through its own proxy again. Against the backup, the profiles, attachments, portable documents, settings, active profile and last instance ID were byte-identical, and the editor recovery document had the same keys and values.
      - **AWS requests on macOS through the client (T36 live run and these flows):** RegisterClient, StartDeviceAuthorization, CreateToken, GetRoleCredentials, DescribeInstances, DescribeInstanceInformation, StartSession (port forward and SSH), SendSSHPublicKey and the presigned GetCallerIdentity.
      - **Remaining:** StartInstances and StopInstances (they need the workstation stopped and started), GetSecretValue (the single-user profile's workstation no longer resolves), and the macOS parts of the AC-12 to AC-19 and AC-25 rows.
- [ ] T28 `docs/specs/cross-platform-client.spec.md` - Windows 11 x64 native acceptance of the AC-12 to AC-19, AC-21, AC-23, AC-25 and AC-27 rows, and each of the 12 AWS requests once against AWS on Windows 11 x64; done: an evidence line under each criterion exercised (AC-28, AC-12, AC-13, AC-14, AC-15, AC-16, AC-17, AC-18, AC-19, AC-21, AC-23, AC-25, AC-27)
      Progress: 2026-11-22, on w11-sandbox (Windows 11 x64, pve VM 103) signed in as `m`, a local administrator whose apps run unelevated, with automatic sign-in (PDS `Set-AutoAdminLogin`), DCV Viewer from AWS's MSI, the owner's multi-user profile imported through the settings window, and the SSO session seeded from the Mac. The tray and settings window were driven with UI Automation from a task in the interactive session.
      - **Install, upgrade and removal (AC-21):** the full-UI MSI upgrades t28.1 to t28.5 showed the files-in-use prompt with only Close SSM Connect and Cancel. With a desktop connected, Cancel exited 1602 and left t28.4 installed and connected on its port; Close ended the shell, helper and plugin sessions and installed t28.5 (exit 0), while the VS Code and DCV Viewer windows kept running. Removal while connected behaved the same way: Cancel left it installed and connected (1602); Close removed it, after one Restart Manager retry prompt raised while VS Code's Remote-SSH relaunched the proxy, and OK finished it (exit 0). On the test release `v0.0.0-t28.7` (run 45005641238, 5e010aa), `winget install --manifest` from its validated manifest needed SmartScreen's More info and Run anyway for the unsigned MSI, then installed build `0.0.0-t28.7+5e010aa3f1b0`, which connected, disconnected and quit; `winget install` over the prior candidate worked the same way. That upgrade, from a VM build made with Swift 6.4.3 to the CI build with 6.4.2, removed eight runtime DLLs and left the helper unable to start: fixed by laying down every file (2bc0375, with a regression check in `Test-Package.ps1` seen failing on t28.7 and passing on t28.8). `winget uninstall` could not find the install until the manifest named the MSI's product code (9627abf); with it, `winget uninstall --manifest` removed the program folder and Start menu entry. Profiles, settings, the editor setup and known hosts stay, as intended. A failed upgrade: with SSM Connect closed, Cancel pressed during the t28.7 upgrade of t28.8 once 33 files had been copied (after RemoveExistingProducts) exited 1602; rollback left t28.8 registered with all 26 files, its user state byte-identical, and it then connected and disconnected.
      - **Desktop (AC-12, AC-23):** tray Connect reached connected in about 7 seconds with the bundled plugin running, the local port listening and DCV Viewer launched; after the one-time server identity check (Trust and Connect, as on macOS) the Viewer showed the authenticated workstation desktop. Disconnect ended the plugin and freed the port. The DCV connection file is deleted five seconds after launch (5e010aa).
      - **Web forwards (AC-13, AC-23):** Start Web Forwards brought up ssh with SOCKS on 11080 and the 4466 forward; the forward and SOCKS each reached the workstation's dashboard, and SOCKS reached an outside site. Stop Web Forwards ended ssh, freed both ports and removed the temporary key folder. This first failed on the temporary key (2ac2453) and works with the in-process key.
      - **Editor (AC-17, AC-23):** after Set Up VS Code wrote the `~/.ssh/config` Include, Open VS Code started VS Code, whose Remote-SSH asked once for the remote platform and then connected through SSM Connect's `ssm-connect-proxy` and its plugin (status bar `SSH: ssm-connect-...`, the remote server found running). This first failed on the single-quoted ProxyCommand (814716e).
      - **Quit, crash and helper loss (AC-18, AC-27):** with the desktop, web forwards and the editor all active, Quit SSM Connect left no helper, plugin, ssh or proxy process, temporary key, lease or connection file; VS Code and DCV Viewer kept running (fixed in 5e010aa, which runs the workflows' quit work when the helper ends). Killing only the shell by PID ended the helper, all three plugin sessions, both ssh processes and VS Code's proxy, started no replacement and freed every port; the two keys and the lease it could not clean up grant nothing, as the lease's owner is gone and the instance accepts a pushed key for 60 seconds only. The helper owns no TCP or UDP endpoint and no named pipe. Killing the helper three seconds into a connect started one replacement and no plugin in the next 40 seconds; a second kill left the core unavailable until Retry Core, as designed. The tray kept showing "tunneling" after that kill until f6eda7c.
      - **Capability refusal (AC-25):** with the bundled plugin removed and the helper's outbound connections blocked and audited by a Windows Firewall rule (Filtering Platform Connection and Process Creation auditing on), Connect, Start Web Forwards and Open VS Code were each refused naming the Session Manager plugin, with no connection attempt logged, no process started and no configuration file changed. A positive-control helper that sends the STS identity request before its preflight logged one blocked attempt (event 5157) under the same check.
      - **Secrets and permissions (AC-19):** every file and folder under SSM Connect's state folder has a protected DACL granting only the user (`known-hosts`, which ssh writes, inherits that). The SSO token cache had the profile's inherited ACL because the client's 0600 chmod does nothing on Windows; it is now written owner-only on every platform (0ac4662, tests seen failing on Windows first). During listProfiles, connect and disconnect, none of the cached access token, refresh token or client secret appeared in the 16 helper frames or its diagnostics, nor in any of 60 files SSM Connect owns (state, program folder, temporary files); the DCV launch event carries only the connection file's path. A temporary second local user, logged on with LogonUser and impersonated, was denied reading the settings, lease, PAC, SSO cache file and a temporary private key, and listing the state and cache folders; the user was deleted afterwards.
      - **Silent renewal (AC-15):** with the cached access token marked expired and its refresh token kept, Connect renewed it through CreateToken's refresh grant, wrote the new token and reached connected, with no browser opened or sign-in asked.
      - **Rejected refresh and explicit sign-in (AC-15):** once the IAM Identity Center session ended, CreateToken's refresh grant was refused (400 InvalidRequestException) and Connect waited for an explicit sign-in, as designed, but the tray only said "authenticating". With 6dc219d the tray reads "Sign in required" and the user is told once to choose Sign In with SSO (confirmed on t28.12). Sign In with SSO then opened the device page; approved through auth-refresh's admin lane with the code checked against the one SSM Connect showed, it signed in, and Connect went through to connected. The connect that had been waiting since before the earlier, unapproved device codes expired had ended with them, so the resume of a pending action is shown by the helper test in 6dc219d rather than natively.
      - **Sign-out (AC-18):** signing out with web forwards and VS Code active left two keys and a lease. WPF exits at WM_QUERYENDSESSION before the shell's WM_ENDSESSION hook (09b654e stops the helper in OnExit; the Linux helper handles SIGTERM, test seen failing first), and an instrumented build showed Windows ending the windowless helper before the shell's request reached it; with d00c87f the helper's hidden window runs its quit work at WM_ENDSESSION, and both a normal sign-out (`shutdown /l` in the session) and a forced one (`logoff`) left no key or lease.
      - **Profile files (AC-14):** saving an attached profile only changed the local copy on Windows and Linux; 38248d3 saves it through the shared checked save, asks for formatting consent once and offers the file's version on a conflict. Natively, the first save of the attached `workstation.json` was refused for consent and then written with it. That save also gave the file's folder a protected DACL for the user alone, which locked the Windows Installer service out of it (1619); afcdea1 replaces only the file, as macOS does.
      - **Managed browser (AC-16):** Open Browser started Chrome with all traffic through SOCKS, decided by the shell; with 8355af1 the helper builds macOS's command line, and Chrome 158.0.8127.37 (now pinned) opened in its own protected profile folder with the PAC that sends only the private suffix through SOCKS, with the user's Chrome profile and the system proxy untouched.
      - **First launch after an install:** the helper's first start after installing took 14 seconds while Defender checked the unsigned executable, beyond the 10-second handshake, so SSM Connect came up "core unavailable"; with 6b9f162 the installer runs it once and the first start took 67 ms. "Core unavailable" was also seen once on a first start shortly after a reboot and not reproduced.
      - **AWS requests on Windows through the client:** CreateToken (refresh grant), GetRoleCredentials, DescribeInstances, DescribeInstanceInformation, StartSession (port forward and SSH), SendSSHPublicKey and the presigned GetCallerIdentity.
      - **AWS requests on Windows, added:** RegisterClient, StartDeviceAuthorization and CreateToken's device grant (the Sign In with SSO above).
      - **Open finding, cancelled upgrade:** after an upgrade is cancelled or fails and rolls back, the previous product stays installed but loses its upgrade code registration, so the next upgrade installs beside it and a later uninstall leaves its files (reproduced on w11-sandbox with t28.18 and t28.7, then a copy of t28.18 under a new product code). Removing the old product late (afterInstallExecute) kept the registration but made a full-UI upgrade fail writing the first file (error 1310), so the early schedule stays until the cause is known.
      - **Disconnect during Connect (AC-18):** the Linux runs (T29) found that Disconnect while connecting was refused as busy in both shells. With 8efc7dd and 3ded8ec on t28.22, Disconnect pressed when the tray showed tunneling brought it to disconnected within two seconds with no plugin process or listener left, and the next Connect reached connected with the Viewer. The plugin count read 0 at tunneling as well, so this run does not show the plugin already running when the cancel came; ubuntu-sandbox showed that part.
      - **Stop and start (AC-28):** with the owner's approval of 2026-11-22, on t28.22 through the tray: Connect, then Stop Workstation sent StopInstances and the tray showed disconnected; EC2 reported the instance stopped after about 7 minutes; Connect then sent StartInstances, waited for running and reached connected 30 seconds later; Disconnect left no plugin. The tray stopped the workstation without the confirmation macOS asks for, which AC-29 now covers.
      - **Remaining:** GetSecretValue (no single-user workstation resolves), the open finding above, and sleep for AC-18.
- [ ] T29 `docs/specs/cross-platform-client.spec.md` - Fedora 43 and Ubuntu 24.04 native acceptance of the same rows, and each of the 12 AWS requests once against AWS on Fedora 43 and Ubuntu 24.04; done: an evidence line under each criterion exercised (AC-28, AC-12, AC-13, AC-14, AC-15, AC-16, AC-17, AC-18, AC-19, AC-21, AC-23, AC-25, AC-27)
      Progress: 2026-11-22, Fedora 43 KDE Plasma Desktop Edition (x86_64, the owner's management workstation) in a headless Plasma session (KWin's virtual backend with kded for the StatusNotifierWatcher), the tray driven over D-Bus (dbusmenu) and the settings window through AT-SPI; the SSO session copied from w11-sandbox.
      - **Install and upgrade (AC-21):** `dnf install` of the prior candidate, then of 0.0.0-t29.1, t29.2 and t29.3 over it, each reporting its build from the installed helper.
      - **Helper start:** the shell never reached its helper ("core unavailable"): the hello written while QProcess was still starting it was dropped (44e823e), and after Retry Core the tray could stay at "Starting…" because a new helper at a freed helper's address was taken for it (a177dda). Both have tests that failed first.
      - **Desktop (AC-12, AC-13):** Connect reached connected with the bundled plugin on the local port; Disconnect ended it. AWS's DCV Viewer package for RHEL 9 cannot install on Fedora 43 (it needs ICU 67, libicuuc.so.67), so the Viewer launch is not tested here; without a Viewer the tunnel stays up, as AC-13 requires.
      - **Web forwards (AC-13):** ssh with SOCKS on 11080 and the 4466 forward; both reached the workstation's dashboard and SOCKS an outside site; the key folder was 0700 and the key 0600.
      - **Editor (AC-17):** Set Up VS Code (pressed through AT-SPI) added the Include to `~/.ssh/config`; Open VS Code started VS Code, whose Remote-SSH resolved the SSM Connect host through `ssm-connect-proxy` and found the remote server running.
      - **Quit and containment (AC-18, AC-27):** Quit with web forwards and the editor on left no ssh, plugin, helper, shell, temporary key, lease or helper unit. With the helper frozen by SIGSTOP, killing the shell ended the helper's unit, the helper and the plugin within 0.33 seconds and freed the port.
      - **Plugin removed (AC-25):** with the bundled plugin moved away, connect, startWebForwards and openEditor were each refused naming the plugin, with no network connect, no process started and no configuration file changed (strace of connect and execve, files hashed before and after). The positive control, the same trace with the plugin in place, recorded the connect.
      - **Silent renewal (AC-15):** with the cached access token marked expired, Connect renewed it through the refresh grant (written 18:02Z, mode 0600) and connected without asking to sign in.
      - **Later builds:** `dnf install` of t29.8 over t29.3 reported its build; the rows below ran on t29.8.
      - **Sign In with SSO (AC-15, AC-28):** the helper's signIn registered a new client, started the device authorization and, once the device page was approved through auth-refresh's admin lane with its code checked against the helper's, received the token through CreateToken's device grant and reported ready after 27 seconds; the cache was rewritten 0600.
      - **Profile files (AC-14):** an attached copy of the profile file (mode 0640) through the helper's commands: the first save was refused for formatting consent; with consent the file was replaced through a rename (new inode), kept 0640 and left no temporary file; after a change outside SSM Connect the save failed with fileConflict and left the file as changed; applying the file's changes loaded its version.
      - **Secrets and permissions (AC-19):** with Connect, web forwards and VS Code active, none of the cached access token, refresh token or client secret appeared in SSM Connect's settings or state, the shell's log, the user journal or any process's arguments. Every folder SSM Connect made is 0700 and every file it wrote 0600; `known-hosts`, which ssh writes, is 0644 inside a 0700 folder. The shared `~/.aws/sso/cache` folder, made earlier by other tools, keeps its 0755.
      - **Sign-out (AC-18):** logging out stops the user's application scopes; stopping the shell's scope with Connect, web forwards and VS Code active took 324 ms, and the helper's quit work removed both temporary keys and the lease, with no ssh, plugin, helper, shell or helper unit left.
      - **Remaining on Fedora:** the AC-16 row: Fedora's Zen is a Flatpak, which managed browsing does not support, and Google's Chrome is not installed there.
      Progress: 2026-11-22, Ubuntu 24.04 on a new VM, ubuntu-sandbox (pve 104, a linked clone of the 9100 template, ubuntu-desktop-minimal), in a headless GNOME Shell 46 session (`--headless --virtual-monitor`, the AppIndicator extension for the tray); the tray driven over D-Bus as on Fedora.
      - **Install and upgrade (AC-21):** `apt install` of the prior candidate, then of 0.0.0-t29.3 to t29.8 over it, each reporting its build from the installed helper.
      - **Desktop (AC-12, AC-13):** Connect reached connected and started AWS's DCV Viewer 2026.0.14555 (DEB, SHA-256 checked). The first Viewer start in the fresh session took about 70 seconds, longer than the five seconds after which SSM Connect deletes the connection file, so that Viewer found no file; a copy of the file reached the certificate prompt (the same SHA-1 fingerprint as on Windows), and after Trust & Connect the workstation desktop. Every later Connect started the Viewer, which opened the desktop by itself. Open finding for the owner: the five-second deletion assumes a Viewer that starts within that time.
      - **Web forwards (AC-13):** ssh with SOCKS on 11080 and the 4466 forward. The forward and SOCKS both reached the workstation's dashboard server, and SOCKS reached outside sites (an HTTPS fetch of example.com was refused by the workstation network's filter, others returned 200); the key folder was 0700 and the key 0600.
      - **Editor (AC-17):** Qt's accessibility tree stayed empty in this headless GNOME session, so the setup ran as the helper's installEditorSetup command, the command Set Up VS Code sends, which wrote the Include. Open VS Code from the tray started `code --new-window --remote ssh-remote+ssm-connect-<profile>` in its own scope. VS Code 1.147 cannot open a window in this session (its Xwayland hangs on connect and Electron ignores the Wayland hint), so the same command line ran with `--ozone-platform=wayland`: Remote-SSH resolved the host through `ssm-connect-proxy`, found the existing server and connected.
      - **Managed browser (AC-16):** with web forwards on, Open Browser hung the helper. Foundation's Process on Linux waits for every child on one thread, and when ssh closed its inherited descriptors that thread sat in waitpid for ssh, so the chrome --version probe was never reaped and the helper ignored stdin EOF and SIGTERM (gdb thread dump). 4b4f38b waits for each child on its own; its test failed first. After it, Chrome 158.0.8127.36 (pinned in af0e2d1) opened in its own 0700 profile folder with the PAC that sends only the private suffix through SOCKS 11080 and everything else direct; Chrome's default folder gained only its crash report folder.
      - **Cancellation (AC-18):** a helper whose stdin closed four seconds into Connect exited and left its plugin running: a cancelled start never ended the plugin (65218a5, test failed first). With t29.6 the same run reached tunneling, was cancelled and left no plugin. Disconnect pressed during Connect was refused as busy and the connect carried on (8efc7dd lets Disconnect cancel a running Connect in both shells; tests failed first on Linux and on w11-sandbox).
      - **Quit and containment (AC-18, AC-27):** Quit with web forwards and the editor on ended the shell and helper within 956 ms and left no ssh, plugin, proxy, helper, shell, temporary key, lease, helper unit or listener. With the helper frozen by SIGSTOP, killing the shell made the helper's unit inactive after 37 ms, and the helper and plugin were gone after 351 ms with the port freed.
      - **Plugin removed (AC-25):** as on Fedora, all three actions were refused naming the plugin, with 0 network connects, 0 processes started and 0 configuration files changed; the positive control traced 33 connects.
      - **Cancellation, continued:** with t29.7, Disconnect during tunneling ended the plugin and freed the port, and the next Connect reached connected; the tray kept showing tunneling, because a cancelled connect sent no further state (3ded8ec waits for the teardown and sends its state; the helper test failed first). With t29.8 the tray showed disconnected 90 ms after Disconnect.
      - **Sign In with SSO (AC-15, AC-28):** as on Fedora, RegisterClient, StartDeviceAuthorization and CreateToken's device grant, approved through the admin lane with the code checked, ready after 37 seconds, the cache rewritten 0600.
      - **Profile files (AC-14):** the same run as on Fedora gave the same results: consent first, a rename that kept 0640 and left no temporary file, the conflict refused with the file untouched, and the file's version applied. Importing the same file again was refused as already attached.
      - **Secrets and permissions (AC-19):** the same search as on Fedora found no token or secret. SSM Connect's folders are 0700 and its files 0600, except ssh's `known-hosts`; Chrome's own files in the managed profile folder keep Chrome's modes inside the 0700 folder. A helper killed with SIGKILL leaves its temporary key folder (0700, key 0600); EC2 Instance Connect accepts a pushed key for 60 seconds only, so it gives no reusable access.
      - **Sign-out (AC-18):** stopping the shell's scope with Connect, web forwards and VS Code active took 332 ms and left no key, lease, process, unit or listener.
      - **Open finding for the owner:** the Windows and Linux shells lack three actions macOS has: deleting a profile, Restore Editor Setup (which removes the owned Include) and Stop Remote Access; the helper has no command for any of them. On Fedora the Include was removed by hand after the run.
      - **Environment notes:** the headless GNOME Shell crashed once (signal 11 in its init.js) and was restarted; the Viewer and VS Code limits above belong to this headless session.
      - **AWS requests on Fedora and Ubuntu (AC-28):** the connect, web forwards and editor flows that sent CreateToken's refresh grant, GetRoleCredentials, DescribeInstances, DescribeInstanceInformation, StartSession (port forward and SSH) and SendSSHPublicKey on Windows ran on both, and Sign In with SSO sent RegisterClient, StartDeviceAuthorization and CreateToken's device grant.
      - **Stop and start (AC-28):** with the owner's approval of 2026-11-22, through the helper's commands on t29.8 (`~/.local/share/ssm-acceptance/workstation-power.sh`): on Fedora, Connect and stopWorkstation sent StopInstances, the instance was stopped after about 9 minutes, and the next Connect sent StartInstances and connected about 30 seconds later; on Ubuntu, the same stop, and the next Connect started the stopped instance (running 51 seconds later) but then failed because the plugin did not open the local port within its 15 seconds. That wait is the same on macOS (`SSMConnectMacOS/SSHTunnel.swift:64`, `BundledPluginTunnel`), and the workflow retries only a desktop that is not ready yet, not a plugin that missed its port, on every platform; the same miss happened once on a running instance on Fedora. Observation for the owner, not a Windows or Linux difference.
      - **Remaining on Linux:** GetSecretValue (as on Windows), and sleep for AC-18.
- [ ] T30 `docs/specs/cross-platform-client.spec.md` - measure the refactored macOS app and the Windows and Linux clients with T1 on the T2 hosts; done: every metric compared with its limit in an AC-22 evidence line (AC-22)
- [ ] T31 `docs/specs/cross-platform-client.spec.md` - inspect each built dependency graph and artifact for duplicate production workflows and for any aws-sdk-swift, aws-crt-swift or Smithy module, and rebuild each platform's release path on its own; done: AC-11 and AC-24 evidence lines, and an AC-28 evidence line combining the T37-T40 parity results, the T27-T29 native operation results and these inspections (AC-11, AC-24, AC-28)
      Progress: 2026-11-22, the Windows and Linux part. Resolved package graphs: SSMConnectKit, its AWSClient package and the helper spike pin only swift-asn1, swift-crypto and Yams; aws-sdk-swift, aws-crt-swift and smithy-swift appear only in `SSMConnectKit/Tools/FixtureRecorder`, the development tool that records SDK fixtures and is not built into any artifact. Built artifacts: in the t29.8 `.deb` and `.rpm` (helper, editor proxy, Qt shell) and the files installed from the t28.22 MSI, no name of an SDK, CRT or Smithy module occurs (strings and Select-String for AWSSDK, AwsCommonRuntimeKit, aws_c_common, ClientRuntime, SmithyHTTPAPI and AWSClientRuntime), while the helpers carry SSM Connect's own client (about 2,100 to 2,300 SSMConnectAWSClient symbols); the Qt and WPF shells carry none. Duplicate workflows: the shell sources (2,327 lines of C# and C++) contain no AWS call, endpoint or workflow logic. Remaining: the macOS artifact, rebuilding each release path on its own, and `project.yml`'s comment that still says aws-sdk-swift is declared in the package.

The parity revision (accepted 2026-11-23) adds T50 to T62. AC-30 comes first because it is small; each failing test precedes the change that makes it pass.

- [x] T50 `SSMConnectKit/Tests/SSMConnectHelperTests/HelperCommandTests.swift` - failing helper tests for the DCV window: the default is 120 seconds, connect reports connected while the file exists, the file is gone after an injected window, stdin EOF through `HelperExit` removes a waiting file, a connect removes an untracked file older than the window, two connects 10 seconds apart and a five-minute forward clock change keep the helper's own file until its deadline, and the missing-Viewer message names the Windows or Linux install; done: `swift test --filter HelperCommandTests` fails on exactly these cases on Linux (AC-30)
  - Evidence: 2026-11-23, `swift test --filter HelperCommandTests` in swift:6.4.2-noble: 19 tests, and exactly the four new cases fail for the stated reasons: the window constant is 5 seconds, the waiting file survives `HelperExit.end`, the 200-second-old leftover survives a connect, and the missing-Viewer message names `/Applications` and brew. The reconnect case passes already, because today's helper never sweeps on connect; it guards the T51 sweep against deleting a live file. The tests need three seams added with today's behavior: `ShellDCVLauncher.viewerReadWindow` (still 5 seconds), an injectable clock and an empty `removeWaitingFiles()`, and a `quit:` handler on `HelperRuntime` (default `.shared`) so a test ends one helper without running other fixtures' quit work, which had stalled the parallel suite.
- [ ] T51 `SSMConnectKit/Sources/SSMConnectHelperCore/ShellRequests.swift`, `SSMConnectKit/Sources/SSMConnectHelperCore/HelperRuntime.swift`, `SSMConnectKit/Sources/SSMConnectWorkflow/DCVLaunching.swift` - the 120-second window, the helper's record of its own files, quit cleanup registered with the quit handlers, the connect sweep and the per-platform message; done: T50 passes on Linux and on w11-sandbox, and the macOS launcher and message tests pass unchanged on the Mac (AC-30)
      Progress: 2026-11-23, the helper keeps each connection file 120 seconds on its own task, remembers the files it keeps, removes them in its quit work (registered on the runtime's quit handler) and sweeps untracked files older than the window at each connect; the missing-Viewer message names the Windows MSI or the Linux packages, and macOS keeps its text and its 5-second launcher. T50 passes: `swift test` in swift:6.4.2-noble passes every suite (43 helper tests), and the same package suite passes on w11-sandbox (`kittest.ps1`, 40 helper tests). Remaining: the macOS launcher and message tests on the Mac, which is offline.
- [ ] T52 `docs/specs/cross-platform-client.spec.md` - on ubuntu-sandbox with the T51 build, log the session out and in so the Viewer starts cold, then Connect; done: an AC-30 evidence line showing the desktop opened with no copied file (AC-30)
- [ ] T53 `contracts/macos-parity.json`, `scripts/check-macos-parity.mjs` - the inventory of every macOS menu, settings, profile editor, log and About control (title, file and symbol, when it is offered and enabled, and its helper command, `shell`, or cancel-type entry with its no-command form) and the check that reads the macOS views; done: the check fails for the removed clipboard auto-clear entry, an unlisted control in a copy of a view and an unknown control type, and passes on the real views (AC-29)
- [ ] T54 `SSMConnectKit/Tests/SSMConnectHelperTests/ParityCommandTests.swift` - failing tests: every inventory command is in the helper's command table, and each new command keeps its macOS rule (delete refused for the last profile, the active profile moving to the first remaining one, the attached file left untouched, `cancelEditorRecovery` clearing a pending replacement and automatic recovery with no command running, `cancelForwardingRecovery`, and unrelated workflows left running); done: they fail on the missing commands (AC-29)
- [ ] T55 `SSMConnectKit/Sources/SSMConnectHelperCore/HelperRuntime.swift` - the profile and settings commands: add, duplicate, delete, import from `~/.aws/config`, export, save a local copy, review and apply outside changes, locate file, detach, and reading and saving the app settings (connect on launch, reconnect, clipboard auto-clear); done: their T54 tests pass (AC-29)
- [ ] T56 `SSMConnectKit/Sources/SSMConnectHelperCore/HelperRuntime.swift` - the connection and editor commands and state: retry authorization, copy password, reconnect, reconnect existing workspace, renew editor access, approve replacement, `cancelEditorRecovery`, stop remote access, restore editor setup, and events for pending changes, connection details, the masked password, the lease and recovery lines and a pending replacement; done: their T54 tests pass (AC-29)
- [ ] T57 `SSMConnectKit/Sources/SSMConnectHelperCore/HelperRuntime.swift`, `SSMConnectKit/Sources/SSMConnectHelperCore/ShellRequests.swift` - the web forwards and log commands: turn on and off, approve forwarding replacement, `cancelForwardingRecovery`, open a local forward, copy PAC URL, reveal PAC file through a new `reveal` shell request, apply browser setup with the browser mode choice, restore browser settings, apply changes, and reading and clearing the log with its events; done: their T54 tests pass and every inventory command is in the table (AC-29)
- [ ] T58 `linux/tests/shell_test.cpp`, `linux/tests/fakes.h` - failing Qt drive-throughs from the inventory: every control exists and sends its command after macOS's confirmation; visibility and enabled state in disconnected, connecting, connected and recovering states, with unavailable controls sending nothing; cancel-type controls cancelling a running command and sending their no-command form otherwise; and a delayed completed Open VS Code result followed by one `cancelEditorRecovery`; done: `scripts/linux/shell-tests.sh` fails on exactly these (AC-29)
- [ ] T59 `linux/src/`, `linux/qml/` - the Linux shell controls: tray items with their availability, the settings section, the full profile editor, the profile and file actions, the attachment actions, the log and About windows, the `reveal` request and the cancel handling; done: T58 passes on Fedora (AC-29)
- [ ] T60 `windows/tests/SSMConnect.App.Tests/ShellDriveThroughTests.cs`, `windows/tests/SSMConnect.App.Tests/HelperHostTests.cs` - the same failing drive-throughs for the WPF shell; done: they fail on w11-sandbox on exactly these (AC-29)
- [ ] T61 `windows/src/SSMConnect.App/` - the Windows shell controls, as T59; done: T60 passes on w11-sandbox (AC-29)
- [ ] T62 `docs/specs/cross-platform-client.spec.md` - with T57, T59 and T61 built, exercise each new control once natively on w11-sandbox, Fedora 43 and Ubuntu 24.04 against the owner's profile; done: an AC-29 evidence line per platform (AC-29)

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
| 2026-11-18 | R-20 | spec | `654c59e` | n/a | n/a | accepted by owner |
| 2026-11-21 | R-21 | spec | `9f2969f` | gpt-6.1-sol | procedural | No blocking findings; three should-fix |
| 2026-11-21 | R-22 | spec | `8d04477` | gpt-6.1-sol | procedural | No blocking findings; three should-fix |
| 2026-11-21 | R-23 | spec | `da7d96c` | gpt-6.1-sol | procedural | No blocking findings; two should-fix and one nit |
| 2026-11-21 | R-24 | spec | `b079c3b` | gpt-6.1-sol | procedural | No blocking findings; one should-fix |
| 2026-11-21 | R-25 | spec | `e74903d` | gpt-6.1-sol | procedural | NO FINDINGS |
| 2026-11-21 | R-25 | spec | `e74903d` | n/a | n/a | accepted by owner |
| 2026-11-22 | R-26 | spec | `a44b14c` | gpt-6.1-sol | procedural | No blocking findings; four should-fix |
| 2026-11-23 | R-27 | spec | `0a7fe89` | gpt-6.1-sol | procedural | No blocking findings; one should-fix and one nit |
| 2026-11-23 | R-28 | spec | `2cc723c` | gpt-6.1-sol | procedural | No blocking findings; two should-fix |
| 2026-11-23 | R-29 | spec | `3bf2897` | gpt-6.1-sol | procedural | No blocking findings; one should-fix (a first pass at this commit could not read the conventions and returned no usable records) |
| 2026-11-23 | R-30 | spec | `3c84f9a` | gpt-6.1-sol | procedural | NO FINDINGS |
| 2026-11-23 | R-30 | spec | `3c84f9a` | n/a | n/a | accepted by owner |

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

### R-21

FINDING: F-01
KIND: factual
SEVERITY: should-fix
WHERE: Design / AWS client, lines 382-394; Acceptance Criteria / AC-28; Test Plan / AC-28; Tasks / T42, T43; Sources / clock-skew decision, lines 1228-1229
EVIDENCE: The new clock-skew revision defines storing and retaining corrections but omits their removal. The pinned [AWSClockSkewProvider](https://github.com/awslabs/aws-sdk-swift/blob/b60b2f0805a6177cf0bc181c973134281fbff972/Sources/Core/AWSClientRuntime/Sources/AWSClientRuntime/ClockSkew/AWSClockSkewProvider.swift#L24-L47) clears an existing correction when a subsequent skew error has a near, missing or invalid Date header. Its calculation also uses the unadjusted local timestamp: [SigV4Signer](https://github.com/smithy-lang/smithy-swift/blob/31336dfea2e448523630ea1fe4d83ddc1156de3c/Sources/SmithyHTTPAuth/SigV4Signer.swift#L55-L79) records Date() separately from the corrected signing date at line 142. Design's “time it signed at” does not distinguish those timestamps. The listed proofs can pass without establishing recovery when the local clock changes after a correction was learned.
PROPOSAL: Define calculation from the unadjusted local timestamp and the SDK's transitions for clearing an existing correction. Extend T42 and AC-28's proof with an already-corrected client whose local clock is subsequently repaired, plus missing and invalid Date headers.

FINDING: F-02
KIND: factual
SEVERITY: should-fix
WHERE: Design / AWS client, per-host correction and changed-offset retry, lines 382-391; Acceptance Criteria / AC-28; Test Plan / AC-28; Tasks / T42, T43
EVIDENCE: The revision introduces shared mutable clock state without defining concurrent updates. The pinned [ClockSkewStore](https://github.com/smithy-lang/smithy-swift/blob/31336dfea2e448523630ea1fe4d83ddc1156de3c/Sources/ClientRuntime/ClockSkew/ClockSkewStore.swift#L10-L41) serializes comparison, replacement and the returned changed flag in one actor operation. With two simultaneous AuthFailure responses for the same host and offset, only the first update changes that store. Separate reads and writes could let both callers report a change and retry. Every stated sequential skew check could pass while that behavior differs from the SDK.
PROPOSAL: Specify process-wide sharing and atomic comparison, update and changed-result semantics. Add concurrent same-host failure checks that compare resulting retries with the pinned SDK.

FINDING: F-03
KIND: factual
SEVERITY: should-fix
WHERE: Context / Owner summary, lines 71-93; Context / Observed credential-free portability results, lines 183-185; Design / First increment; Tasks / T32-T43, T4, T5; Sources / clock-skew decision
EVIDENCE: Frontmatter identifies clock-skew correction as the current revision, but the owner summary does not explain that change since the latest acceptance. It still describes authentication and transports as unverified and authorization as limited to credential-free spikes. T5 now records native SSO authorization, refresh and usable SSM traffic on Windows and Fedora, while T33 and T35 record completed client checks. These records are not independently established native proof in this review, but their presence conflicts with the summary's unqualified account of progress. The pinned feature-document standard requires refreshing the summary when proof or decisions change.
PROPOSAL: Refresh the summary to explain the clock-skew addition and distinguish recorded subset results from remaining full-workflow acceptance. Reconcile the authorization wording with the authority actually granted for completed tasks, preserving separate permission boundaries for future operations.

### R-22

FINDING: F-01
KIND: factual
SEVERITY: should-fix
WHERE: Context / Owner summary:76-77; Design / AWS client:380-406; Acceptance Criteria / AC-28; Test Plan / AC-28; Tasks / T39, T35, T42, T43
EVIDENCE: The pinned SDK's [DefaultRetryStrategy](https://github.com/smithy-lang/smithy-swift/blob/31336dfea2e448523630ea1fe4d83ddc1156de3c/Sources/SmithyRetries/DefaultRetryStrategy/DefaultRetryStrategy.swift) checks a shared retry quota before retrying, including clock-skew retries. Its [RetryQuota](https://github.com/smithy-lang/smithy-swift/blob/31336dfea2e448523630ea1fe4d83ddc1156de3c/Sources/SmithyRetries/DefaultRetryStrategy/RetryQuota.swift) defines consumption, exhaustion and replenishment. The document promises SDK-default retry parity but specifies none of these transitions. The recorder explicitly creates fresh clients to prevent quota carryover at SSMConnectKit/Tools/FixtureRecorder/Sources/FixtureRecorder/Retries.swift:45-54. Today's authorization flow reuses one SDK client across device-token polling at AWSAuthProvider.swift:142-198, so quota depletion can affect actual behavior. A replacement without quotas can pass every listed isolated scenario while continuing retries the SDK would refuse.
PROPOSAL: Define quota scope and transitions to match the pinned SDK. Add repeated-call parity checks covering exhaustion, replenishment and clock-skew retries when quota is exhausted.

FINDING: F-02
KIND: factual
SEVERITY: should-fix
WHERE: Context / Owner summary:89-94; Design / First increment:434-439; Test Plan / AC-23; Tasks / increment description:684-688, T4, T5
EVIDENCE: T5 is marked complete although its cited driver does not establish usable remote traffic or pending-action cancellation. HelperSpike/main.swift:175-187 reports tunnelReady after tcpConnects; lines 198-226 only connect to the local listener and close, without sending or receiving payload. drive.py:83-116 then refreshes, stops an established tunnel and quits. The helper has no cancel command at main.swift:51-69, and its input loop awaits each command at lines 237-242 before reading another. These checks can succeed without proving the remote forwarding path or cancellation of an in-flight action, both required before broad extraction.
PROPOSAL: Preserve the recorded subset results while identifying these missing checks. Add explicit tasks before extraction that verify a response through the remote service and cancel a pending action on both native feasibility targets.

FINDING: F-03
KIND: factual
SEVERITY: should-fix
WHERE: Context / Owner summary:84-87; Design / AWS client:407-415; Tasks / T5
EVIDENCE: The summary added when addressing R-21 says the motivating clock failure occurs where today's app would recover. However, T5's driver requests identity before DescribeInstances or StartSession at drive.py:71-83. Today's STSIdentityResolver.swift:16-22,42-46 signs with local time, sends once and rejects a non-success response without learning clock skew. Design explicitly preserves that behavior at lines 411-415. SDK clock correction therefore does not establish recovery for the complete motivating sequence, and the revised client deliberately retains this limitation.
PROPOSAL: Limit the recovery claim to SDK-managed signed requests and explain that the direct STS identity path still fails under clock skew. Preserve the selected single-attempt STS policy.

### R-23

FINDING: F-01
KIND: factual
SEVERITY: should-fix
WHERE: Frontmatter / covers:7-17; Context / Owner summary:90-97; Design / First increment:447-452; Test Plan / AC-23; Tasks / T4, T5, T44
EVIDENCE: The coverage list includes spikes/swift-portability/ but omits spikes/helper-feasibility/. T4 and the new T44 modify that omitted directory, and T5 relies on its driver for the mandatory native feasibility proof before extraction. The pinned feature-document standard requires covers to include every path affecting the feature. These proof-producing files therefore fall outside the declared coverage used by freshness and feature-tree checks. The T44 addition addressing R-22 F-02 leaves this omission in place.
PROPOSAL: Add spikes/helper-feasibility/ to covers so changes to the helper, driver and build scripts participate in feature verification.

FINDING: F-02
KIND: factual
SEVERITY: should-fix
WHERE: Tasks / T43:725, T45:727
EVIDENCE: The quota work addressing R-22 F-01 puts implementation in T43, whose completion requires T45 to pass. T45 appears later and must first demonstrate tests failing because the client has no retry quota. Following the listed order cannot establish both done conditions: T43 requires unwritten tests, and completing its quota implementation removes T45's required failing state. The pinned standard requires dependency order with failing tests first.
PROPOSAL: Move T45 before T43, preserving both task IDs. Record its expected failure before implementing the quota.

FINDING: F-03
KIND: factual
SEVERITY: nit
WHERE: Tasks / T4:728
EVIDENCE: T4 describes the helper as built from current SSO, SSM and plugin sources behind stub UI ports. spikes/helper-feasibility/run.sh:11-12 and run.ps1:10-11 copy only SSMSessionResponse, AWSRegion and IdentityMapper. HelperSpike/main.swift:78-127 implements its own authorization and refresh harness, and lines 148-195 implement its plugin orchestration. The task overstates source reuse, although its native-build done condition is unchanged.
PROPOSAL: Describe T4 as a feasibility harness using the AWS client and the three reused portable types. Retain the distinction between this subset evidence and final workflow integration.

### R-24

FINDING: F-01
KIND: factual
SEVERITY: should-fix
WHERE: Design / AWS client, direct STS request; Acceptance Criteria / AC-28; Test Plan / AC-28; Tasks / T35, T36
EVIDENCE: T35 is checked and explicitly includes moving STSIdentityResolver onto the shared client. However, SSMConnectKit/Sources/SSMConnectKit/Auth/STSIdentityResolver.swift:16-25 still owns its URLSession transport, and lines 42-46 still send through that transport. STSPresigner.swift:16 also retains the hardcoded amazonaws.com host. Only its signer delegates to SSMConnectAWSClient. The standalone package checks cited under T35 cannot exercise this production resolver. T36 describes switching the SDK adapters but does not explicitly carry this unfinished direct-request migration.
PROPOSAL: Preserve the standalone client results while recording the production STS adapter migration as unfinished and assigning it an unchecked task. Require a production-resolver transport test establishing shared-client use, the China endpoint and the preserved single-attempt behavior.

### R-25

NO FINDINGS

### R-26

FINDING: F-01
KIND: factual
SEVERITY: should-fix
WHERE: Context / Owner summary:96-102; Scope / Windows and Linux interface parity:237-239; Design / Windows and Linux parity with the macOS interface:618-644; Acceptance Criteria / AC-29; Test Plan / AC-29
EVIDENCE: The new parity section says its view-reading check lists every control, but its enumerated control types omit Stepper. SettingsView.swift:59-64 uses a Stepper for clipboard auto-clear seconds, a setting Design explicitly includes at lines 618-619. The scanner and inventory-driven tests can therefore pass while that setting has no inventory entry or Windows/Linux control. AboutView.swift:73-90 also contains Link and DisclosureGroup controls outside the enumerated types.
PROPOSAL: Make discovery cover the control types present in the selected macOS surfaces, including Stepper. Demonstrate that removing the clipboard-setting entry causes the check to fail.

FINDING: F-02
KIND: factual
SEVERITY: should-fix
WHERE: Context / Owner summary:96-102; Scope / Windows and Linux interface parity:237-239; Design / Windows and Linux parity with the macOS interface:588-644; Acceptance Criteria / AC-29; Test Plan / AC-29
EVIDENCE: AC-29 requires macOS availability rules, but its shell proofs check control existence, command frames and confirmations. They never require visibility or enabled-state assertions. MenuContentView.swift:94-103 offers Stop Workstation only while connected, and lines 117-122 disable recovery entry during opening while offering Cancel Recovery during recovery. Existing TrayMenu.cs:11-15 and linux/src/tray.cpp:11-15 create always-enabled actions. Extending those menus with every command and confirmation can satisfy the stated drive-through checks while retaining incorrect availability.
PROPOSAL: Add expected visibility and enabled states to the parity checks. Exercise representative disconnected, connecting, connected and recovering states, asserting that unavailable controls cannot dispatch commands.

FINDING: F-03
KIND: judgement
SEVERITY: should-fix
WHERE: Context / Owner summary:96-102; Design / Integration and feasibility:354-379; Design / Windows and Linux parity with the macOS interface:607-611,633-650; Acceptance Criteria / AC-27, AC-29; Test Plan / AC-27, AC-29
EVIDENCE: The new parity scope includes Cancel Recovery, Stop Remote Access and Restore Editor Setup, while requiring every new command to follow one-command-per-workflow admission. HelperSession.swift:108-110 rejects another command for a running workflow before executing its handler; cancellation instead uses a separate cancel frame at lines 78-79. On macOS, Cancel Recovery is available during recovery and cancels its active task directly (MenuContentView.swift:121-122; RemoteDevelopmentStateMachine.swift:159-168). The document does not specify how these interrupting controls reach that behavior while their workflow already has an admitted command. The command-table inventory requirement also does not explain how a cancellation frame qualifies.
PROPOSAL: Raise an owner question selecting the interruption policy for these controls, preferably using the existing cancellation path where appropriate. Specify their inventory representation and test interruption during an active workflow, terminal results and preservation of unrelated workflows.

FINDING: F-04
KIND: factual
SEVERITY: should-fix
WHERE: Context / Owner summary:103-107; Design / DCV connection file lifetime:660-669; Acceptance Criteria / AC-30; Test Plan / AC-30
EVIDENCE: The new lifetime section says quit cleanup and the next-connect sweep already remove waiting or orphaned DCV files. ShellRequests.swift:60-77 implements delayed deletion and a sweep method, but registers no quit cleanup. HelperExit.end at HelperRuntime.swift:422-424 shuts down commands and runs registered handlers; ConnectionStateMachine.swift:131-140 registers only tunnel termination. The sole production call to dcv.sweepOrphanedFiles is ConnectionStateMachine.onLaunch at lines 170-172, and neither the helper entry point nor HelperRuntime invokes that method. The helper's connect path at HelperRuntime.swift:286-300 does not sweep. These are missing cleanup paths, not behavior preserved by changing the delay.
PROPOSAL: Describe quit cleanup and the next-connect sweep as implementation work required by this revision. Require tests through the production helper shutdown and connect entry points, establishing cleanup before the 120-second timer expires and after a simulated crash.

### R-27

FINDING: F-01
KIND: factual
SEVERITY: should-fix
WHERE: Context / Owner summary:100-104; Design / Windows and Linux parity with the macOS interface:610-613,650-669; Acceptance Criteria / AC-29; Test Plan / AC-29
EVIDENCE: The cancellation policy added after R-26 F-03 assumes a running helper command always exists. Replacement review outlives its command: RemoteDevelopmentStateMachine.swift:378-382 sets pendingReplacement and throws, while HelperRuntime.swift:325-334 finishes openEditor and HelperSession.swift:140-142 removes the command. Automatic editor recovery also starts independently through RemoteDevelopmentStateMachine.swift:412-439 after the opening command finishes. A cancel frame only cancels running[id] at HelperSession.swift:78-79, so it cannot clear these states. The new proof exercises cancel controls only with a command running and can pass while these controls do nothing during replacement review or automatic recovery.
PROPOSAL: Define how cancellation reaches the shared workflow when no admitted command remains, raising an owner question if that requires changing the selected policy. Add proofs for replacement review and automatic recovery after the initiating command has terminated, checking the resulting workflow state and preservation of unrelated workflows.

FINDING: F-02
KIND: factual
SEVERITY: nit
WHERE: Design / DCV connection file lifetime:693-698
EVIDENCE: The cleanup explanation addressing R-26 F-04 says the helper's quit work runs only registered tunnel termination. RemoteDevelopmentStateMachine.swift:83 and WebForwardsStateMachine.swift:65 also register quit handlers, and HelperExit.end runs those handlers at HelperRuntime.swift:422-424. The narrower claim that DCV file cleanup is missing remains correct.
PROPOSAL: Say that existing quit handlers clean up desktop, editor and forwarding resources but do not remove waiting DCV connection files.

### R-28

FINDING: F-01
KIND: factual
SEVERITY: should-fix
WHERE: Context / Owner summary:97-103; Design / Integration and feasibility:356-381; Design / Windows and Linux parity with the macOS interface:657-680; Acceptance Criteria / AC-27, AC-29; Test Plan / AC-27, AC-29
EVIDENCE: The fallback added after R-27 F-01 distinguishes a running command from recovery that outlives it, but leaves their transition undefined. HelperSession.swift:140-142 removes the running command before sending its result, and lines 78-79 ignore cancellation for an absent command. A shell can therefore send cancel while it still considers Open VS Code running, after the helper has finished it with pendingReplacement still set (RemoteDevelopmentStateMachine.swift:378-382). The late cancel does nothing, and the arriving terminal result removes the shell's pending entry, so its cancellation timeout does not recover the situation (linux/src/helper_host.cpp:159-174; windows/src/SSMConnect.App/Helper/HelperHost.cs:166-177,300-305). The proof tests running-command and no-command cases separately and can pass while Cancel Replacement Recovery fails at this boundary.
PROPOSAL: Define how the requested workflow cancellation completes when the initiating command finishes before the cancel arrives, preserving generation checks and the prohibition on replaying the original action. Add a deterministic proof that delays terminal-result delivery, sends cancellation after helper completion, and verifies that pending recovery clears without affecting another workflow.

FINDING: F-02
KIND: factual
SEVERITY: should-fix
WHERE: Context / Owner summary:104-110; Design / DCV connection file lifetime:694-715; Acceptance Criteria / AC-30; Test Plan / AC-30
EVIDENCE: The new next-connect sweep has no proof distinguishing crashed-helper leftovers from files still within a live helper's 120-second window. ShellRequests.swift:73-77 implements sweepOrphanedFiles by deleting every matching DCV file in its directory, without checking its owner or pending deletion. Connecting this existing method to each helper connect would pass the specified leftover-file proof, but a disconnect and reconnect within 120 seconds would delete the preceding connection file early. AC-30 permits early removal at Quit or following a crash, not an ordinary reconnect.
PROPOSAL: Specify that the sweep preserves files whose live launch window has not expired. Add a back-to-back connect proof that verifies the earlier file survives until its own deadline while genuine crashed-helper leftovers are removed.

### R-29

FINDING: F-01
KIND: factual
SEVERITY: should-fix
WHERE: Context / Owner summary:105-109; Design / DCV connection file lifetime:709-724; Acceptance Criteria / AC-30; Test Plan / AC-30
EVIDENCE: The modification-time rule added to address R-28 F-02 does not reliably preserve a live file's 120-second window. ShellRequests.swift:64-69 writes the file before starting its duration-based deletion task. If the system clock advances five minutes ten seconds later, a reconnect's modification-time sweep sees a 310-second-old file even though 110 seconds remain in its launch window. It can delete the file before a cold Viewer reads it. The proposed back-to-back connect proof keeps the clock unchanged and would pass this implementation.
PROPOSAL: Exclude files whose launch windows remain active in the current helper from the modification-time orphan sweep. Add a controlled-clock reconnect check showing that a forward clock correction cannot delete those files early.

### R-30

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
  named comparison hosts (Q15); clock-skew correction matching the SDK, after
  the T5 live run exposed the gap (owner decision 2026-11-21); after T3 found no Windows support upstream, one
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
