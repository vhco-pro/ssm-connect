# SPECIFICATION: Private-domain browsing in VS Code over SSM

- **Date:** 2026-10-16.
- **Status:** proposed; source investigation complete, native integration/prototype gates open.
  This document does not enable a browser feature, change a workstation or establish a tunnel.
- **Outcome:** the local VS Code integrated browser reaches selected private workstation web
  domains through SSM Connect, at their original HTTPS URLs, including authentication callbacks.
- **Investigation baseline:** then-published SSM Connect release `v0.6.0`
  (`b6956ee0b66f0ae50a6a392df1850a2cef6b8e73`); investigation uses fetched `origin/main`
  `96afb76e8659ee64e92ed9619ef5082ea17153ec`, including the later same-owner lease-renewal fix.
- **Related:** [Web forwards](./web-forwards.spec.md),
  [managed browser bootstrap](./browser-bootstrap.spec.md),
  [Remote VS Code](./remote-vscode.spec.md),
  [portable profiles](./portable-profiles.spec.md).
- **Consolidation (2026-10-17):** stable `v0.6.1` / main `96afb76` is the new implementation
  baseline. This proposal and the [logical replacement contract](./logical-workstation-replacement.spec.md)
  share one combined PR, not two independent implementations. Section 12 records the exact
  installed-editor capability check; it does not claim native Browser acceptance.

## 1. Problem and evidence boundary

The following **generalized/anonymized reproduction pattern** motivates this specification.
All application/authentication names are synthetic fixtures, not deployment identifiers:

| Generalized reproduction observation | Meaning |
|---|---|
| The remote workstation's corporate/private resolver answers `app.private.example.test` and `auth.private.example.test` with private RFC1918 destinations. | The private namespace exists in the workstation's network view. It need not be resolvable on the Mac. |
| A remote HTTPS request to the application `/health`, without an HTTP proxy, returns 200. | At that time the remote network, DNS and application health path worked. This is not proof of browser login or local reachability. |
| The local Mac VS Code Browser reports `ERR_NAME_NOT_RESOLVED` (`-105`). | That browser navigation does not have an effective working remote-name-routing path. |

This pattern generalizes reported symptoms; it is not a new controlled test executed for this
specification, nor a transcript of private incident evidence. Actual internal FQDNs, addresses,
usernames, account/instance/profile identifiers, app registrations, cluster names and topology
are excluded from this public document. Future approved tests use these synthetic fixtures or
keep environment-specific inputs/results in private records. The two names are distinct origins
even in a fixture where they happen to share a private destination address.

Remote - SSH moves terminals, builds and many extensions to the workstation; it does **not**
automatically give every local Electron/browser session the workstation's DNS or HTTP route.
The integrated browser renders locally. Agent browser tools and their `pageId` handles do not
themselves select a proxy or DNS resolver. A remote `curl` success therefore cannot validate
the browser's network path.

The immediate failure class is the missing or ineffective browser-specific name/transport
route, not evidence that private ingress, Kubernetes or public DNS must be changed. The exact
installed Mac SSM Connect version, selected profile, configured private-domain entries, PAC
contents/application, browser settings/storage scope/policy and proxy state were not captured.
It is also unknown whether Web Forwards was enabled alongside Remote Access or remained alive
for that browser navigation. A missing app/auth domain entry, wrong profile, inactive forwarding
or a forwarding-lifecycle problem are possible explanations, alongside browser-session routing
configuration. This is a reproduction report, **not a confirmed SSM Connect client bug or proof
of Electron proxy incompatibility**. Do not assert which cause applies without native evidence.
Working remote DNS alone does not establish a browser-to-proxy-to-remote TCP/TLS path; changing
DNS alone is not a proposed routing fix.

## 2. Existing capabilities and proven gaps

### 2.1 SSM Connect source

The following paths were inspected at the baseline main revision:

| Source | Observed behavior and implication |
|---|---|
| [`Tunnel/SSHTunnel.swift`](../../SSMConnectKit/Sources/SSMConnectKit/Tunnel/SSHTunnel.swift), `SSHCommand.arguments`, `WebForwardsPAC` | SSH-in-SSM with `-D 127.0.0.1:<port>` and explicit `-L` forwards, under the selected SSH user. PAC lowercases the host, matches configured `proxySuffixes` with `dnsDomainIs`, returns one `SOCKS5` endpoint for a match, and `DIRECT` only for other hosts. It does not use `dnsResolve`. |
| [`Models/ConnectionProfile.swift`](../../SSMConnectKit/Sources/SSMConnectKit/Models/ConnectionProfile.swift), [`Settings/ProfileEditorValidation.swift`](../../SSMConnectKit/Sources/SSMConnectKit/Settings/ProfileEditorValidation.swift) | Workstation UUID, Web Forwards settings, SOCKS port and leading-dot suffix list already exist. Validation checks port collisions within a configuration and suffix syntax. There is not yet an exact-host route list or integrated-browser capability. |
| [`Services/BrowserBootstrap.swift`](../../SSMConnectKit/Sources/SSMConnectKit/Services/BrowserBootstrap.swift), `BrowserDescriptor`, `BrowserRouting` | Managed external Chromium launch uses an owned data directory and a data-URL PAC. Firefox-family preferences include remote SOCKS DNS, no direct failover and disabled DNS prefetch. The implemented allowlist is Chrome `156.0.8078.12` in separate-browser mode and Zen `1.23.1b`; discovering Edge/Firefox does not make them verified. VS Code is not a descriptor. |
| [`Services/FirefoxProxySetup.swift`](../../SSMConnectKit/Sources/SSMConnectKit/Services/FirefoxProxySetup.swift), [`StateMachine/WebForwardsStateMachine.swift`](../../SSMConnectKit/Sources/SSMConnectKit/StateMachine/WebForwardsStateMachine.swift) | Existing-browser conflict/restore handling, profile-owned routing, auth/SSM preparation and supervised native forwarding exist. These are reusable ownership/lifecycle patterns, not proof that Electron honors their settings. |
| [`Tunnel/RemoteSSHBridge.swift`](../../SSMConnectKit/Sources/SSMConnectKit/Tunnel/RemoteSSHBridge.swift), [`StateMachine/RemoteDevelopmentStateMachine.swift`](../../SSMConnectKit/Sources/SSMConnectKit/StateMachine/RemoteDevelopmentStateMachine.swift) | Editor access uses a separate raw-stream SSH proxy helper and credential-free owned lease. `canReuse` rejects changed profile/account/role/region/tag selector/instance/user as `targetChanged`; `continues` also checks owner identity, launch date, generation, key and helper paths. Every new authorized channel resolves the target again. Do not bypass these guards to recover browsing. |
| [`contracts/connection-profile.schema.json`](../../contracts/connection-profile.schema.json) | Portable Web Forwards and Remote Development capabilities are separate. Browser support must not become a silent prerequisite for ordinary editor access. |

The external-browser success evidence in the related specifications is not integrated-browser
acceptance evidence. An SSH listener, a generated PAC, a working terminal or an opened editor
window does not demonstrate that a BrowserPage request used the tunnel.

### 2.2 VS Code: a real remote feature, but not a selective PAC API

The existing Remote VS Code specification records installed VS Code Stable **1.140.0 ARM64**,
commit `07f806f999227108933c2e30515b26eecc1fda74`, with Microsoft Remote - SSH and
OpenSSH `10.3p1`; it does not record an exact Remote - SSH extension version.
This investigation also inspected upstream Stable **1.142.0**, released 2026-10-14,
commit `d956e8a6ac5d904486557eea07e1d6bd62a4d36f`.
Source `.npmrc` pins Electron `43.7.3` and `43.7.7` respectively; record the actual runtime
from the installed product in any future test, rather than treating a source pin as measurement.
See the pinned [1.140.0 engine configuration][vscode-140-engine] and
[1.142.0 engine configuration][vscode-engine].

Official [integrated-browser documentation][vscode-browser] describes **preview** remote
connections. Both inspected tags contain:

- `workbench.browser.enableRemoteProxy`, an experimental window-scoped boolean whose source
  default is false for Stable and true for non-Stable builds. Experiments, policy and user
  settings can affect effective behavior; inspect the actual value.
- `workbench.browser.dataStorage`: global storage is incompatible with remote proxying.
  The source default value `default` selects workspace storage for remote workspaces and
  global storage for local ones. Untrusted workspaces use ephemeral storage.
- A remote indicator when proxying is active. `file://` is not proxied. Localhost links use
  the remote original URL when remote proxying is enabled rather than the forwarded local URL.
  Agent-opened tabs are documented as participating, but must still be tested in their actual
  session/storage scope.

The exact schemas are in [browserRemoteFeatures][vscode-remote-setting] and
[browserDataStorageFeatures][vscode-storage-setting]; these, rather than guessed settings,
bound the prototype configuration.

At 1.142.0 the source path is:

1. [`MainThreadBrowserTunnelProxy`][vscode-main-thread] gates on a remote authority and the
   remote-proxy setting.
2. [`NodeExtHostBrowserTunnelProxy`][vscode-ext-host] runs an HTTPS proxy in the **local**
   node extension host. It uses `connectRemoteAgentTunnel(options, host, port)` over the
   established Remote - SSH/remote-agent connection, not SSM Connect's Web Forwards SOCKS port.
3. [`TunnelProxy`][vscode-tunnel-proxy] passes the CONNECT hostname, or absolute HTTP URL
   hostname, into that tunnel. The [remote-agent server][vscode-remote-server] dials
   `net.createConnection({host, port, ...})` remotely. This is a source-supported remote-DNS
   mechanism, not an assumption that the local resolver can resolve private names.
4. [`BrowserSessionRemote`][vscode-session-remote] calls Electron
   `session.setProxy({proxyRules: info.url, proxyBypassRules: '<-loopback>'})`.
   It excludes global storage, applies one fixed proxy to the session, and resets the session
   to `direct` when its final proxy reference is released. It does not install a domain PAC.
   Its own comment warns that shared sessions across windows can have last-applied-proxy wins.
5. [`BrowserSession`][vscode-session] uses a global persistent partition, workspace-specific
   storage path, per-view ephemeral partition, or agent partition keyed by affinity/workspace/
   window. None is automatically an SSM Connect profile/account/user identity.

The remote-session proxy and setting also exist in the inspected [1.140.0 source][vscode-140].
This is a bounded source comparison, **not** certification of every intervening/future build,
Insiders, a VS Code fork, vscode.dev, or the Mac's effective runtime configuration.
The installed editor version recorded in the existing spec is historical evidence, not a new
inventory of the failing Mac session. Source API gaps below describe integration feasibility;
they do not identify the cause of that particular navigation failure.

There is no selective/private-domain proxy control in the inspected stable extension
[`vscode.d.ts`][vscode-stable-api]. The proposed [`vscode.proposed.browser.d.ts`][vscode-browser-api]
offers `BrowserTab`, opening/closing tabs and a CDP session, but no proxy/PAC/resolver selection
or account-scoped network partition. Proposed APIs and internal workbench services are not a
stable third-party integration contract. Electron's [session proxy API][electron-session]
belongs to its main process; its existence does not grant an ordinary extension access to it.

**Consequences:** preview remote proxying can address the DNS failure in a properly scoped
remote window, but routes the session's HTTP(S) through the remote connection without native
domain selection. Its reset-to-direct and shared-session behavior need explicit examination.
It is not evidence that SSM Connect's PAC was consumed, that public IdP traffic stayed local,
or that selected private hosts stay blocked during every disconnect.

## 3. Goals, invariants and non-goals

### Required product behavior

- Route configured private domains through the selected workstation and its DNS view, reusing
  native Web Forwards policy and transport where the integration permits it.
- Keep original HTTPS scheme, hostname, port, path and origin throughout browsing and SSO.
  Preserve SNI, HTTP Host/HTTP2 `:authority`, redirects, cookie scope and certificate validation.
- Support the application **and** its separate private auth/callback origin, plus public
  Entra ID/Okta login, federation, MFA, logout and return redirects.
- Apply routing to the integrated browser's actual network session, including agent-created
  pages; never claim success from configuring a different browser or extension-host HTTP client.
- Fail closed for selected private hosts across startup, policy errors, transport loss,
  app/editor restarts and replacement. No selected-host `DIRECT` fallback.
- Leave unrelated browser sessions, other accounts/profiles/users, DCV, ordinary editor access
  and normal public browsing unchanged.

### Prohibited shortcuts / out of scope

No `/etc/hosts` rewrites, static destination-IP persistence, URL replacement with localhost/IP,
TLS termination/MITM, disabled certificate checks, public exposure of private ingress, OS-wide
permanent DNS/proxy changes, blanket routing of the machine's traffic, or silent broadening to
all company/IdP domains. A port forward alone is not a hostname-preserving HTTPS/SSO solution.

No new remote browser service, VM rebuild mechanism, AWS/IAM/SSO account changes, IdP registration
changes, cloud/network changes, current multi-user workstation changes or reboots are authorized
by this document. Do not run discovery tunnels, change localhost proxy configuration or trigger
authentication as part of writing/reviewing it. Actual prototype and native tests require a
separately approved environment; credentials and MFA remain with the user.
This work is independent of other application modernization or cloud-access workstreams.
It neither diagnoses their operational state nor authorizes any DNS changes.

## 4. Architecture decision and mandatory feasibility gate

### 4.1 Alternatives

| Option | Assessment / decision |
|---|---|
| Documented VS Code preview remote proxy with non-global storage | First, lowest-change **diagnostic prototype** on the exact supported build. It can prove remote DNS without modifying ingress. It is scoped to a browser session, not the OS, but offers no private-domain selector and sends public IdP traffic through the remote network too. It does not reuse native SOCKS. Not accepted as the selective product feature without a separately reviewed scope change and full fail-closed proof. |
| Supported per-session fixed proxy endpoint plus an app-owned domain-aware broker | Preferred product architecture **if a supported integration surface becomes available**. The browser sends its HTTP(S) to the owned loopback broker; only selected destinations traverse native SOCKS/SSM, while public destinations use the local permitted network path. This avoids PAC-download failure changing selected-host routing. Proxy configuration is browser-session scoped, not a global VPN. The currently inspected public VS Code API does not provide this surface. |
| Supported per-session PAC using native Web Forwards | Smaller adapter if VS Code adds/exposes a supported session PAC surface. Requires mandatory fail-closed PAC-load/error behavior and actual SOCKS5 remote-DNS/coverage tests. A PAC with no `DIRECT` in its matching branch is necessary but insufficient if the engine ignores or cannot load it. No such public VS Code surface was found. |
| Isolated VS Code process launched with Chromium/Electron proxy switches | Research-only candidate, not a supported configuration prescription. Must establish documented VS Code product support, exact version handling, process reuse behavior and per-session precedence first. A CLI switch recognized by Chrome is not evidence for an existing VS Code process or its Browser session. Do not ship undocumented `--proxy-pac-url`, `--proxy-server`, resolver flags or speculative settings. |
| Upstream VS Code capability request / supported adapter | Required path if no existing supported surface meets selection, isolation and failure invariants. Request per-session proxy/PAC, policy readiness/blocking and identity/lifecycle controls rather than patching private workbench code. |
| Managed external browser | Existing, separately verified fallback with honest labeling and existing consent/version gates. Useful while integrated support is blocked; it does not satisfy integrated-browser acceptance. |

Do not use `http.proxy`, shell `HTTP_PROXY`/`ALL_PROXY`, Remote - SSH dynamic-forward settings,
OS PAC discovery, a webview, CDP Fetch response rewriting, or an undocumented extension command
as a substitute for proving the Browser session's network configuration.

### 4.2 Gate G1: choose a supportable integration before implementation

Record a bounded compatibility report in the future implementation PR, not a claim that this
specification passed native tests. Required evidence:

1. Exact VS Code product/version/commit, Electron/Chromium runtime, Remote - SSH extension
   version, macOS version, window remote authority, Workspace Trust and actual browser storage
   scope, including tool-opened/shared pages and popups. Also capture the actual Mac SSM Connect
   version, chosen logical profile, app/auth domain entries, effective PAC and whether Web
   Forwards was enabled and healthy concurrently with Remote Access. Distinguish a configuration/
   lifecycle failure from a browser integration limitation before proposing changes.
2. Supported configuration/API and its documented scope/precedence; whether changes apply to
   existing sessions, require new tabs or require an explicitly approved isolated process.
3. A browser request with local private DNS unavailable, a hostname-bearing tunneled request,
   remote-side resolution/connection evidence, and no local DNS/connection for selected hosts.
4. Domain selection, public IdP/local path behavior, fail-closed startup/PAC failure/disconnect,
   localhost semantics, authenticated endpoint isolation and profile concurrency results.
5. A way to apply policy before any navigation, observe configuration completion, invalidate
   pooled connections on a binding change, and leave selected hosts blocked during teardown.

If only the preview all-remote path works, report **Remote proxy available; selective integration
unsupported**, not **Connected**. Offer the existing managed external-browser fallback.
Do not implement against private APIs or weaken an invariant to manufacture a passing prototype.
No integrated adapter is release-supported until G1 selects a documented, tested surface.

### 4.3 Conditional product flow

Once G1 succeeds:

```text
Local VS Code Browser session (identified, isolated, policy ready before navigation)
  -> supported session proxy/PAC adapter
  -> owned routing context for profile/account/region/role/remote user/generation
       selected private host -> native SSH SOCKS5 hostname -> SSM -> remote DNS/TCP
       public host           -> local approved network/proxy path
       selected + not ready  -> blocked/error, never local/direct
```

Reuse `WebForwardsConfiguration`, validation, native tunnel supervision and existing ownership/
restore patterns. Do not create a second manually maintained domain list for the editor.
The broker option is a proposed component, not existing code. If it is needed, it relays raw
CONNECT bytes for HTTPS without reading TLS/application credentials; plain HTTP handling must
not log authorization headers. Native SSH/SSM session authorization remains in SSM Connect.
With a healthy broker and only its remote transport down, public requests must still take the
local permitted path. Losing the broker itself can make public pages in that opted-in session
unavailable too; disclose this scoped availability tradeoff, while unrelated sessions remain
unaffected. Never restore availability by switching that session's private requests to direct.

## 5. Routing and DNS contract

### 5.1 Deterministic hostname matching

Private routing policy is persistent per logical workstation profile, not per ephemeral IP.
Initially import the existing leading-dot suffix list without changing its semantics.
An optional exact-host list is a future additive model/schema change, with portable capability
negotiation and validation; it does not exist in today's profile contract.

- Parse the URL/CONNECT authority, normalize the DNS hostname to lowercase ASCII/IDNA and
  consistently handle a final DNS root dot. Never apply suffix rules to an entire URL string.
- An exact rule matches only that hostname. A suffix `.private.example.test` matches
  `app.private.example.test` and deeper labels, not the apex `private.example.test`,
  `evilprivate.example.test` or `private.example.test.attacker.test`. Include the apex explicitly
  with an exact rule if required. Do not reinterpret legacy suffixes as arbitrary substrings.
- Reject malformed/empty domains, paths, credentials, ports embedded in host rules, ambiguous
  wildcard syntax and control characters. Prefer narrow exact rules for the app/auth pair;
  broad suffixes need explicit user review. Deduplicate equivalent canonical rules.
- Private classification wins over public exceptions. Every request/subresource/redirect is
  classified anew by hostname, including auth callbacks. Do not classify all redirects by the
  first page, by current resolved IP, or by a broad `*auth*` heuristic.
- A public destination stays on the local approved path, including a pre-existing mandatory
  enterprise proxy. Never silently bypass that proxy or install an OS-wide alternative.

An unconfigured dependency is not automatically approved as private. Report the host and the
route decision without tokens/query parameters; require a deliberate policy edit if it belongs
to the private redirect/resource graph. Fail-closed guarantees cover selected hosts, not an
invented ability to recognize every unknown private name on the Internet.

### 5.2 Remote resolution and leak prevention

For selected domains send the **hostname**, not a locally resolved IP, in SOCKS5 CONNECT
(`ATYP=DOMAINNAME`) or the supported remote CONNECT equivalent. The selected remote SSH user's
network context performs resolution. Do not add local DNS preflight as a prerequisite.
`curl --socks5` can resolve locally; a future transport diagnostic must deliberately use
hostname-proxy semantics such as `--socks5-hostname`. Neither curl variant proves browser routing.

PAC must use hostname-only exact/boundary matching. No `dnsResolve`, `dnsResolveEx`, `isInNet`
or resolver-based network detection for selected names: these can invoke local DNS **before**
proxy selection. No private-address mapping or global `host-resolver-rules` workaround.
See [Chromium's SOCKSv5/PAC documentation][chromium-proxy] for proxy-side DNS semantics.

Negative tests must cover OS DNS, speculative prefetch, Electron/Chromium caches, secure DNS/
DoH, IPv4/IPv6 attempts and alternate service-worker/utility-process paths. A SOCKS5 connection
alone does not demonstrate absence of other DNS lookups. Use cold unique test names and
appropriately scoped observations in the approved environment. If the supported adapter cannot
prevent selected-name leaks, mark the combination unsupported.

Remote NXDOMAIN/timeout produces a **Remote DNS** diagnosis, not local fallback. Retire remote
answers, connection pools and route fingerprints on target/user/generation changes; never persist
the observed private IP as a replacement-readiness shortcut.

### 5.3 Failure and proxy ownership

- Selected routes return only their owned proxy; no `SOCKS5 ...; DIRECT` or `PROXY ...; DIRECT`.
  Public-direct routing is a separate nonmatching rule, not error recovery for private requests.
- Missing/stale policy, unavailable broker/PAC, bind conflict, wrong listener identity, auth
  expiry, remote DNS failure and SSM loss block selected requests. Do not change a private rule
  to direct to keep public browsing working. PAC fetch/parse/runtime errors must also block;
  reject a PAC adapter if its engine silently defaults to direct.
- Verify endpoint ownership and generation, not just that some process accepts a TCP connection.
  Bind to loopback only, collision-check across profiles and `-L` forwards, and never kill an
  unrelated listener or steal its port. Port allocation changes are staged and applied atomically.
- Keep a blocked/dead-proxy policy for private tabs while disconnected. Closing the app,
  releasing an Electron proxy reference or restoring another setting must not expose selected
  requests to the local network. Apply a supported blocking state before release; if impossible,
  require an explicit tab/session shutdown handoff or reject that adapter at G1.
- Await proxy application before navigation and invalidate old pooled sockets during controlled
  rebinds. Electron documents that `setProxy` alone can leave old connections in use.

## 6. HTTPS, authentication and browser coverage

The `app.private.example.test` and `auth.private.example.test` origins must both be private
routes; sharing a destination address does
not merge certificates, cookies or callback URLs. The browser uses their original HTTPS URLs
through CONNECT/SOCKS; the proxy must not substitute localhost, an IP, another Host header or
its own certificate. Certificate expiry, hostname mismatch or an untrusted chain must remain
real errors. Existing approved enterprise CA trust may be used, never silently installed.

Public Entra ID/Okta/federation/MFA pages generally use the local permitted route, while every
return to a selected app/auth hostname uses the remote route. Public reachability is not assumed:
conditional access, source-network requirements, third-party-cookie policy, popup partitioning,
logout propagation and device posture can all affect the result. Record the redirect host graph
and route decisions with sensitive paths/queries removed. Do not broaden private suffixes or
alter identity-provider settings to fix a failed login.

Required coverage includes navigation, redirects, subframes, popups, fetch/XHR, static assets,
workers/service workers and their cache updates, SSE, `ws`/`wss`, downloads and resumed downloads.
Inventory the actual request owner: renderer/Electron network utility process, browser session,
local extension host, remote host or external helper. A download delegated to a different process
is not covered merely because the page loaded. Either preserve the policy through a supported
handoff or block and explain the unsupported action.

User-created and agent-created/shared pages must use the same intended routing identity without
silently sharing authentication data. The source `agent` storage mode exposes its cookies/storage
to agents; it is not a substitute for private user-session isolation. Do not copy browser profiles,
tokens or cookie databases into the app or diagnostics. User credential entry and MFA are manual;
automation may test a controlled signed-out fixture, not capture a real sign-in secret.

No UDP/WebRTC/QUIC tunnel coverage is implied by SOCKS5 TCP support. Detect/block unsupported
private-network escape paths or mark the workflow unsupported; do not allow direct UDP as fallback.

### Localhost and special destinations

Remote preview proxying uses `proxyBypassRules: '<-loopback>'`; in Chromium this **removes**
implicit localhost/link-local bypass rather than adding a bypass. Copying it blindly can send a
Mac-local OAuth callback to the remote workstation or expose remote local services.

Default product semantics: literal `localhost`, `127.0.0.0/8`, `[::1]` and `*.localhost` remain
local unless the user explicitly selects a separate, named remote-loopback forward. A private
FQDN is not exempt merely because a remote DNS answer happens to be loopback. Test the actual
engine's implicit bypass behavior; PAC and fixed-proxy modes can differ.

Remote-loopback services retain explicit opt-in and the mapped Unix user's access restrictions.
Do not grant wildcard access to remote loopback, link-local or instance metadata destinations
through the new browser broker. Non-HTTP schemes, `file://`, VS Code URI callbacks and custom
protocol handlers keep their documented behavior; disclose external opens instead of pretending
they inherited browser routing.

## 7. Identity, profiles and ownership

Persist only logical configuration: workstation/profile UUID, private exact/suffix policy,
adapter choice, consent/version compatibility and nonsecret settings-restore journal.
Account/role/region/selector and mapped remote Unix user are binding inputs, not editable
browser-only substitutes for the selected workstation's identity.

An active binding additionally includes resolved instance ID, remote authority, owning app launch
identity, current lease/transport generation, browser session/storage identity, endpoint ownership
and routing fingerprint. Distinguish logical profile persistence from permission to resume an old
lease. Never persist AWS credentials, proxy credentials, SSH secrets, browser cookies or SSO tokens
in portable profiles, launch arguments, logs or repository files.

Two profiles may intentionally use the **same hostname** with different remote DNS answers.
They require independent browser network contexts, cookies, connection pools and routing bindings.
Workspace storage is not proof of profile isolation; global storage is unacceptable, and
agent affinity must not span incompatible profiles. If a supported API cannot provide isolation,
deny concurrent binding and explain the conflict; never last-writer-wins or move a live session
to another account/user. An isolated editor process may be offered only through a supported,
explicitly consented mechanism that preserves ordinary editor windows.

Runtime metadata uses existing app-owned 0700 directories/0600 atomic files and excludes browser
session data. A new broker must authenticate an unguessable per-binding capability through the
supported browser proxy interface, enforce its route/port scope, and reject stale/cross-profile
callers. Do not create a generally usable loopback open proxy.

**Loopback is not Unix-user authentication.** Existing OpenSSH `-D` has no browser SOCKS
authentication in Chromium; a private PAC file alone does not stop another local user connecting
to a TCP port. G1 must state and test both local endpoint access and remote SSH-user ownership.
If strict local cross-user isolation requires a protected backend/OS mechanism, select a verified
mechanism before claiming support; wrapping an otherwise exposed SOCKS port is not sufficient.
Do not silently advertise a stronger guarantee than the reused native transport provides.

## 8. Lifecycle, replacement readiness and user experience

Expose **Enable private browsing in VS Code** as an opt-in capability next to Remote Development,
using the existing domain configuration. Show chosen adapter, scope and support status before
any setup. Existing-browser/editor policy conflicts are actionable and never overwritten.
Ordinary **Open VS Code** remains usable when this optional capability is unsupported.

Keep transport, browser routing and application authentication as distinct status layers:

| State / diagnosis | Required behavior / action |
|---|---|
| Disabled / unsupported version or API | No setup writes or background listener. Explain the missing capability; offer the verified external-browser action. |
| Preparing / waiting for auth, SSM, SSH or browser policy | Block selected navigation; show the actual pending layer and bounded timeout. Repeated clicks coalesce. |
| Transport ready, browser not verified | Do not label the Browser connected. Offer a scoped browser route check. |
| Browser route verified | Show logical profile and active target/user, last check time and tested host. This does not claim the user is signed in. |
| Remote DNS / TCP / TLS / HTTP error | Distinguish stages and suggest checking the selected target/resolver, reachability, certificate or app health respectively. An expected 302/401 proves an HTTP path, not an authenticated session. |
| Authentication required / disconnected / target changed | Preserve private blocking; direct the user to SSM Connect's existing auth/reconnect/target-review flow, not an ingress/public-DNS fix. |
| Policy, port, session or enterprise-setting conflict | Identify the conflicting owned resource without exposing tokens. Offer a safe new context or restoration, never kill/overwrite another owner. |

Readiness requires the resolved target to be running, SSM available, the mapped user/SSH path
authorized, native transport owned and healthy, policy applied to the actual browser session,
and an end-to-end browser check through that binding. Configured safe health paths should be
nonmutating; do not send credentials, replay login callbacks or infer readiness merely from
an open port, running EC2 state, PAC-file existence or a remote-only `/health` request.

On SSM/SSH drop, sleep/wake, expiry or app restart, immediately mark browser verification stale
and preserve blocking. Use the existing auth coordinator and bounded reconnect/backoff/cancel
behavior. Do not launch surprise sign-in windows or re-submit pending non-idempotent requests.
After re-establishment, revalidate identity, policy, remote DNS and browser path before **Verified**.
Handle WebSocket/SSE closures normally; the application decides whether/how to reconnect.

Retain logical profile/domain configuration across workstation replacement, but treat the new
instance/user/generation as a new binding. Wait for the existing replacement/readiness flow to
resolve a unique intended target, establish its authorized transport and satisfy dependencies.
Then create a new lease/context through the existing reviewed flow; drain old sockets and
invalidate old route/DNS proof. The old lease must continue to reject `targetChanged`.
Same-owner rolling lease renewal is **not** permission to adopt a replacement or another user.

The existing [editor lease and continuity requirements](./remote-vscode.spec.md#15-automatic-editor-lease-continuation-2026-10-16)
remain authoritative. This specification consumes their readiness/identity outcome; it does not
redesign rebuilding, bypass generation checks or promise unattended replacement already works.
Preserve unsaved editor buffers and remote code/server data. Never stop/reboot a workstation
or alter another user's sockets to recover browsing.

Stop/quit/upgrade must tear down only owned listeners/transports and invalidate their capabilities.
Browser authenticated data is not deleted. Explicit restore removes only app-owned integration
after checking for user edits and safe private-tab handoff; do not restore a global configuration
over another feature's changes. DCV, existing external Web Forwards and ordinary editor workflows
must retain their independent behavior.

## 9. Acceptance matrix

All cases below are **not executed** by this specification. A future implementation records
product/runtime versions, adapter, storage scope, profile binding, observations and result
(passed / failed / unsupported / not run) for each case. A source review or curl cannot replace
the required native Browser proof. Use approved test infrastructure and keep operational details
and authentication artifacts out of public evidence.

| ID | Case and required result |
|---|---|
| A01 | Establish the generalized split with synthetic fixtures: actual Browser navigation fails with `-105`, while the selected remote resolver answers the app/auth names and remote non-proxied `/health` returns 200. Separately measure local DNS; do not infer its exact OS result solely from the browser error. Capture Mac app/editor versions, selected profile, both domain entries, effective PAC and concurrent Web Forwards/Remote Access lifecycle without changing infrastructure. Classify the cause as configuration/lifecycle/integration/unknown from the evidence, not as a confirmed client bug in advance. Keep environment-specific inputs/results private. |
| A02 | On exact 1.140.0 and 1.142.0 test candidates, document preview enablement and non-global storage behavior; global scope must not be reported remotely routed. Record the actual installed Remote - SSH and engine versions. This is diagnostic evidence, not selective-feature acceptance. |
| A03 | With local private DNS unavailable, actual user-opened and agent-opened Browser pages reach both configured synthetic `app.private.example.test` and `auth.private.example.test` origins using valid HTTPS certificates and original URLs. Prove hostname-bearing remote CONNECT/SOCKS and remote resolution; a screenshot or 200 alone is insufficient. |
| A04 | Execute signed-out application -> private auth -> Entra/Okta federation -> MFA -> both private callback origins -> signed-in app, then logout and sign in again. Popups, cookie partitions, conditional access and public IdP local routing work without rewritten redirects or TLS exceptions. |
| A05 | Cold-cache private names never reach local OS DNS, DoH, prefetch or direct IPv4/IPv6 sockets. Controlled local answers pointing to a sentinel must not receive traffic; remote NXDOMAIN must not cause a local lookup/retry. Include unique subresource/redirect names. |
| A06 | Positive/negative matcher table covers exact hosts, subdomains, apex, case, IDNA, trailing dot, unrelated suffix lookalikes and malformed authorities. Private app/auth both match; unrelated/public hosts do not tunnel. |
| A07 | Public control URL and every public IdP hop use the local approved route, including required enterprise proxy policy. Prove different local/remote egress where permitted; do not infer route solely from page success. |
| A08 | Kill only the owned remote test tunnel: selected requests fail as proxy/blocked errors without local DNS/TCP fallback while public paths remain usable. Separately kill the owned broker: the affected session may be unavailable as disclosed, but unrelated public sessions remain usable. Repeat for startup races, app crash, SSM disconnect and preview proxy-reference release; no availability recovery may enable private direct access. |
| A09 | Missing/malformed/unavailable PAC, stale route fingerprint and rejected proxy settings never make selected requests direct. A prototype that cannot enforce this fails G1 rather than shipping a workaround. |
| A10 | WebSocket frames, SSE updates, fetch/XHR, workers/service workers, redirects, subframes, downloads and resumed downloads all retain policy. Exercise actual app live updates and auth popup/download process boundaries; detect unsupported UDP/QUIC/WebRTC escape paths. |
| A11 | Bad hostname/expired/untrusted certificate still fails; original SNI, Host/`:authority`, origin and private cookie boundaries remain intact. No bypass flags or newly installed trust roots. |
| A12 | Mac-local localhost callback remains local; explicitly opted remote-loopback service reaches the correct remote user's service. Cover `localhost`, IPv4/IPv6 loopback and engine implicit bypass rules; metadata/link-local access is not accidentally opened. |
| A13 | Existing listener, duplicate configured forward ports and two-profile contention produce actionable conflict without killing processes, reusing an unknown listener or changing routing to another target. Verify loopback-only bind and capability authentication. |
| A14 | Two profiles/accounts/remote Unix users resolve the same hostname differently: independent routing, cookies and sockets, or an explicit unsupported-concurrency refusal. No last-applied-proxy wins, shared agent-affinity crossover or other user's remote socket access. |
| A15 | A different local Unix user cannot consume the new protected routing capability; test the reused SOCKS backend as well as the broker. Any remaining exposure blocks a strict-isolation support claim. |
| A16 | Auth expiry, app relaunch, VS Code reload/relaunch, extension-host restart, sleep/wake and a new channel after EIC authorization expiry give accurate status and recover only through the current valid owner/lease. No false **Connected** or surprise authentication action. |
| A17 | Logical profile survives instance replacement, but the old lease/target/generation fails closed. No private request reaches the replacement until the reviewed readiness flow creates a new valid binding; DNS/pools are revalidated. Unsaved editor buffers remain. |
| A18 | Cancellation, repeated open clicks, shutdown, uninstall/restore and rollback remove only owned resources and preserve private blocking or complete the explicit tab shutdown handoff. User changes and unrelated browser/editor/DCV sessions remain intact. |
| A19 | Fault injection distinguishes remote DNS failure, TCP refusal/timeout, TLS error, HTTP health error, auth redirect and unsupported session/API. Status reports the failed layer, current binding and a concrete recovery action without secrets. |

## 10. Delivery phases and release gates

1. **Discovery:** capture the approved native environment/version matrix and effective browser
   session settings; reproduce A01; confirm the exact supported network control. No operational
   remediation or silent setup during discovery. Publish a capability decision, not a feature claim.
2. **Prototype:** in an explicitly approved isolated context, test documented preview routing
   first, then a supported selective surface if one exists. Complete G1, route/leak/failure/
   localhost/isolation tests and public IdP path evaluation. If no selective surface exists,
   stop with an upstream capability request and external-browser fallback; do not build on
   unsupported flags or private workbench calls.
3. **Implementation:** only after G1 passes, produce the implementation plan and adapter contract.
   Reuse native transport/policy and auth/lease ownership, add only necessary additive portable
   capability/schema changes, scoped consent/restore, status and generation-aware tests.
   Ordinary editor access and current Web Forwards remain backward compatible.
4. **Test:** unit-test matching/migration/identity/state transitions; adapter-test configuration
   precedence, readiness and teardown; execute the full native acceptance matrix, including
   human SSO/MFA, reconnection and replacement readiness in an approved fixture. Use existing
   tooling; do not label unrun combinations supported.
5. **Rollout:** opt-in, exact tested product/version/adapter allowlist, non-global isolated scope,
   initial small cohort, clear unsupported/version-upgrade state and external-browser fallback.
   Re-run capability checks after VS Code/engine/Remote - SSH upgrades. No silent network changes.
6. **Rollback:** block new private navigations, cancel/drain owned work, revoke capabilities,
   safely detach/close only the affected browser context, then restore only consented owned
   settings if unchanged. Preserve user browsing data and editor buffers. If the app cannot
   keep selected hosts blocked while detaching, keep the safe blocked state and explain the
   required user action; never roll back by enabling direct private access.

### Decisions still required

- **D1:** supported selective session proxy/PAC API, or upstream addition; the inspected preview
  setting alone does not meet this contract.
- **D2:** actual user/agent/shared-page session identity and safe ownership/isolation across
  profiles, windows, popups and local/remote Unix users.
- **D3:** enforceable no-direct/no-DNS-leak state during initialization, PAC errors, release,
  disconnect and restart; protected reuse of the native SOCKS endpoint.
- **D4:** public IdP/callback network and cookie policy for the real environment, plus exact
  tested protocol/download coverage and replacement-readiness integration.

Until these pass, the accurate deliverable is an evidence-grounded design and bounded prototype
work, not an assertion that enabling PAC or connecting Remote - SSH fixes the integrated browser.

## 11. External references and version policy

Upstream implementation links below are pinned to VS Code 1.142.0's immutable commit, except the
explicit 1.140.0 comparison. Product documentation and Chromium's general proxy guide are moving
references consulted on 2026-10-16; they are guidance, not runtime acceptance. Electron references
are pinned to the inspected 1.142.0 source engine version.

[vscode-browser]: https://code.visualstudio.com/docs/debugtest/integrated-browser
[vscode-main-thread]: https://github.com/microsoft/vscode/blob/d956e8a6ac5d904486557eea07e1d6bd62a4d36f/src/vs/workbench/api/browser/mainThreadBrowserTunnelProxy.ts
[vscode-ext-host]: https://github.com/microsoft/vscode/blob/d956e8a6ac5d904486557eea07e1d6bd62a4d36f/src/vs/workbench/api/node/extHostBrowserTunnelProxy.ts
[vscode-tunnel-proxy]: https://github.com/microsoft/vscode/blob/d956e8a6ac5d904486557eea07e1d6bd62a4d36f/src/vs/platform/tunnel/node/tunnelProxy.ts
[vscode-remote-server]: https://github.com/microsoft/vscode/blob/d956e8a6ac5d904486557eea07e1d6bd62a4d36f/src/vs/server/node/remoteExtensionHostAgentServer.ts
[vscode-session-remote]: https://github.com/microsoft/vscode/blob/d956e8a6ac5d904486557eea07e1d6bd62a4d36f/src/vs/platform/browserView/electron-main/browserSessionRemote.ts
[vscode-session]: https://github.com/microsoft/vscode/blob/d956e8a6ac5d904486557eea07e1d6bd62a4d36f/src/vs/platform/browserView/electron-main/browserSession.ts
[vscode-140]: https://github.com/microsoft/vscode/blob/07f806f999227108933c2e30515b26eecc1fda74/src/vs/platform/browserView/electron-main/browserSessionRemote.ts
[vscode-stable-api]: https://github.com/microsoft/vscode/blob/d956e8a6ac5d904486557eea07e1d6bd62a4d36f/src/vscode-dts/vscode.d.ts
[vscode-browser-api]: https://github.com/microsoft/vscode/blob/d956e8a6ac5d904486557eea07e1d6bd62a4d36f/src/vscode-dts/vscode.proposed.browser.d.ts
[vscode-remote-setting]: https://github.com/microsoft/vscode/blob/d956e8a6ac5d904486557eea07e1d6bd62a4d36f/src/vs/workbench/contrib/browserView/electron-browser/features/browserRemoteFeatures.ts
[vscode-storage-setting]: https://github.com/microsoft/vscode/blob/d956e8a6ac5d904486557eea07e1d6bd62a4d36f/src/vs/workbench/contrib/browserView/electron-browser/features/browserDataStorageFeatures.ts
[vscode-140-engine]: https://github.com/microsoft/vscode/blob/07f806f999227108933c2e30515b26eecc1fda74/.npmrc
[vscode-engine]: https://github.com/microsoft/vscode/blob/d956e8a6ac5d904486557eea07e1d6bd62a4d36f/.npmrc
[electron-session]: https://github.com/electron/electron/blob/v43.7.7/docs/api/session.md
[chromium-proxy]: https://chromium.googlesource.com/chromium/src/+/HEAD/net/docs/proxy.md

## 12. Consolidated Exact-Build Feasibility Check (2026-10-17)

Read-only local metadata identifies installed VS Code Stable 1.142.0, commit
`6d62b1d5dace93a33b3a6d3eca1317bd5e15bcb1`. The running Mac app remains v0.6.0; published
v0.6.1 has not been installed as part of this assessment. This is more specific than the
earlier source-pinned release comparison, not a capture of effective Browser routing settings.

The exact installed revision's
[proposed Browser API](https://github.com/microsoft/vscode/blob/6d62b1d5dace93a33b3a6d3eca1317bd5e15bcb1/src/vscode-dts/vscode.proposed.browser.d.ts)
still exposes tab/CDP control but no per-session proxy/PAC/resolver selection. Its
[remote session implementation](https://github.com/microsoft/vscode/blob/6d62b1d5dace93a33b3a6d3eca1317bd5e15bcb1/src/vs/platform/browserView/electron-main/browserSessionRemote.ts)
still applies a fixed session proxy, excludes global storage, documents shared-session
last-applied-proxy behavior, and resets to direct when the final proxy reference is released.
The stable API was checked for the corresponding Browser/session/proxy-control surface;
none was found.

Therefore D1/G1 is **not passed** for the selective, public-local and fail-closed product
contract. The documented all-remote preview is a separately scoped diagnostic option, not an
implementation of selective native Web Forwards. Do not ship an undocumented flag/private API
adapter or substitute an unused matcher/broker skeleton for a working Browser path.

The combined PR may implement independently valid app/target/forwarding continuity while this
capability remains explicitly unsupported. A change to all-remote preview routing or another
browser isolation/failure policy requires explicit owner acceptance and native evidence first.
No live Browser settings, proxy, DNS, tunnel, authentication or infrastructure state was changed
for this exact-build check.
