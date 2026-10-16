# SPECIFICATION: Native VS Code workspace bootstrap over SSM

- **Status:** shipped in macOS v0.5.0 on 2026-10-15; the user approved continuation and native SSH
  setup. Verified transport/menu/server and native fixture editing evidence is recorded below;
  fresh-user, cross-user socket hardening, enterprise-policy and complete app-drop acceptance
  remain unverified limits accepted for stable release by the user on 2026-10-15. Concurrent
  native windows and socket-mode language/debug flows are verified below.
- **Requested outcome:** open the management VM's existing code folder in local VS Code,
  with a native editor UI rather than a DCV-rendered desktop.
- **Related:** [web-forwards.spec.md](./web-forwards.spec.md),
  [browser-bootstrap.spec.md](./browser-bootstrap.spec.md).
- **Gate:** normal SSH Include setup and native VS Code/server testing were explicitly approved
  by the user. No VM sshd/system policy or remote repository content was changed by automation.

## 0. Prove the Mechanism Before Building

Use an isolated SSH configuration and an explicitly approved throwaway remote folder.
Do not change normal SSH/VS Code configuration, the live web tunnel, DCV, or the VM's sshd.

1. Identify installed VS Code product/version, Remote - SSH extension/version, local OpenSSH,
   remote OS/architecture and current VS Code Server prerequisites. Record exact versions.
2. Establish SSH command execution through `AWS-StartSSHSession` and the bundled plugin,
   using the mapped OS user and an ephemeral EC2 Instance Connect key. A working `-D` or
   `-L` listener alone is not evidence of Remote SSH command/server compatibility.
3. Prove a proxy helper can carry raw stdin/stdout SSH traffic, send diagnostics only to
   stderr, and refresh public-key authorization before each new SSH authentication. AWS
   credentials/session tokens must never enter SSH configuration, command arguments or logs.
4. Connect real local VS Code and open the approved folder. Let the user explicitly approve
   VS Code Server installation in their remote home. Verify remote authority, file open/save,
   integrated terminal, language-server completion, one project build/test and port forwarding.
5. Repeat after the EC2 Instance Connect key's initial 60-second authorization window expires,
   including a second editor window and a slow server download. No permanent authorized_keys
   entry or copied credentials may be required. Verify concurrent invocation/key ownership.
6. Exercise multi-user socket-server mode as well as the chosen supported default. Microsoft
   documents that socket mode disables connection multiplexing; ControlMaster alone must not
   be the authentication strategy. Report any required host capability as a prerequisite,
   never silently change sshd or disable a user's security setting.
7. Drop/reconnect SSH, expire AWS SSO, restart the app and replace the resolved instance.
   Verify actionable recovery, correct target/user and no public-network SSH fallback.
8. Verify DCV/web forwards stay independent and that app/remote-access shutdown does not
   close VS Code, discard unsaved editor buffers, or delete the remote source/server data.

Mark each result observed / failed / not verified. Until these pass, support is a proposal.

## 1. What Runs Where

The editor window, rendering and UI extensions run on the Mac. Source files, terminal commands,
builds, tests and most workspace/language extensions run on the management VM through VS Code
Server. This removes streamed-desktop latency; it does not make a remote compiler or network
round-trip as fast as a local one. No source synchronization or filesystem mount is required.

The released implementation uses an owned SSH alias/config fragment and a bundled raw-stream
proxy helper. Each independent SSH channel checks the credential-free lease, owning app/process,
generation, target and user, silently obtains AWS authorization, refreshes the temporary EIC public
key authorization and starts its own SSH-over-SSM channel. It is not a DCV or SOCKS dependency.
Browser PAC configuration does not configure Remote SSH.

The owner's later SSO expiry/reconnect experience is a failed usability test. Proactive sign-in
status and same-target pending-action recovery remain follow-up requirements in
[AUTH-01 through AUTH-07](./ssm-connect.spec.md#13-authentication-freshness-and-recovery-follow-up-2026-10-15),
not outcomes established by the earlier fixture reload/save tests.

## 2. User Experience

### Settings

An optional **Remote Development** section per workstation contains:

- Enable native VS Code access.
- Installed editor product, initially verified Visual Studio Code Stable only.
- Optional remote folder: an absolute Linux path; empty opens a remote window for folder choice.
- SSH user inherited from the workstation's explicit/mapped user; do not introduce an unrelated
  browser preference or assume a shared `ec2-user` account on multi-user workstations.
- Setup status and **Restore Editor Setup** for the app-owned local integration.

Use existing workstation AWS/SSO/region/instance configuration. Browser and web-forward settings
are not prerequisites. Missing editor/extension is actionable: offer Open Download Page or an
explicit **Install Remote - SSH** confirmation; never install implicitly.

### Open VS Code

1. First use explains the exact local SSH/VS Code integration and normal user-scoped remote
   server installation. Cancel causes no configuration writes, installs or workstation start.
2. Authenticate/start the selected workstation as needed, resolve its user, prepare owned
   SSH access and verify a remote command channel. Show **Opening VS Code**; deduplicate clicks.
3. Launch the chosen local editor against the exact remote authority and folder. Prefer
   `--folder-uri` for unambiguous, correctly escaped folder paths, including dotted names.
   Do not infer a repository path from the workstation name or scan remote home directories.
4. VS Code handles Workspace Trust and its normal server/extension prompts. SSM Connect must
   not bypass trust, copy editor logins, or claim launch success means the remote folder opened.
5. Repeated use retains the user's normal local VS Code profile/settings. Reuse/focus a matching
   remote workspace only through a verified editor mechanism; never overwrite another window.

**Stop Remote Access** affects only editor-owned transports. Closing VS Code does not stop the
workstation or disconnect DCV/web forwards. Stopping EC2 or quitting SSM Connect warns that
remote editor connections will drop; VS Code windows and local unsaved buffers remain open.

## 3. Proposed Transport and Ownership

### V1: App-Owned SSH Proxy Helper

Generate a stable, collision-checked SSH alias per workstation UUID. Its app-owned host entry
uses a bundled proxy helper, the verified local OpenSSH client, resolved instance/user and a
restricted ephemeral identity file. The helper reads a 0600 same-user lease containing no AWS
credentials, verifies the owning app's PID/bundle/launch identity and current generation, silently
refreshes AWS auth, checks the resolved instance, authorizes the key and opens a new SSM channel.
The lease expires and becomes invalid when the app stops access or exits. No additional daemon
or custom editor/server protocol is introduced. GUI interactive SSO remains in the app.

Every independent SSH authentication refreshes EIC public-key authorization before the channel
is used. VS Code's command/install/tunnel connections are independent, so initial menu-click
authorization is insufficient. One leased key generation must remain stable across in-flight
connections; never rotate/remove the identity file underneath a native SSH client reading it.
Prove key-loading order, concurrent lease behavior and reconnect semantics in section 0.

Do not reuse `ProcessPluginProcess` unchanged: it discards stdout for forwarding supervision,
whereas a ProxyCommand helper needs a bidirectional raw stream. Share existing AWS service
interfaces and safe request generation, not an inappropriate process I/O contract.

The helper fails closed when the app/session/alias is unavailable, rejects changed target/user
and mismatched generations, and never falls back to direct VM IP/DNS SSH.
Use only the bundled helper/plugin and structured inputs. Stdout contains SSH bytes only.

### Optional Optimization: ControlMaster

Authenticated command channels can potentially share an owned OpenSSH master. Gate this on
actual Remote SSH compatibility, including dynamic/stream-local forwards and user settings.
Bind socket ownership to account, region, instance ID, OS user and session generation, not just
the display name. Use a private short path within macOS Unix-socket length limits. Probe master
identity/readiness, refuse an unowned socket and never multiplex into a stale/replaced instance.
Do not require multiplexing or override multi-user socket mode to make the product work.

### Local Integration

Prefer an owned host fragment with a single explicitly consented include in the user's selected
SSH config. Preserve existing entries, include ordering and `Host *` behavior; detect an existing
alias, managed configuration or incompatible `remote.SSH.configFile/path`. Do not silently
replace a custom config path or globally set `remote.SSH.*` for unrelated hosts/editors.

Keep a minimal ownership/restore journal for exactly the integration added. Restore removes
only still-matching owned content; later user/policy changes cause a conflict. Do not back up
entire editor settings/credentials. App upgrade/move must not strand helper paths: detect and
repair through checked setup, or report the changed installation before launching.

## 4. Prerequisites and Boundaries

- Local supported VS Code, Remote - SSH and OpenSSH; native AWS SSO and bundled plugin suffice.
  No AWS CLI, manually started shell script, DCV Viewer or public SSH ingress is required.
- Remote reachable through SSM, EIC-enabled sshd, correct OS user, required exec/forwarding
  capabilities, writable user home and the current VS Code Server runtime prerequisites.
- Mapping an AWS identity does not create a Linux account/home. Use an already provisioned
  account or an independently approved user-provisioning mechanism. Do not call a DCV
  `ensure-session` endpoint merely to make editor access work; a missing user/home is an
  explicit prerequisite failure until a user-only bootstrap contract is verified.
- Remote server download can use Remote SSH's documented local-download/transfer fallback.
  Marketplace/extension dependencies have their own connectivity requirements; browser PAC
  is not a remote-server proxy. Report blocked downloads distinctly from SSH/auth failure.
- Honor configured multi-user server isolation. Never install OS packages, edit sshd, open
  firewall/security-group rules, grant root, or add permanent keys as automatic remediation.
- No SSH-agent forwarding, X11 forwarding, TLS bypass or unconditional host-key bypass.
  Specify a verified host-identity/trust flow; changed host keys/instances require checked trust.
- Remote Git authentication remains the user's remote setup. Do not copy local Git/editor/AWS
  credentials to the VM. Do not read workspace source until the user chooses that workspace.
- Keep persistent integration at 0600 within 0700 owned directories. Ephemeral keys and SSM
  responses are private, excluded from diagnostics and removed only after owned clients stop.
  Never delete remote repositories, `.vscode-server` data, user extensions or editor profiles.

## 5. Requirements

| ID | Priority | Requirement |
|---|---|---|
| RV-1 | P0 | One Open VS Code action reaches the selected remote folder with native local UI, without starting DCV or web forwards. |
| RV-2 | P0 | Reuse native SSO/EC2/SSM/user/EIC services; support new Remote SSH connections beyond EIC's 60-second window. |
| RV-3 | P0 | Authenticate proxy IPC and bind all key/channel/alias ownership to the exact workstation identity and user. |
| RV-4 | P0 | No silent installs or SSH/editor configuration writes; scoped consent and conditional Restore. |
| RV-5 | P0 | No direct SSH fallback, permanent remote keys, host-key/TLS bypass, agent forwarding or privileged host changes. |
| RV-6 | P0 | Multiple SSH invocations/windows and independent reconnects are safe, deduplicated and generation-aware. |
| RV-7 | P0 | SSH execution plus server/forwarding compatibility is verified, including multi-user socket-mode behavior. |
| RV-8 | P1 | Separate editor readiness/errors from transport readiness; preserve working DCV/web sessions on editor failure. |
| RV-9 | P1 | Optional backwards-compatible editor/folder settings; structured launch/URI escaping; no hardcoded private paths. |
| RV-10 | P0 | Stop/quit/profile switch never force-close editor windows, lose unsaved buffers or delete remote data. |

## 6. Acceptance Criteria

| ID | Scenario | Required evidence |
|---|---|---|
| AC-R1 | Fresh configured workstation; double Open while all transports off | One preparation; native remote folder opens; DCV/web stay off. |
| AC-R2 | Missing VS Code or Remote - SSH; consent cancelled | Clear prerequisite result; no writes/installs/workstation start. |
| AC-R3 | Custom SSH/editor config, alias collision or policy | Existing config preserved; explicit conflict, not silent global replacement. |
| AC-R4 | Initial key authorization expired; second window/slow download/reconnect | New native SSH channels authenticate without permanent keys/manual commands. |
| AC-R5 | Native folder, dotted/spaced/Unicode paths | Exact folder authority; open/save, terminal, IntelliSense and project test verified. |
| AC-R6 | Two workstation identities or replaced instance/user | No channel/key/socket/window crossover; explicit stale-generation recovery. |
| AC-R7 | Remote server download or runtime/forwarding requirement missing | Distinct actionable failure; no privileged/system/security workaround. |
| AC-R8 | Multi-user socket-server setting already enabled | Verified compatible authenticated flow, or explicit unsupported prerequisite; no override. |
| AC-R9 | Transport drop, expired SSO, app quit/relaunch | Honest reconnect/sign-in state; no direct fallback or silent workspace redirection. |
| AC-R10 | Stop Remote Access with DCV/web running and unsaved editor content | Only owned editor transports stop; other sessions and editor buffers remain. |
| AC-R11 | Restore after setup, including later user changes/app move | Only still-owned integration removed; newer values retained; helper-path drift detected. |
| AC-R12 | Fresh Mac/user with app + supported VS Code | End-to-end bootstrap without AWS CLI, hand-edited config or a manual tunnel script. |

Unit tests cover args/URI/config ownership/key leases/generations. Real Remote SSH tests prove
channel, server, concurrency, user isolation and editor workflows; a successful SSH port probe
or process launch alone cannot mark these criteria met. Performance comparison is human-observed
editor responsiveness on the same workspace; do not invent a numerical speed-up guarantee.

## 7. Sources and Open Decisions

- [Microsoft Remote SSH](https://code.visualstudio.com/docs/remote/ssh): execution model,
  prerequisites, user-scoped VS Code Server and local-download fallback.
- [Microsoft troubleshooting](https://code.visualstudio.com/docs/remote/troubleshooting):
  multiple SSH connections, ControlMaster, socket-mode incompatibility and remote launch URI.
- [AWS EIC temporary keys](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-instance-connect-methods.html):
  authorization lifetime must be accounted for per connection, not treated as a permanent key.
- Native SSH Include setup and the standard VS Code server flow were approved by the user.
  The remote folder was left blank so folder selection stays with the user in VS Code.

## 8. Executed Preview Evidence

- Installed local VS Code 1.140.0, ARM64, commit `07f806f999227108933c2e30515b26eecc1fda74`;
  Microsoft Remote-SSH present; OpenSSH 10.3p1 verified.
- `realSSHCommandChannelsRefreshAuthorization` passed in 75 seconds: raw SSH-over-SSM command
  output exactly matched the harmless marker for two independently authorized channels, with
  the second opened after 65 seconds. Isolated temporary config/keys were cleaned up; normal
  SSH/editor configuration was untouched by that transport proof.
- `previewNativeEditorMenu` passed: actual menu click, approved Include consent, owned lease
  permissions/owner identity, packaged-helper host configuration and native editor launch.
  Existing SSH hosts were retained. No DCV or web proxy was started by the editor coordinator.
- A further owned SSH channel observed the standard current-commit VS Code Server executable
  on the management VM. This is server-installation evidence, not proof of every workspace feature.
- URI escaping, strict host-key/agent-forwarding boundaries and conditional SSH Include restore
  passed focused unit tests. Initial full suite passed 195 tests/31 suites; opt-in transport/menu
  checks were executed separately. Output is recorded in `/tmp/ssm-native-editor-full-tests.log`.
- The sequential Debug preview rebuild completed with its matching Debug helper embedded;
  executable presence and deep/strict app signature verification passed. No release, commit or
  push was performed. The native window remains available for folder selection.
- Local CodeQL lint, lockfile stability and diff formatting passed. Hosted CodeQL remains
  unverified by these local checks.
- Author review regressions for bounded CLI timeout/cancellation/output and pending-open profile
  changes passed. The optimized suite after those fixes passed 197 tests across 31 suites.
- An isolated remote fixture was created using the approved SSH lease and the existing
  VS Code Server Node runtime. No existing repository was inspected and no package was installed.
  Native file opening displayed the owned remote source; a native UI edit/save was verified
  through an independent SSH read of that same fixture file. The project test passed afterward.
- The actual integrated terminal ran the fixture project test and wrote an independently
  verified remote proof file. The TypeScript service's native Go to Definition moved the
  cursor from the call site at line 2 to the declaration at line 1.
- The fixture folder's configured debugger started, paused on entry (Continue control visible),
  and emitted `SSM_EDITOR_BUILD_OK=42` in the native Debug Console after Continue, then stopped.
- Initial connection attempts encountered a stale cached local forwarding port and a reconnect
  dialog. A fresh SSH SOCKS channel reached the live server port, and a subsequent native
  connection recovered. These observations do not establish automatic recovery in every case.
  The unreliable keyboard-driven test attempt was removed; these UI actions were directly
  executed and inspected through guarded native accessibility/System Events operations.
- Still unverified: arbitrary user projects, simultaneous windows, live multi-user socket-server
  mode, full app/drop/SSO recovery, and
  fresh-Mac/user bootstrap. These are not marked met by an SSH marker or CLI launch.

## 9. Recovery Coverage Follow-Up (2026-10-14)

The user explicitly chose to finish remaining coverage rather than publish the tested
preview scope. Release remains unapproved.

- An expired lease now renews on explicit Open only after validating the exact profile,
  account/SSO/role/region, tag selector, instance and OS-user identity. Changed identities
  still require a separate decision; renewal never silently redirects an existing workspace.
- `reopeningExpiredLeaseCreatesFreshOwnedGeneration` executed the coordinator twice around
  an expired journal and verified a new key/generation on the same target. Identity mismatch
  and expiry-boundary checks passed independently.
- Double Open deduplicates preparation and later same-target Open reuses its owned key and
  generation. Sign-in-required refusal does not reach EC2 or create a lease and can be retried.
- Empty-state cancelled consent performs no SSH-config write or AWS operation. Missing editor
  prerequisites are refused before AWS. These local fixture tests passed.
- The full retained suite passed 202 tests across 31 suites. Live probes remain opt-in.
- Explicit `SSM_REMOTE_INTERACTIVE_SIGNIN=1` on the live probe uses the normal native
  authentication flow with a bounded approval window. Without that opt-in, the probe
  remains silent and refuses an expired sign-in. It never accepts credentials through chat.
- The initial expanded live probe refused expired cached sign-in. Explicit native sign-in
  then succeeded and three concurrently authorized channels returned distinct expected
  markers, followed by fresh authorization after 65 seconds. A duplicate attempt failed
  quickly; a bounded repeat with private per-channel diagnostic classification passed in
  81 seconds. One pass is not treated as proof of every reconnect condition.
- An owned temporary Unix socket on the VM was reached through a fresh SSH `-L` channel,
  with loopback-only local binding and private remote permissions. Expected output matched,
  and the owned server/socket were cleaned up. No sshd or global editor setting was changed.
  This verifies stream-local forwarding, not a full multi-user VS Code socket-server session.
- Full concurrent editor windows, native multi-user socket mode, arbitrary SSO/policy and
  drop/app-relaunch recovery remain open. The user's active preview lease/session was not
  replaced or stopped by these probes.
- Local fresh directories validate setup boundaries, not a genuinely fresh Mac, remote-user
  provisioning or enterprise identity-provider behavior. Those acceptance scopes remain open.

## 10. Owned-Channel Shutdown Follow-Up (2026-10-14)

- Proxy task cancellation now stops its owned plugin even when cancellation interrupts the
  polling sleep. An invalidated lease receives a bounded graceful-stop period followed by
  force-stop of only that child if needed.
- Local process tests verified invalidation, cancellation, refusal to kill an unrelated child,
  and a SIGTERM-ignoring fixture stopped after the grace period. Focused bridge tests passed.
- The extended live probe passed in 87 seconds using its own temporary key/config/lease:
  concurrent channels, fresh authorization after 65 seconds, temporary lease deletion stopping
  its held channel, and a fresh-generation reconnect returning the exact expected marker.
  No real app lease, editor window or normal SSH configuration was deleted or replaced.
- The probe may explicitly select either approved SSM Connect bundle identity as its live
  owner via `SSM_REMOTE_PROBE_OWNER_BUNDLE`. This is a test-only whitelist, not relaxed
  production ownership validation. The main app was used when the preview was closed.
- Disposable external UI/login/forwarding scripts were removed after session setup/testing.
  Reproducible package tests and documented observation/fixture scripts remain.

This adds isolated channel-stop/reconnect evidence, not a complete native-window app-quit/
relaunch test or a genuine fresh-Mac/multi-user/enterprise-policy acceptance. Those gates
remain open and release is still unapproved.

## 11. Device-Login Handoff Follow-Up (2026-10-15)

- A pending native device-code grant rejected with `InvalidGrantException` now checks for a
  completed, still-valid login in the cache for the same SSO start URL and region. It adopts
  that login without opening another authorization browser. Without one, it reports
  `signInRequired` instead of exposing the SDK exception or looping device authorization.
- Both rejection cases failed before the fix and passed afterward. All 13 authentication
  tests passed, followed by the complete retained suite: 206 tests across 31 suites.
- The current-source local Release package rebuilt and passed deep/strict signature
  verification. This is a local package, not a published or notarized release.
- The existing native editor fixture accepts an explicit approved `--profile-id` and an
  isolated `--socket-mode`. Its temporary editor profile retains normal settings elsewhere,
  uses the known Linux platform and local-server startup, and places the standard socket-mode
  server installation under its disposable remote fixture rather than restarting the user's
  existing server. Electron-only runner flags are removed from the editor child's environment.
- `--socket-mode --verify` requires an actual native Unix-socket listener and resolved remote
  authority. It explicitly does not certify workspace UI actions from CLI launch or log output.
  Both native transport checks passed. The actual socket-mode window displayed the owned remote
  source; a native edit/save was independently read back through SSH and the project test passed.
  The actual integrated terminal also ran that project test and wrote an independently verified
  remote proof. No existing user repository was inspected.
- This verifies native socket-mode transport, file editing and terminal use on the tested
  workstation. Socket-mode debugger/language-service flows, different Linux users and genuinely
  fresh-Mac/enterprise-policy scenarios are not inferred from those passes.
- Normal app, DCV, browser, SSH and editor settings were not restarted or overwritten.
  Only owned temporary fixture editor instances were restarted during this verification.

## 12. Approved Preview Recovery (2026-10-15)

- The user approved one deliberate preview quit/relaunch while leaving the main app/DCV
  untouched. A matching updated Debug app/helper was built and signed in a separate build
  directory before the old preview was normally terminated.
- Before that quit, the old 24-hour lease naturally expired. A fresh SSH command refused
  authorization rather than bypassing expiry. This is expiry evidence, not proof that the
  subsequent quit caused that original disconnect.
- The updated preview relaunched with the saved workstation configuration. Its native
  Open VS Code action created a new process-owned lease generation; a fresh authorized
  channel reached the existing disposable fixture and its previously saved content.
- Preview web forwards returned to On through their native menu action, followed by Open
  Browser. The independently running main app retained the same process throughout.
- The existing socket fixture displayed Microsoft's explicit Reload Window recovery dialog
  after the drop. A subsequent live capture showed the same editor process reconnected, and
  the recovered fixture project test passed. This does not establish automatic recovery in
  every case or identify which prior reload attempt completed the connection.
- A separate controlled native Reload Window test added an unsaved fixture marker, confirmed
  it absent on the VM through an independent SSH read, reloaded the socket-mode window, and
  saved the surviving buffer. The exact marker was then read back from the VM and its project
  test passed. No second preview restart or main-app/DCV interruption was required.
- A genuine fresh-Mac/user and enterprise-policy run remain unverified.

No merge, public release, privileged remote changes or existing repository inspection was
performed. The release gate remains with the human owner.

## 13. Concurrent Native Workflows and Host Prerequisites (2026-10-15)

- The fixture's `--socket-mode --second-window` creates only an owned remote subfolder and
  opens it in the existing isolated editor profile. Both native windows resolved the same
  approved remote authority. Their encoded workspace URIs identified the exact two folders.
- A different marker was saved through each actual native editor window. Independent SSH
  reads verified each marker in its intended folder and absent from the other. Both project
  tests passed while both windows remained open. CLI launch alone was not counted as a pass.
- Socket-mode TypeScript Go to Definition moved from the call site at line 2, column 18 to
  its declaration at line 1, column 17 in the native editor.
- The configured socket-mode debugger visibly paused, continued through the native action,
  emitted `SSM_EDITOR_BUILD_OK=42` and the fixture markers in Debug Console, and ended normally.
- The live native socket belonged to the mapped OS user, but its mode was `0775` under a
  `1777` temporary directory. Group-write access means this observation does not establish
  owner-only multi-user isolation. Private socket permissions/location or an independently
  verified isolated group are a host/server prerequisite; no umask, socket, sshd or group
  permissions were changed to force the test to pass.
- Remaining external acceptance requires an approved clean Mac/OS user, a second provisioned
  Linux identity for a real cross-user attempt, and the actual enterprise SSO/policy context.
  Existing-user fixture passes are not substitutes for those environments. The earlier
  preview's natural expiry also remains distinct from quitting an unexpired lease.

## 14. Release Acceptance and Optional DCV Launch (2026-10-15)

- The user approved merging this feature to main and publishing the normal stable release
  for the existing users, with a colleague's installation providing real fresh-user feedback.
  A new Mac or Linux account is not a prerequisite to this accepted release scope. Unverified
  scenarios and the observed socket group-write permissions remain documented, not certified.
- Each profile now offers **Open DCV Viewer automatically**, enabled for existing profiles.
  Turning it off persists `connectAction = tunnelOnly`. Connect and reconnect still require
  the owned local SSM listener, but skip DCV readiness, password fetch, virtual-desktop
  provisioning and Viewer launch in both single-user and multi-user modes. Editor/browser
  transports and their actions remain independent.
- Focused tests cover persistence/default compatibility, both connect modes, reconnect, and
  refusal when the local listener is absent. All 209 tests across 31 suites passed using the
  matching Xcode Swift toolchain. Dependency versions and host configuration were unchanged.

## 15. Automatic Editor-Lease Continuation (2026-10-16)

**Status: required follow-up, explicitly requested by the owner on 2026-10-16; not implemented
or accepted as passed.** Credential renewal does not implement editor-lease continuation.
The current release candidate still requires explicit Open VS Code after a local lease expires.
This known limitation must appear in its release notes rather than being described as fixed.

### 15.1 Observed Failure and Recovery

The existing editor-access lease expired on **2026-10-16 at 12:00:07 CEST**. The original
VS Code SSH channel closed at that same instant; subsequent attempts failed in the local proxy
before SSH could reach the workstation. The lease owner and restricted key files still existed,
and the matching cached AWS SSO access token was valid. This was a local lease-lifetime failure,
not evidence that the remote project, AWS login or workstation had disappeared.

The supported Open VS Code action in the same running lease-owning app renewed access after
checking the same selected profile. The original workspace reconnected at **15:07:55 CEST**,
with the same SSH authority, instance and Linux user. No app/workstation restart, installation,
direct-SSH fallback or manual lease extension was used. The action also opened an extra editor
window; the original window reconnected and neither was closed.

The renewed lease expires on **2026-10-17 at 15:07:45 CEST** (`2026-10-17T13:07:45Z`).
That is an observed deadline for this recovery, not a promised automatic extension or an AWS
SSO-session expiry. The incident establishes manual recovery only.

### 15.2 Required Behavior

- While the app continues to own explicitly enabled access to the same workstation/user, renew
  its editor lease before the known local deadline without another Open VS Code action, a new
  editor window, focus changes, app restart or discarded editor/terminal state.
- Bind continuation to the existing app identity/launch, local profile identity, authorization
  context, resolved instance, OS user and owned generation. Revalidate these before committing
  a renewal and before resuming any pending channel; a changed target is not a renewal.
- Deduplicate renewal across editor windows and independent proxy invocations. Use a bounded
  renewal attempt and retry/backoff policy; a failed renewal must not spin, continually prompt
  or quietly grant an unlimited lease. Specify lead time, budgets and maximum key/lease lifetime
  before implementing; the five-minute auth lead is not an implicit lease-lifetime policy.
- Do not rotate/delete an identity file beneath in-flight native SSH authentication. Separate
  continuation of healthy established channels from authorization to open new channels; avoid
  an avoidable timer-driven disconnect during a valid same-owner renewal.
- If fresh interactive authorization is needed, expose persistent Sign In Required and one SSO
  action before a known deadline when possible. A valid AWS token does not remove a local lease
  failure, and a successful login does not itself prove editor reconnection.
- Stop Remote Access, app exit, owner mismatch, explicit revocation and changed target/user
  still fail closed. A renewal racing Stop/profile change must not recreate stopped access,
  redirect the old workspace or adopt another owner's key/generation.
- Preserve healthy DCV/web transports, normal SSH configuration, host-key checks and local
  VS Code buffers. Never fix a lease failure by modifying a remote repository, sshd, permanent
  authorized keys, user/group policy, or by weakening ownership/authentication checks.
- Show distinct local lease, AWS authorization and established-channel status, with an actionable
  recovery error and no tokens, credentials, session responses or presigned URLs in diagnostics.

### 15.3 Acceptance Criteria

| ID | Scenario | Required evidence |
| --- | --- | --- |
| LEASE-01 | Same-owner editor remains open across its original lease deadline | Synthetic-clock and controlled native tests observe one completed pre-deadline renewal; the original workspace/channel stays usable without Open, a new window or focus change. |
| LEASE-02 | Multiple windows/proxies reach renewal together | One bounded renewal per owned context/generation; concurrent SSH key loading succeeds and no in-use key is deleted. |
| LEASE-03 | A reconnect opens a fresh channel after the original deadline and EIC's 60-second window | The same existing authority reaches the same instance/user through SSM with fresh EIC authorization; no permanent key or manual reconnect preparation. |
| LEASE-04 | Renewal needs SSO, is offline, or access is denied | Distinct persistent status and bounded recovery; no prompt/retry storm or false claim that successful sign-in proves the editor connected. |
| LEASE-05 | Stop, quit, profile/target/user change or revocation races renewal | No stale continuation, access recreation, wrong-target replay or owner/generation crossover; valid healthy unrelated transports remain untouched. |
| LEASE-06 | Renewal or atomic lease persistence fails | Actionable local-lease error; no silent deadline extension, partial lease or unsafe fallback; local buffers survive any unavoidable channel loss. |
| LEASE-07 | Native long-working-day/overnight session spans at least the initial 24-hour boundary | Existing-window open/save, integrated terminal and project/language/debug actions pass before and after continuation; an SSH marker/listener or a fresh replacement window alone does not satisfy this criterion. |
| LEASE-08 | Renewal across declared key/lease-lifetime limits | Tests enforce the explicitly accepted limits, cancellation and key-generation handover without indefinite extension or mid-authentication key deletion. |

No acceptance criterion above is marked met by the October 16 manual recovery. Windows must run
its own native ownership/process/file tests before claiming the same continuation behavior.

## 16. Upgrade and Relaunch Workspace Continuity (2026-10-16)

**Status: owner clarified the required outcome; same-workspace reconnect was observed during
the v0.6.0 upgrade, but automatic upgrade/relaunch recovery is not implemented or accepted as
passed.** This is separate from extending a lease while its existing owner remains running.

The durable identity is the stored local workstation profile UUID and its SSH authority, not
an SSM session ID, temporary key, lease generation or app PID. Those transport/owner values may
change during an upgrade without creating a new remote workspace identity. Ordinary launches
must not allocate a replacement profile UUID. Import as Local Copy remains an intentionally
different identity and must not inherit an existing profile's access.

During the October 16 upgrade, the original VS Code window reconnected to the same SSH authority,
instance and Linux user through the installed v0.6.0 helper. Its logs reported the existing
remote VS Code Server process rather than a replacement installation. The development preview
used a different app bundle/storage namespace, so transferring its owned SSH integration to the
installed app was a one-time migration. This observation does not prove that every running agent
or extension-host process survived, or that an unattended future upgrade will recover itself.

### Required Behavior

- For an explicitly requested upgrade/relaunch of previously enabled editor access, retain the
  profile UUID, exact workstation/user and original workspace authority. Revalidate authorization,
  instance and ownership before creating fresh process-bound access.
- Recover access for the original VS Code window instead of opening a random/new workspace or
  unconditionally creating another window. Do not close/reload the editor, discard buffers,
  reinstall/delete VS Code Server state, reset extension storage or restart remote agents.
- Reestablish the owned transport after the old app exits; do not reuse a dead owner's lease or
  copy its PID/generation as if still valid. Preserve host-key trust and unrelated SSH hosts.
- Keep recovery idempotent and bounded. If SSO or an ownership/target decision is needed, expose
  that specific action; do not fall back to another workstation or silently enable auto-connect.
- Explicit Stop Remote Access, revocation or intentional Quit must not be undone by background
  recovery. Define the upgrade/relaunch resume intent separately from those cancellation actions.
- Preserve access to the same agent/conversation context where the existing editor/server
  supports it. Durable chat history and live agent execution are distinct: a dead remote process
  cannot be claimed restored merely because the SSH authority reconnects.
- Treat the macOS first-launch trust warning separately from transport/session recovery. The
  ad-hoc-signed v0.6.0 release is not notarized; proper signed/notarized distribution is a separate
  requirement, not permission to disable system-wide launch protections.

### Acceptance Criteria

| ID | Scenario | Required evidence |
| --- | --- | --- |
| UPGRADE-01 | Upgrade/relaunch with an existing remote workspace open | The original profile UUID/SSH authority and exact target/user remain stable; fresh access is established without another workstation/profile or forced new editor window. |
| UPGRADE-02 | Existing agent/conversation and unsaved editor state | Native before/after checks show the same original workspace, buffers and existing agent/conversation context remain accessible. Report separately whether live agent execution continued; SSH/server reuse alone is insufficient. |
| UPGRADE-03 | New app PID/key/generation and expired initial EIC authorization | The original window opens new authenticated channels through the new owner, without weakening lease/host-key checks or requiring a permanent remote key. |
| UPGRADE-04 | Repeated upgrade/recovery, including preview-to-installed migration | Recovery is idempotent; checked migration preserves unrelated integration and trust. Later ordinary upgrades need no repeat preview migration or identity reset. |
| UPGRADE-05 | Stop/revocation/intentional Quit or changed target races recovery | No recreation of stopped access, stale-owner adoption, wrong-target replay or accidental global auto-connect enablement. |
| UPGRADE-06 | Missing authorization, damaged integration or macOS launch refusal | Distinct actionable recovery state, original workspace retained, and no claim of success until the original window reconnects. |

The observed v0.6.0 handover establishes same-workspace reconnectability, not automatic recovery
or complete agent continuity. UPGRADE-01 through UPGRADE-06 remain unverified as a complete feature.