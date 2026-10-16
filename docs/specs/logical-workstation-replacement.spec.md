# SPECIFICATION: Same Workspace and Native Forwarding After Workstation Replacement

- **Status:** use case raised by the owner on 2026-10-16; source assessment and proposed contract,
  not implemented, production-approved or accepted as passed.
- **Baselines:** released macOS v0.6.0 and the same-owner rolling-lease fix merged in PR #28.
  Neither provides a complete physical-instance replacement/rebind workflow.
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

## 2. Source-Verified Existing Coverage

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

All replacement criteria remain **not verified**. Existing lease-renewal, reboot/canary and editor
fixture tests do not close them. Windows and any required GPU/DCV/multi-engineer workflows need
their own native acceptance before they are declared supported.

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
