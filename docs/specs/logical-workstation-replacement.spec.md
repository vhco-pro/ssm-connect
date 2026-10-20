# SPECIFICATION: Same Workspace and Native Forwarding After Workstation Replacement

- **Status:** client implementation shipped in macOS v0.7.0 through PR #31. On 2026-10-20,
  real replacement confirmation, original-window reconnection and native editor workflows
  passed. Current criterion dispositions are in section 9; broader infrastructure, routing
  and isolation acceptance is not complete.
- **Baselines:** v0.6.0 and the PR #28 rolling-lease fix established the original gaps.
  Released v0.7.0 adds the reviewed client rebind and recovery workflow.
- **Outcome:** after an authorized OS/root-image replacement, select the same VS Code Recent
  workspace and reuse native browser/domain-forward settings against the replacement once ready.
- **Related:** [native editor](./remote-vscode.spec.md), [web forwards](./web-forwards.spec.md),
  [browser ownership](./browser-bootstrap.spec.md), [portable profiles](./portable-profiles.spec.md).
- **Combined client scope (2026-10-17):** coordinated with
  [integrated private browsing](./remote-browser-private-dns.spec.md), which consumes the same
  validated logical target but remains gated on a supported Browser-session routing API.
- **Scope:** a cross-boundary client and server/bootstrap contract. This spec does not authorize
  Terraform changes/apply, instance replacement/reboot, production-hold removal or remote changes.

## 1. Required Continuity and Intentional Interruption

The logical workstation survives its disposable physical EC2 instance. Keep the local profile
UUID, SSH authority, saved remote folder, authorized user identity and native routing configuration.
A replacement may have a new instance ID, root filesystem, SSH host keys, owner-bound transport
generation and ephemeral authorization key.

Interruption during replacement is acceptable. Reconnection and **saved state** are required:
project files, user configuration, persisted tools/server data and supported persisted editor/
conversation state must be available under the same user after readiness.

Do not promise that the old desktop, terminal, editor extension-host or live agent process survives
destruction of its VM. Reconnecting to a saved conversation or workspace is distinct from carrying
an in-memory process across machines. This is not the same case as upgrading only the Mac app
while the remote server remains alive.

## 2. Historical Source-Verified Coverage Before v0.7.0

| Surface | Existing behavior | Gap for replacement |
| --- | --- | --- |
| Profile/Recent identity | The SSH authority is derived from the stored local profile UUID, not generated per connection. | Stable naming is necessary but not sufficient for a fresh physical binding. |
| EC2 discovery | The macOS resolver uses the configured tag/region and explicitly rejects zero or multiple eligible matches. | An expected temporary absence needs a bounded replacement state, not a false success or uncontrolled retry. |
| Editor lease/proxy | Account/role/region/selector/user, instance, owner and generation are bound; a different instance is refused. | There is no supported same-logical-workstation rebind that refreshes the owner setup for the original Recent entry. |
| Rolling lease renewal | PR #28 renews a finite lease for the same live owner and exact instance/user. | Physical replacement deliberately remains a terminal identity change, not an automatic lease extension. |
| Native web forwards | Each establishment reauthenticates, re-resolves tags, authorizes a temporary EIC key and creates SSH-over-SSM. | Reconnect is bounded to three attempts; a longer rebuild can end in Error and require another user action. SSM Online is not complete user/service readiness. |
| Editor server | Remote-SSH can reuse a normal existing server installation under the user's home. | A separate always-on VS Code tunnel service is not implied or required by this workflow. Saved state and fresh server startup must be tested on the replacement. |

Existing editor AC-R6/AC-R9 prove or require identity refusal/recovery boundaries; they do not
establish transparent rebuild usability. UPGRADE-01 through UPGRADE-06 concern the Mac app's
lifecycle. Neither closes the new replacement acceptance below.

## 3. Logical Identity and Safe Client Rebinding

### 3.1 Authority

Reuse the same authorized logical profile, including account, role, resource/SSO regions, selector
and intended OS user. Retain unique-target refusal. A matching Name tag alone must not be treated
as proof that an arbitrary new machine is an approved replacement.

Define an explicit trust/intent rule for an expected replacement before implementation. Unexpected
instance, account, selector or user changes remain actionable refusals or require confirmation.
Never silently redirect a healthy existing SSH stream to a different machine.

### 3.2 Coherent Handoff

The owning client/broker must coordinate a fresh physical binding, generation/key authorization,
SSH configuration and target-specific host trust while preserving the stable authority. Old
generation/instance channels must not cross into the replacement or inherit another user's access.

Native SSH may read HostName, IdentityFile and host-key options before ProxyCommand executes.
Rewriting those files only inside the proxy is therefore not an accepted design or proof of
reconnect. The final design must establish a consistent binding for each SSH attempt, account for
concurrent windows/key loading, and demonstrate that the same Recent entry works without manual
host/profile/instance-ID edits or a forced replacement workspace.

Preserve editor host-key checking and verify the replacement's host identity through the accepted
trust flow; do not disable it to obtain a green test. Existing native web forwarding has a separate,
documented SSM-bound host-key policy, so the current implementation must not be described as
providing uniform strict SSH host verification across both paths. Review replacement trust for
each path explicitly; no broader bypass is authorized by this spec.

### 3.3 Waiting and Recovery

Present expected rebuild/unavailable/bootstrapping states separately from SSO-needed, access-denied,
ambiguous-target, missing-user/home and invalid-configuration failures. Specify an accepted finite
wait budget/backoff and cancellation policy before implementation; do not wait forever or merely
increase the current retry count without defining readiness.

Re-resolve the logical target on applicable retries. Continue only when the replacement's required
user, SSH/EIC/SSM and application dependencies are ready. Stop, profile changes and app exit cancel
pending recovery; no stopped access is recreated. App-relaunch intent follows its separate contract.

Keep native browser/profile/PAC settings local and preserve their ownership/explicit-Apply rules.
Routed domains must remain fail-closed during the outage. Reconnection must not route private
domains directly, bypass TLS, overwrite another browser owner or silently change local bindings.

## 4. Server and Infrastructure Readiness Contract

The client cannot repair these conditions by changing an AMI reference:

- **Expected persistent data:** identify the intended data volume/filesystem, attach it exclusively
  and require the verified mount before creating users, starting their services or advertising
  readiness. Missing/ambiguous/unmountable data must not become a usable empty root-backed home.
  Do not select an arbitrary non-root disk or format an existing volume after a failed probe.
- **Stable authorized user:** restore the intended UID/GID and home ownership, detecting collisions
  before service startup. Do not compensate with a recursive ownership rewrite of everybody's
  persistent data or rely on whichever UID a fresh `useradd` happens to allocate.
- **SSH-first access:** the authorized user and home must exist before editor/forwarding SSH auth.
  Do not require opening DCV or calling a desktop-provisioning endpoint first. Any user-only
  provisioning/readiness API needs its own authorization and acceptance contract.
- **Fresh-root prerequisites:** recreate SSM registration, EIC key lookup, SSH authentication,
  TCP forwarding, required stream-local forwarding, private DNS/routes and policy-approved tools.
  Persisted files under `/home` do not recreate root configuration automatically.
- **User services:** restore the user manager/linger and actual dependencies before declaring
  services ready. For a UID-isolated local dashboard, verify startup, required authorized
  noninteractive privilege, firewall behavior, kubeconfig/cloud auth and cross-user boundary.
  A surviving unit file or loopback listener alone is not proof that the dashboard works safely.
- **Organization security agent:** where required by the approved image policy, enrollment is a
  server-side readiness prerequisite with appropriately scoped secret access. Never put enrollment
  secrets into user data, traced shell output or client profiles.

Keep data retention, backups and one-writer attachment rules explicit in the replacement plan.
The existence of a retained volume by itself is not evidence that the fresh instance mounted
the right data or restored compatible ownership.

## 5. Acceptance: Replace, Do Not Merely Reboot

Use an independently approved disposable logical profile, synthetic user/project state and
separate test data volume. Do not use the live multi-user workstation or production credential
caches. A same-instance reboot is not this test.

| ID | Scenario | Required evidence |
| --- | --- | --- |
| REBUILD-01 | Replace host A with B under the same logical profile | Instance ID/root change while profile UUID, SSH authority and remote folder stay stable; no manual SSH/profile/ID edits. A and B never mount the data filesystem writable together. |
| REBUILD-02 | Select the original VS Code Recent entry | That original authority reaches the authorized replacement/user and saved project, with real open/save, terminal and required language/debug/socket workflows. CLI/window launch alone is insufficient. |
| REBUILD-03 | Persistent user/configuration/server state | Expected saved files/tools/server/extension and supported conversation data are available with correct UID/GID/home ownership. Live agents/processes are reported separately, not claimed migrated. |
| REBUILD-04 | Native domains and local forwards after a long bootstrap | Existing native browser/PAC configuration resumes actual private DNS/HTTP/websocket and named forwards after the accepted rebuild wait; outage stays fail-closed. |
| REBUILD-05 | Missing/wrong/unmountable data or UID collision | Host does not advertise ready or create an apparently valid empty home. No formatting, recursive ownership repair or client-side privileged workaround; actionable error and data preserved. |
| REBUILD-06 | Changed target/user, ambiguous matches, owner or host trust | Unexpected changes are refused/confirmed by the agreed policy; no stale-key/generation reuse, host-key bypass, wrong-user binding or stream redirection. |
| REBUILD-07 | Parallel Recent windows and EIC's initial window expires | Every fresh SSH authentication gets current authorization against a coherent new binding; no key-loading race or dependence on permanent authorized keys. |
| REBUILD-08 | App restart, lease expiry or SSO recovery overlaps replacement | Separate recovery policies compose without loops, cross-target replay, another workspace identity or success-shaped incomplete readiness. |
| REBUILD-09 | Stop/cancel or interrupted bootstrap | Waiting and new grants stop; healthy unrelated transports are unchanged, no dead target remains advertised ready, and resumption is explicit/authorized. |
| REBUILD-10 | Persisted user dashboard/service | Service returns with the intended user's data and functioning identity-gated access; actual cross-user rejection and dependency ordering are verified. |
| REBUILD-11 | Approved rollback to recorded previous image/bootstrap | Data identity and safe attachment/ownership remain intact through another replacement. The exact prior image is recorded; pointing at a floating latest value is not rollback proof. |

Section 9 records the subsequent real-replacement results: REBUILD-01, REBUILD-02 for the
exercised native TCP editor workflow, REBUILD-06 and REBUILD-07 are met, and REBUILD-08 is met
for the expired-lease overlap.
The later dashboard API/WebSocket checks initially failed because Azure reauthentication was
required. Owner-approved sign-in subsequently restored both, as recorded in section 10.2.
Remaining composite criteria are not verified as complete requirements; this resolved credential
failure is not carried as an open client defect. Existing same-instance fixtures alone do not
close replacement acceptance. Windows and any required GPU/DCV/multi-engineer or socket-mode
workflows need their own applicable native evidence.

## 6. Decisions and Operational Boundary

These are two consumers of a shared identity/readiness boundary, not permission to conflate
browser routing, editor transport, remote user readiness and infrastructure replacement. The
combined implementation must keep a blocked browser capability explicit if G1 does not pass,
and must not claim server-side replacement acceptance from client fixture tests alone.

Before building, settle the expected-replacement trust signal/confirmation policy, finite readiness
budget, broker/key/host-trust handoff and authorized user-only readiness/provisioning boundary.
Infrastructure changes must have their own reviewed source/spec, data-retention plan and approved
execution environment. Cross-repository acceptance is required; a client patch alone is incomplete.

Keep the production operational hold in place. Review live pipeline trigger and approval behavior
before any infrastructure merge: a merge may apply immediately rather than wait for a maintenance
schedule. Require backups, recorded previous image/bootstrap, an agreed capacity/change window
and honest rollback expectations. Reverting an image is another replacement, not restoration of
the deleted root or its old processes.

This source/spec assessment performed no infrastructure edits, plan/apply, replacement, reboot,
remote service/firewall changes or production validation. The source attachment is investigative
evidence, not authorization to execute its rollout.

## 7. Accepted Client Policy and Implementation Evidence (2026-10-17)

The owner selected **confirm-new-instance**, rather than automatic adoption, and delegated a
sensible finite wait budget. Use **30 minutes**, a visible cancellable wait with 15-second
readiness backoff. Recovery must not start EC2. Missing targets, pending/stopped targets and
SSM-not-online may wait; ambiguity, denial, invalid configuration and changed user are not
bootstrapping successes. Approval is tied to the displayed candidate and the current profile;
re-resolving a third instance requires a new review.

The editor owner now prepares a fresh generation/key and instance-specific host trust under the
original authority. A proxy may leave only a private, generation/owner-bound status request and
must fail that SSH attempt; it cannot rebind a channel or authorize a different instance itself.
Once access is prepared, retry the original workspace so native SSH rereads coherent configuration.
No Code window is launched by recovery, and no remote data/process migration is asserted.

Executed package evidence at the reviewed checkpoint: **292 tests in 36 suites passed**, including
deterministic explicit
relaunch, confirmation/reconfirmation, cancellation, terminal errors, SSM readiness, stale helper
requests, another live owner, Stop/Quit/Restore intent and the measured 60-second lease budget.
This checkpoint was client-seam evidence only. Section 9 separately records the later
owner-approved observations on an actual replacement and the current acceptance disposition.

Native forwarding now keeps its applied browser/PAC/forward configuration while waiting for
expected readiness after a drop. The same 30-minute outer budget includes backoff and connection
stages, and each readiness miss uses 15-second backoff. A different physical instance stops for
Review Forwarding Replacement before EIC or a new SSH session; approving B never authorizes C.
Automatic recovery cannot start EC2, while ordinary explicit Turn On retains cold-start behavior.
Ambiguity, changed users and authorization errors are terminal; unrelated transport errors retain
the earlier three-attempt limit. This is a client readiness policy, not proof of mounted home,
UID/GID, DNS, dashboard or websocket readiness on a real replacement.

Each transport reviews its own binding: native forwarding retains the documented SSM-bound
host-key policy, not the editor's instance-specific accept-new policy. An editor approval is not
silently reused as browser readiness or broader host-trust approval.

An isolated no-window AppKit probe, compiled with the production launch handler, observed both
initial explicit open and reopen as explicit launches. It used a separate temporary bundle with
no credentials, profile access or network work. This verifies native event delivery only; it does
not verify login-item behavior, an installed-app upgrade or original editor/agent preservation.
The ARM64 macOS Release app and embedded proxy build passed, with ad-hoc bundle verification.
No candidate app was installed or run against production preferences or an existing workspace.

### Reviewed Corrections

Publication now takes a persistent, private root-wide file lock, then rechecks the exact
pre-key-generation lease snapshot before writing the host configuration or granting ownership.
The critical section is synchronous on MainActor; the file lock also serializes cooperating
app processes and aggregation of configuration for different profiles. A changed or live claim
is refused. The lock file is not unlinked between publications.

Ordinary explicit editor cold starts retain their 120-second SSM budget; explicit native
forwarding retains its configured budget, 180 seconds by default. Only recovery uses 30-second
SSM slices. SDK permission-denial codes are classified separately from expired-token recovery
and terminate native reconnect without transport retries.

All three independent findings were reproduced before correction. The two ordinary-start
regressions failed at approximately 30.004 seconds before the fix and passed real 35-second
waits after it. The full corrected suite passed in 61.057 seconds. A focused independent
follow-up passed two test functions, including three SDK-denial stage cases, and closed all
three findings with high confidence. Separate-process lock contention was source-inspected,
not executed; the ownership regression exercises the suspended-publisher interleaving within
one process. The native Release build and ad-hoc seal verification also passed.

## 8. Independent Review Record

The following verdicts are preserved verbatim for reviewed baseline
`823e239fa762296fda75820d9adf7a311d0ea407`. Their line references describe that baseline.
Corrections above close the three source findings, not the complete native/server criteria.
The accepted repository specifications were used directly; no Vega onboarding or feature
artifact was introduced. Source review used a shared read-only checkout, not a structurally
isolated worktree. Focused independent execution observed 61 test functions in four suites.

```text
CRITERION: UPGRADE-01 — Upgrade/relaunch with an existing remote workspace open
VERDICT: not verified
EVIDENCE: EditorWorkspaceRecoveryTests.swift:91-111 passes for stable fixture identity and fresh no-window preparation; no original-window installed-upgrade execution.

CRITERION: UPGRADE-02 — Existing agent/conversation and unsaved editor state
VERDICT: not verified
EVIDENCE: No observed native before/after buffers, conversation or agent checks. Parent event probe cannot establish these; live agent execution remains separately unknown.

CRITERION: UPGRADE-03 — New app PID/key/generation and expired initial EIC authorization
VERDICT: not verified
EVIDENCE: Fresh fixture owner/key/generation is covered at EditorWorkspaceRecoveryTests.swift:91-111; realSSHCommandChannelsRefreshAuthorization was skipped and no original-window channel handoff was observed.

CRITERION: UPGRADE-04 — Repeated upgrade/recovery, including preview-to-installed migration
VERDICT: not verified
EVIDENCE: Fixture restart/recovery and silent-auth behavior pass at EditorWorkspaceRecoveryTests.swift:140-172,322-335; repeated installed upgrades and checked preview migration were not observed.

CRITERION: UPGRADE-05 — Stop/revocation/intentional Quit or changed target races recovery
VERDICT: not verified
EVIDENCE: Cancellation/intent/stale-request fixtures pass at EditorWorkspaceRecoveryTests.swift:113-137,216-237,306-320,373-381,435-451; ownership-publication race in finding 1 remains uncovered, and native races were not exercised.

CRITERION: UPGRADE-06 — Missing authorization, damaged integration or macOS launch refusal
VERDICT: not verified
EVIDENCE: Corrupt-intent and silent sign-in refusal fixtures pass at EditorWorkspaceRecoveryTests.swift:275-283,322-335; original-window recovery through damaged integration/launch refusal was not observed.

CRITERION: REBUILD-01 — Replace host A with B under the same logical profile
VERDICT: not verified
EVIDENCE: EditorWorkspaceRecoveryTests.swift:140-172 passes for synthetic A-to-B authority retention; no physical replacement/root change or exclusive data-attachment execution.

CRITERION: REBUILD-02 — Select the original VS Code Recent entry
VERDICT: not verified
EVIDENCE: No observed original Recent entry against a replacement with real project open/save, terminal, language, debug or stream-local socket workflows.

CRITERION: REBUILD-03 — Persistent user/configuration/server state
VERDICT: not verified
EVIDENCE: No replacement execution demonstrating persisted files/tools/server/extensions/conversation data or UID/GID/home ownership. No live-process migration is claimed.

CRITERION: REBUILD-04 — Native domains and local forwards after a long bootstrap
VERDICT: not verified
EVIDENCE: WebForwardsStateMachineTests.swift:256-279 passes four synthetic missing-target waits and configuration retention; actual private DNS/HTTP/websocket/named forwards and outage fail-closure were not exercised.

CRITERION: REBUILD-05 — Missing/wrong/unmountable data or UID collision
VERDICT: not verified
EVIDENCE: No server negative-readiness/data-preservation execution; client SSM readiness does not establish verified mounts, collision refusal or absence of an empty root-backed home.

CRITERION: REBUILD-06 — Changed target/user, ambiguous matches, owner or host trust
VERDICT: not verified
EVIDENCE: Synthetic confirmation/reconfirmation/user/ambiguity checks pass at EditorWorkspaceRecoveryTests.swift:140-195,256-273,399-412 and WebForwardsStateMachineTests.swift:281-313,341-356; findings 1 and 3 remain uncovered and native host-trust handoff was not observed.

CRITERION: REBUILD-07 — Parallel Recent windows and EIC's initial window expires
VERDICT: not verified
EVIDENCE: The native SSH authorization probe was skipped. No parallel original-Recent authentication/key-loading/host-binding execution across replacement was observed.

CRITERION: REBUILD-08 — App restart, lease expiry or SSO recovery overlaps replacement
VERDICT: not verified
EVIDENCE: Restart, stale-generation and SSO fixture cases pass at EditorWorkspaceRecoveryTests.swift:91-111,285-304,322-371; no combined native overlap execution, and finding 1 exposes an uncovered owner interleaving.

CRITERION: REBUILD-09 — Stop/cancel or interrupted bootstrap
VERDICT: not verified
EVIDENCE: Client wait/cancel/deadline fixtures pass at EditorWorkspaceRecoveryTests.swift:197-254 and WebForwardsStateMachineTests.swift:315-339; interrupted server bootstrap and healthy unrelated native transports were not jointly exercised.

CRITERION: REBUILD-10 — Persisted user dashboard/service
VERDICT: not verified
EVIDENCE: No actual service restoration, intended-user data/access, cross-user rejection or dependency-ordering execution on a replacement.

CRITERION: REBUILD-11 — Approved rollback to recorded previous image/bootstrap
VERDICT: not verified
EVIDENCE: No approved second replacement using a recorded exact prior image/bootstrap with preserved data identity, attachment and ownership.

CRITERION: Explicit-launch fixture restores the same profile/instance/user with a fresh owner/key/generation and no extra editor launch.
VERDICT: met
EVIDENCE: explicitLaunchRestoresOnlyTheSameWorkspace, EditorWorkspaceRecoveryTests.swift:91-111; observed focused run.

CRITERION: Stop, disabled/legacy/background launch and changed-role fixture cases do not initiate restoration authorization.
VERDICT: met
EVIDENCE: cancelledAndUnapprovedRecoveryNeverStartsAWS and loginAndUnknownAppleEventsDoNotBecomeLaunchConsent, EditorWorkspaceRecoveryTests.swift:113-137; observed focused run.

CRITERION: Synthetic replacement B requires approval; changing to C requires another review; remembered-user mismatch is refused.
VERDICT: met
EVIDENCE: EditorWorkspaceRecoveryTests.swift:140-195,399-412 and forwardingReplacementMustBeReviewed at WebForwardsStateMachineTests.swift:281-313; observed focused run.

CRITERION: Tested stopped/absent/SSM-pending recovery paths use bounded cancellable waiting without starting EC2.
VERDICT: met
EVIDENCE: EditorWorkspaceRecoveryTests.swift:197-254,383-397 and WebForwardsStateMachineTests.swift:256-279,315-339; observed focused run. This excludes ordinary cold-start budget preservation in finding 2.

CRITERION: Tested stale-generation and malformed/non-private helper requests do not initiate new authorization.
VERDICT: met
EVIDENCE: oldGenerationCannotTriggerRecovery and invalidHelperMessageCannotTriggerAWS, EditorWorkspaceRecoveryTests.swift:354-371,414-433; observed focused run. This does not establish atomic owner acquisition.
```

Complete-contract tally at review: zero met, zero not met, seventeen not verified.
Five narrower client subchecks were met. Follow-up disposition, verbatim:

```text
Result: all three findings closed with high confidence. No new tightly-coupled correctness flaw found.

Whole UPGRADE-01…06 and REBUILD-01…11 remain not verified. This closure concerns the three source findings, not native/server acceptance.
```

Later [isolated native owner-recovery evidence](./remote-vscode.spec.md#18-executed-isolated-native-owner-recovery-cycle-2026-10-17)
observed fresh-owner access and same-window native reconnection after an explicit retry, followed
by native edit/save and exact unsaved-buffer preservation in the isolated same-instance fixture.
It does not upgrade these baseline complete-contract verdicts or establish a physical replacement.

The [final process/channel checks](./remote-vscode.spec.md#19-final-process-channel-and-stop-checks-2026-10-17)
subsequently passed 296 package tests, real separate-process publication-lock contention,
concurrent native SSH, fresh authentication after 65 seconds and native Stop/relaunch refusal.
The earlier review's unexecuted interprocess-contention limitation is therefore closed for that
specific subcheck. Parallel original Recent windows, physical replacement and complete-contract
verdicts are not promoted by this narrower evidence.

## 9. Real Replacement Acceptance (2026-10-20)

### 9.1 Confirmed Client Rebind: Closed

The owner reported that the workstation had been replaced and that the existing remote window
could not reconnect. Installed v0.7.0 logs independently showed a new running instance under the
same logical selector. SSM was online; the desktop agent ensured the same user's session and
the desktop tunnel connected. These observations did not establish editor access.

The editor was still bound to the former instance, with an expired lease and a matching helper
recovery notice. The app already displayed Review Replacement Workstation. After the owner
explicitly approved the displayed old/new candidate, the normal native review/Continue action:

- retained the original local profile UUID and SSH authority;
- created a fresh key/generation and finite lease for the approved replacement and same user;
- updated the per-instance HostName/HostKeyAlias coherently while retaining accept-new checking;
- did not open a Code window, edit the user's SSH Include, bypass trust or restart either host.

The owner retried the existing Code window. Its native Remote-SSH log then authenticated to the
replacement and resolved the original authority. The owner confirmed that window worked.
This closes the confirmed-replacement client-rebind scenario; it is not still awaiting a
hypothetical first replacement run.

### 9.2 Agent-Executed Native Workflows

At the owner's request, further checks were executed directly in the original remote window:

| Check | Observed result |
| --- | --- |
| User and home | Login user, UID/GID and home ownership matched. `findmnt` placed the home on a separately mounted ext4 `/home`, not a root-backed fallback. |
| Retained project data | The previously created October 15 editor fixture still existed, retained its saved recovery/window markers and matching ownership, and its original Node test passed without rewriting the fixture. |
| Native open/edit/save | A clearly owned new test file was opened in the original remote editor, changed and saved through native File > Save. Independent SSH reads verified the exact expected content. No existing project source was edited. |
| Native terminal | A newly created remote bash terminal executed the owned Node test; an exact proof file independently verified success. The user's default terminal profile was local, so it was not mistaken for replacement-host execution. Defaults were not changed. |
| Language navigation | Native TypeScript Go to Definition moved from the owned function call on line 6 to its declaration on line 2, column 17. |
| Debugger | A native JavaScript Debug Terminal paused the owned program at its debugger statement. The proof file was absent while paused; native Continue produced the exact expected value and the process completed. |
| Conversation availability | Existing chat history was visible in the reconnected original window. No chat request was sent, no private conversation was exported, and individual previous agent executions were not claimed resumed. |
| Named local forward | The configured forwarding transport started successfully against the replacement. Its named loopback forward returned HTTP 200 for the existing Headlamp page and valid API JSON. |
| Dashboard configuration | Headlamp returned 26 configured clusters and its cluster chooser rendered in a browser. No cluster operation, credential change or service restart was performed. Cluster access, data fidelity and cross-user rejection were not inferred from this. |
| Native SOCKS | A request using SOCKS remote-hostname resolution reached the replacement-local dashboard API with HTTP 200. This is not a test of a particular private HTTPS site or WebSocket. |

The shared browser initially produced CORS errors at numeric loopback, while its localhost
page rendered. Subsequent isolated native Chrome testing in section 10 did not reproduce that
problem at either origin. The shared-browser observation is not evidence of a production
launch-link bug, and the app's existing numeric-loopback URL semantics were retained.

The active editor configuration used TCP Remote-SSH, not remote-server-listen-on-socket mode.
No private-domain browser routing settings, workspace-trust settings, existing code buffers,
desktop process or remote service configuration were changed.

Temporary test files, proof files and their empty directory were removed after collecting
evidence. Only the four owned editor tabs and three test-created terminal shells were closed.
The debugger completed normally. The original Code window, prior terminals, installed app and
preview draft stayed open. Native web forwards were left on and ready for the owner's use.

### 9.3 Current Criterion Disposition

The October 17 independent-review blocks in section 8 remain immutable historical evidence.
This table supersedes their all-not-verified replacement summary for the exercised scenarios;
it does not retroactively change what that reviewer observed.

| Criterion | Current verdict | Evidence and remaining boundary |
| --- | --- | --- |
| REBUILD-01 | met | Same profile/authority/original window plus a fresh root volume and the exact retained home volume are verified. Mounted-device/AWS correlation, non-multi-attach gp3 settings and successful non-forced detach-before-attach CloudTrail chronology establish the observed transition (section 10.5). |
| REBUILD-02 | met | Original window reconnected to the replacement; native open/edit/save, remote terminal/test, language navigation and debugger passed for its configured TCP workflow. Socket-mode replacement acceptance is not claimed for this TCP-configured profile. |
| REBUILD-03 | not verified | Retained pre-replacement fixture, saved markers, current home ownership, user config/server directories and visible history are verified. Complete expected tools/extensions/configuration/conversation fidelity lacks a recorded baseline comparison. Destroyed-VM live processes are not expected to migrate. |
| REBUILD-04 | not verified | Native SOCKS, named forward, dashboard API and native WebSocket now pass after authorized Azure reauthentication (section 10.2). Actual private HTTPS domains and outage fail-closed behavior remain untested in this replacement incident. |
| REBUILD-05 | not verified | Current home is mounted and ownership matches. Missing/wrong-volume and UID-collision refusal require a disposable negative-readiness environment, not destructive manipulation of the working host. |
| REBUILD-06 | met | Actual changed instance was refused until explicit native confirmation; fresh key/generation, same user/authority, per-instance host trust and no stream redirection were observed. Existing executed regression coverage supplies ambiguity, wrong-user, stale-candidate and conflicting-owner negative cases. |
| REBUILD-07 | met | Two simultaneous native workspaces on the replacement independently saved/read their exact owned markers. Three fresh concurrent SSH authentications after a measured 65-second wait also passed with the lease/key/generation/owner unchanged (section 10.4). |
| REBUILD-08 | met | The real replacement overlapped an expired editor lease. Owner-bound recovery, explicit candidate confirmation and native retry produced a fresh same-authority grant without an extra workspace or retry loop. App-restart/SSO variants overlapping replacement were not run live in this incident. |
| REBUILD-09 | not verified | Previous cancellation/Stop tests pass, but interruption/cancellation during this actual bootstrap was not exercised; do not stop the working access solely to promote that result. |
| REBUILD-10 | not verified | Listener, chooser, saved configuration and the read-only development-cluster API/watch work after Azure reauthentication (section 10.2). Full service-data fidelity, cross-user rejection and boot dependency ordering remain unverified. |
| REBUILD-11 | not verified | No rollback or second replacement using a recorded prior image/bootstrap was performed or authorized. |

### 9.4 Remaining Work, Without Requiring Another Replacement

Private HTTPS/WebSocket endpoints and the dashboard's normal authenticated workflow can be
checked on this running replacement when their intended targets are known. Preserve existing
SSO identity and routing; a cluster chooser or generic HTTP response is not a substitute.
Parallel TCP-window checks are recorded in section 10.4. Additional socket-mode or identity
checks must use owned fixtures and preserve working editor/agent state.

Volume/attachment evidence from the actual replacement is now recorded in section 10.5.
Wrong-volume/UID-collision failures, interrupted bootstrap, cross-user isolation and rollback
require separately approved environments or identities. They are not blockers to calling the
confirmed client-rebind path verified, but they keep the broader cross-boundary spec open.

The incident also exposed a discoverability gap: the useful replacement-review action was
present in the app while VS Code showed the generic proxy refusal. Section 10 records the
separate, not-yet-released diagnostic improvement.

## 10. Autonomous Follow-Up Verification (2026-10-20)

### 10.1 Native Browser Origin: No Production Defect Reproduced

A dedicated native Chrome 156.0.8078.36 profile tested both `http://127.0.0.1:4466/` and
`http://localhost:4466/` through the existing named forward. Both rendered the Home/cluster
chooser, returned HTTP 200 and 26 configured clusters from `/config`, and recorded zero CORS
errors, zero failed network requests and zero cross-origin loopback requests.

The normal browser profile, cookies and proxy settings were not read or modified. No TLS/CORS
protection was disabled. This agrees with the earlier native-browser findings in the
[web-forward specification](./web-forwards.spec.md#32-spike-results-2026-10-12).
A separate isolated headless Zen screenshot was blank; that invocation was not counted as
successful native page rendering. Chrome evidence is not promoted to a full default-Zen run.

There is therefore no justified application URL change from this observation. Keep the existing
IPv4 listener and Open-link contract, rather than introducing a global localhost behavior change
or an unnecessary profile-format option.

### 10.2 Dashboard API/WebSocket: Azure Reauthentication Resolved

A read-only namespace-watch smoke test used an existing development context, not a production
cluster or a write operation. Its native browser WebSocket did not open. An ordinary read-only
namespace API request through Headlamp returned HTTP 502.

The replacement independently resolved that configured API hostname and established TCP access
to its HTTPS port. The dashboard listener belonged to the expected user, and the existing
`headlamp.service` log reported a credential executable returning exit code 1. The executable
was not reported missing. Those initial logs alone did not establish the specific cause.

Subsequent read-only inspection of only that context's exec configuration identified
`kubelogin --login azurecli`. Both kubelogin and Azure CLI were available in the dashboard
service and interactive PATH. The service used the intended home directory, with no custom
Azure configuration-directory override. Azure CLI could read an enabled default cached account,
but a noninteractive token request for the existing AKS audience failed with **AADSTS70043**.
Only expiry/type metadata was requested; no access token or private configuration was printed.

[Microsoft's error reference](https://login.microsoftonline.com/error?code=70043) identifies
that code as an expired or invalid refresh token due to Conditional Access sign-in-frequency
checks. This is a concrete downstream Azure authentication blocker, not a missing runtime,
DNS failure, SSM tunnel failure or evidence that the saved dashboard configuration was lost.
It required fresh interactive Azure authentication in the workstation's existing user context.
The Mac app's separate AWS SSO login cannot repair that Azure token, and an enabled cached
account is not proof that silent token renewal is still permitted.

This separates transport from application authorization: serving the chooser/configuration and
forwarding TCP do not prove that Headlamp can obtain its downstream cluster credentials.
During diagnosis no credential provider, Kubernetes context, account selection, remote service
or permission was changed, and no login flow was started. The owner subsequently explicitly
requested Azure authentication. The workstation CLI used its normal device-code login, restricted
to the existing tenant and exact subscription. The owner completed Microsoft sign-in/MFA in
the browser; no password, MFA response or access token was collected, and no credentials were
copied between machines.

The SSH connection carrying that login exited before the wrapper could report its final
before/after assertions. That interrupted wrapper was not reported successful. Independent
post-login checks instead established:

| Check | Result |
| --- | --- |
| Existing cached account | Azure CLI reported enabled/default state. The login command was scoped to the prior tenant/subscription; the interrupted wrapper's complete identity comparison was not observed. |
| Silent token acquisition for the same configured AKS audience | Exit 0 with a valid expiry. Only expiry/type metadata was requested, never the token value. |
| Actual dashboard downstream API | HTTP 200, valid NamespaceList and one requested item through the existing named forward. |
| Native-browser namespace-watch WebSocket | HTTP 101 upgrade, open connection and an 894-byte valid ADDED event. No event contents or cluster credentials were retained in the report. |
| Transport preservation | Original editor SSH access, native SOCKS/local forwarding and the running client/Code/preview processes remained intact. |

The credential incident is therefore resolved and its earlier failing API/WebSocket checks
now pass. No service restart, application update or permission change was needed. Temporary
native-browser processes/profile and the copied device-code prompt were cleaned up. Broader
REBUILD-04/REBUILD-10 criteria retain only their separately listed private-domain/outage,
data-fidelity, cross-user and startup-ordering gaps; they are not blocked by this old token.

### 10.3 Actionable Reconnect Guidance: Local Implementation

The follow-up helper maps only recognized errors to static, noncredential recovery instructions:

- Changed target: Review Replacement Workstation, verify the expected instance/user, Continue,
  then retry the existing window; do not approve an unexpected replacement.
- Unavailable/expired local access: Reconnect Existing Workspace and complete any requested
  replacement review/sign-in before retrying the original window.
- Rejected authorization: Sign In with SSO, then same-context reconnect/retry.
- Configuration conflict: review the independently changed setup; do not overwrite it or
  disable host-key checking.

Unknown errors keep the existing generic message; arbitrary AWS/process error descriptions
are not copied into SSH diagnostics. Messages are written only to stderr, preserving raw
SSH stdout. A pending replacement also produces a warning near the top of the native app menu,
even if the independent desktop transport is connected.

These are discoverability changes only. They do not silently authorize a replacement, launch
another editor, force a window reload or alter authentication/trust policy. They remain local
until separately shipped; installed v0.7.0 still has its original diagnostics.

The focused editor/recovery run passed 39 tests in two suites. The full run passed
**298 tests in 36 suites**, including measured 35-second initial-readiness and 60-second
lease-attempt regressions. The new checks distinguish replacement, local-access and sign-in
instructions and verify that an unknown error's secret-shaped description is not printed.
The complete native Release app/helper build and ad-hoc signature verification passed. An
owned expired copy of the grant was then supplied to the built helper: it exited unsuccessfully,
wrote no stdout, named Reconnect Existing Workspace on stderr and left the live grant bytes
unchanged. No AWS channel authorization was needed for that expired-copy check. The top-menu
warning was subsequently exercised in a separately identified native fixture using the actual
candidate MenuContentView. Its synthetic profile, memory-only preferences, private SSH config,
dummy keys and mocked/refused network backends never used production configuration or AWS.
Native accessibility observed the warning before Open VS Code, with Review Replacement Workstation
present. The fixture reported zero EC2 starts and was quit normally. The working installed app
was not replaced or restarted for that UI check.

### 10.4 Parallel Native Workspaces on the Replacement

Two owned test workspaces were opened simultaneously through the existing installed helper,
same original authority and current replacement, alongside the existing working editor windows.
The normal workspace-trust configuration was retained; no trust bypass was added.

Each test window natively opened, edited, saved and displayed its own marker. Independent SSH
reads verified the exact A/B contents and absence of cross-workspace files. Both windows remained
open during a measured wait of at least 65 seconds after an initial fresh authentication.
Three additional, independent native SSH processes then authenticated concurrently and returned
their exact unique markers. The lease bytes, key path, generation and owner remained unchanged.
Both native windows still displayed their own saved contents afterward.

Only the two verified test windows were closed normally, and their exact marker files/empty
directories were removed. A before/after native window-title comparison verified that every
pre-existing window remained open at cleanup. Later optional Recent-history cleanup was not
attempted after the accessible editor window set changed; no unrelated window or history was
modified to force that cleanup.

This is direct native replacement evidence for REBUILD-07, in the configured TCP mode. It does
not claim socket-mode replacement acceptance, preservation of destroyed-VM agent processes or
safe exclusive volume attachment during the earlier infrastructure operation.

### 10.5 Read-Only Root and Retained-Home Verification

No infrastructure changes were needed to inspect the actual replacement. The mounted `/home`
NVMe serial was correlated with the exact EBS volume returned for the replacement's device
mapping, rather than assuming that any attached non-root disk was the persistent home.

| Observation | Measured result |
| --- | --- |
| Mounted home | `/home`, ext4, on the volume identified by the device serial |
| Home volume | Encrypted 200 GiB gp3; multi-attach disabled; one current attachment, to the replacement |
| Retention policies | Home DeleteOnTermination false; root DeleteOnTermination true |
| Existing home volume creation | 2026-06-13, before the retained October 15 fixture |
| Old-instance home detach | Successful at 05:07:31 UTC on October 20; force detach was not requested |
| Prior instance termination request | Successful at 05:07:42 UTC |
| Current root volume creation | 05:15:37 UTC, after the prior termination request and after the saved fixture's original creation |
| Same home volume attached to replacement | Successful at 05:15:58 UTC, after its detach from the prior instance |

CloudTrail lookup for the exact home volume covered October 20 with no remaining result pages.
Combined with gp3's non-multi-attach behavior, the observed successful non-forced detach and
later attach demonstrate the serial attachment of that retained volume in this transition.
The current root volume's creation time establishes that it is not the old instance's root.
The current image identifier was measured privately; no previous-image rollback is inferred.

A broader first page of replacement-instance activity had more pages and was not presented
as exhaustive launch history. No absence-of-events assertion, host reconfiguration, Terraform
operation, mount change, formatting, permissions change or additional replacement was used.
Resource identifiers and identity-bearing CloudTrail payloads were kept out of this specification.

This closes REBUILD-01 for the observed replacement. It does not test wrong/missing-volume
bootstrap refusal, UID collisions, application startup ordering or rollback; those remain the
separate REBUILD-05/REBUILD-10/REBUILD-11 requirements.
