# SPECIFICATION: Native VS Code workspace bootstrap over SSM

- **Status:** implemented preview, 2026-10-13; the user approved continuation and native SSH
  setup. Verified transport/menu/server evidence is recorded below; workspace-level acceptance
  and fresh-user/multi-user socket-mode gates remain open.
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

The existing implementation proves AWS authentication, user mapping, EIC key authorization and
SSH-over-SSM forwarding. It currently launches `ssh -N -T`, has no editor bootstrap or SSH host
entry, and owns a key for that forwarding connection's lifetime. Adding a loopback forward to
port 22 would still require a separate SSH authentication for VS Code, including fresh EIC
authorization. Browser PAC configuration does not configure Remote SSH.

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
  passed focused unit tests. Current full suite passed 195 tests/31 suites; opt-in transport/menu
  checks were executed separately. Output is recorded in `/tmp/ssm-native-editor-full-tests.log`.
- The sequential Debug preview rebuild completed with its matching Debug helper embedded;
  executable presence and deep/strict app signature verification passed. No release, commit or
  push was performed. The native window remains available for folder selection.
- Local CodeQL lint, all eight staged Dependabot YAML drafts, coverage assertions, lockfile
  stability and diff formatting passed. Hosted CodeQL and updater publication remain unverified.
- Still unverified: chosen-folder open/save/terminal/language server/project tests/debugging,
  simultaneous windows, live multi-user socket-server mode, full app/drop/SSO recovery, and
  fresh-Mac/user bootstrap. These are not marked met by an SSH marker or CLI launch.