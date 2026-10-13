# SPECIFICATION: Managed browser bootstrap for web forwards

- **Status:** implemented preview, 2026-10-13; user requested implementation and end-to-end tests.
  Automated/local native evidence is recorded below. Human SSO/session-retention, fresh-user
  setup and final UX acceptance remain pending. No release/publication is implied.
- **Area:** web-forwards menu, profile settings, browser discovery/launch and browser-owned data.
- **Related:** [web-forwards.spec.md](./web-forwards.spec.md), especially WF-6, WF-9 and section 6.4;
  [ssm-connect.spec.md](./ssm-connect.spec.md), F-18 and the menu layout.
- **Gate:** preview build authorized by the user's request to see it working before judging it.
  Review of the built experience and the browser evidence are required before final acceptance.
  No commit, push or release is implied by preview authorization.
- **Accepted design decision (2026-10-13):** the user agreed to offering both existing-browser
  setup and isolated browser profiles. This approves both choices in the design, not a write to
  any real browser's settings or a claim that either implementation is complete.

## 1. Problem

Configuring a domain in SSM Connect currently creates a routing rule, not a browser configuration.
The user must copy a PAC URL and configure each browser separately. During testing an isolated
Chrome window was launched with proxy arguments outside the app; that made the feature appear
automatic even though Zen and other ordinary browser windows were still browsing directly.

The product must own this missing setup step. Users should configure their workstation/domain
once, choose Open Browser, and browse through the workstation without shell commands or manual
proxy settings. Browser identity-provider login remains the user's normal interactive login.

## 2. Goals and Non-Goals

### Goals

- One visible action connects web forwards as needed and opens a correctly routed browser.
- Offer Use My Browser with explicit one-time proxy setup, or Separate Browser with an isolated
  profile per workstation. No ordinary browser setting changes before scoped consent.
- Domain DNS resolution and network connections happen at the workstation for selected suffixes.
- Public sites, including public identity providers, remain direct unless explicitly configured.
- Repeated use retains the managed profile's normal login/session data without copying it from
  another browser profile or exposing it to SSM Connect.
- Existing-browser mode keeps that browser's current logins in place without reading or copying
  its authenticated session data, and provides an explicit safe restore action.
- Unsupported browsers, launch failures and required routing refreshes have explicit outcomes.
- PAC copy/reveal remains available for users who intentionally configure an ordinary browser.

### Non-Goals

- Modifying system proxy settings, VPNs or hosts files; silently modifying normal browser
  preferences, or changing ordinary browser settings outside a consented proxy-configuration scope.
- Installing browsers, extensions or certificates without a separate explicit user action.
- Routing every site through the workstation, adding a generic HTTP reverse proxy, or bypassing
  application permissions, TLS verification, corporate browser policies or identity-provider MFA.
- Adding an internal-site bookmark manager. Users can enter normal URLs in the managed browser.
- Reading browser history, cookies, credential databases, page contents or password fields.
- Changing DCV connection behavior or the existing local-forward transport.
- Windows automation in this macOS feature.

## 3. Proposed User Experience

### Profile Settings

Under Web Forwards, SOCKS proxy profiles gain an optional Browser picker. It lists installed,
verified adapters and an Automatic choice. A Browser Mode segmented control offers Use My Browser
and Separate Browser; the selection is stored per workstation profile alongside the browser.
Domain rows remain Add Domain / editable suffix / remove, as specified in WF-11.

Neither choice grants consent by itself. Use My Browser opens a setup confirmation naming the
exact browser/profile and any broader instance-wide scope before changing proxy settings. Separate
Browser creates an app-owned profile without modifying the ordinary one. Missing mode metadata in
legacy profiles prompts for the choice on first browser setup; it never opts into ordinary-profile
changes automatically. Automatic browser selection is restricted to verified adapters for the
selected mode, not merely adapters verified for isolated launch.

Automatic prefers the user's default browser only when a verified adapter exists for it; otherwise
it chooses an installed verified adapter in the order Chrome, Edge, Firefox, Zen. This is a
proposal, not a claim that all four adapters already work. A browser is not offered as automatic
or supported merely because its executable exists.

### Dropdown

- Open Browser is the primary SOCKS/browser action. It is available while web forwards are off
  when the profile is configured and a SOCKS port is enabled.
- When off, the action starts the existing web connection, waits for On and listener readiness,
  then opens the browser. It never starts DCV Viewer.
- While starting, show Opening Browser as disabled; repeated clicks do not create parallel
  connections, browser launches or managed profiles.
- When on, Open Browser opens/focuses the chosen existing browser after verified setup, or the
  isolated browser for that same workstation profile and configuration.
- The browser starts at about:blank with the address bar available. No service URL is inferred
  from a domain suffix, and no private environment URL is baked into the application.
- Existing Open local-forward actions continue working and keep their current semantics. They
  do not require the user to enable SOCKS or use a managed browser for loopback traffic.
- Copy PAC URL and Reveal PAC File move under an Advanced submenu. Manual setup remains opt-in.

### First Use and Browser Absence

Separate Browser uses a dedicated profile. First use therefore may require the user to sign in
again, even if their ordinary browser is already authenticated. The app does not import or copy
ordinary-browser cookies/passwords to avoid this step. Use My Browser retains its current logins
because it keeps using the original profile, not because SSM Connect reads authentication data.

If the selected browser is missing or its adapter is not verified, do not silently launch the
system default directly. Present a clear error with Choose Browser and the advanced manual
configuration option. Browser installation is not automatic.

### Use My Browser: Setup, Conflicts and Restore

1. Select the browser and, where needed, the exact browser profile. Read only the minimal proxy
  configuration needed to identify conflicts; do not scan cookies, history or unrelated preferences.
2. Explain which browser windows/profiles the verified mechanism affects. Some Chromium settings
  may be instance-wide rather than profile-local; disclose that broader effect or mark the mode
  unsupported. Do not promise isolation that the mechanism cannot provide.
3. Detect an existing manual proxy, PAC, proxy-controlling extension or managed policy. Do not
  silently replace or attempt to merge arbitrary PAC scripts. Prefer Separate Browser when a
  conflict exists. Enterprise-managed settings are not overridden.
4. Obtain explicit confirmation before installing selective routing in the normal profile. If a
  non-managed prior proxy configuration would be replaced, obtain a separate clear replacement
  confirmation and preserve it for restore. If that cannot be restored safely, refuse the change.
5. Preserve only the keys/values or extension-control state the app is authorized to alter, in a
  restricted app-owned journal. Do not back up the browser's full preference/credential database.
  Proxy URLs/settings may themselves contain sensitive identifiers or credentials: keep such
  journal data out of logs, diagnostics and repository artifacts, and never authenticate with it.
6. Show Restore Browser Settings in setup/Advanced after a successful owned change. Restore only
  if the current affected values still match the app's last installed values and ownership scope.
  If the user, a policy, an extension or another app changed them, do not overwrite those changes;
  explain the conflict and require a new decision.

With setup retained, matching domains keep using the local SOCKS endpoint even when SSM Connect
is not running; those sites fail closed while the tunnel is off. Nonmatching sites stay direct
for the installed configuration. This persistent effect is part of the setup confirmation. On
ordinary app/tunnel shutdown do not silently remove configuration or restore a prior proxy.

Use a supported live browser configuration API or explicitly approved extension where available.
If the only verified method requires closing the browser, obtain restart consent first and edit
only the authorized proxy scope after it is closed. Never force-kill the ordinary browser or race
a running browser's preference writer. Extension installation, if required, needs the user's
explicit browser-level approval and narrowly scoped proxy permissions; no hidden installation.

## 4. Browser Support Contract

### Engine Families and Shared Backends

Browser rendering engines are Blink (Chromium browsers), Gecko (Firefox-family browsers) and
WebKit (Safari). PAC/SOCKS behavior primarily comes from each browser family's networking and
configuration stack, not from its renderer alone.

Implement two shared browser-family backends: Chromium-family and Firefox-family. Product
descriptors supply bundle identity, executable discovery, supported versions and documented
launch quirks. Chrome/Edge share the Chromium backend; Firefox/Zen share the Firefox backend.
Other compatible products can reuse a backend after their descriptor and isolation/routing
checks pass; sharing an engine alone must not automatically mark an unknown fork supported.

For Separate Browser, keep data directories keyed by workstation UUID and product adapter ID even within one family.
Firefox and Zen must not share profile data, and Chrome and Edge must not share user-data
directories. For Use My Browser, keep ordinary data in place and modify only the approved proxy
scope through a verified mechanism. WebKit/Safari remains outside automated setup
unless a separate mechanism can meet its selected mode's isolation or consent/restore contract
without changing system proxy settings.

| Browser | Proposed isolated launch mechanism | Required evidence before support |
|---|---|---|
| Google Chrome | Chromium backend: dedicated user-data directory and PAC launch configuration; use direct executable or a verified macOS launch API rather than assuming normal-instance open requests apply new flags. | The existing manual Chrome mechanism is proven; the production adapter still needs the criteria below. |
| Microsoft Edge | Chromium backend with Edge's executable/version descriptor and its own user-data directory. | Verify flags, process ownership, policy behavior, reuse and selective routing on installed supported versions. |
| Firefox | Firefox backend: dedicated app-owned profile, app-owned proxy preferences, remote SOCKS DNS and an isolated-instance launch. | Verify selective PAC behavior, remote DNS, instance isolation and profile reuse. |
| Zen | Firefox backend with Zen's executable/version descriptor and its own dedicated profile. | Verify actual Zen behavior and any launch differences; ordinary-profile setup requires separate mode-specific verification and consent. |
| Safari / other browsers | No managed adapter in this scope. | Advanced manual setup only; never silently fall back to direct browsing. |

The shipping supported set is exactly the adapters that pass verification. If any proposed adapter
cannot meet isolation or routing requirements, mark it unsupported, report the gap against this
specification and return for a scope decision. Do not quietly reduce Zen support to Chrome-only.

Exact browser-version floors and launch arguments must be established from the adapter's official
documentation and executed tests before implementation is reported complete.

Support is a product-by-mode matrix. Isolated Chrome support does not establish existing-profile
Chrome setup, and neither establishes Zen support. Chromium existing-profile setup may need a
user-approved proxy extension; Firefox-family setup may use profile-scoped proxy preferences or
another verified API. A mechanism that requires global system proxy changes is not supported.
If an installed browser cannot safely provide one mode, show that mode as unavailable for it and
offer the other verified mode/manual setup; do not silently switch the user's chosen mode.

## 5. Requirements

| ID | Priority | Requirement |
|---|---|---|
| BB-1 | P0 | Open Browser starts web forwards when needed, waits for readiness and launches the selected verified adapter without starting DCV. |
| BB-2 | P0 | Offer both browser modes. Separate Browser uses a persistent isolated profile per workstation UUID/product adapter; Use My Browser targets only the explicitly selected, consented ordinary proxy scope. |
| BB-3 | P0 | Configure selective routing from the existing SOCKS port and proxySuffixes. Matching domains use workstation-side DNS and SOCKS; nonmatching sites remain direct. |
| BB-4 | P0 | Never change system networking, copy browser credentials, silently modify an ordinary profile or change it beyond explicit proxy-setup consent. Never force-terminate an ordinary browser. |
| BB-5 | P0 | Validate browser availability and all generated configuration before launch. Missing executables, conflicting/locked profiles and policy overrides are actionable errors, not direct-browser fallback. |
| BB-6 | P0 | Separate Browser reuses only a managed instance whose workstation UUID, adapter and routing fingerprint match. Use My Browser verifies its consented configuration/owner before reusing an ordinary instance. Singleton forwarding must not silently discard changed proxy options. |
| BB-7 | P0 | Apply routing changes only to the mode's owned/consented configuration, with verified refresh or confirmed restart. Never silently use stale rules or kill unrelated browser processes. |
| BB-8 | P0 | Matching domains fail closed while the web tunnel is down. PAC/configuration load failures must not silently switch them to DIRECT; adapters that cannot enforce this are not supported. |
| BB-9 | P0 | Never disable certificate validation or weaken browser authentication. Explain certificate/policy failures distinctly from DNS/tunnel failures. |
| BB-10 | P1 | Retain the managed profile's own sessions across normal browser closure and app reconnect/relaunch. Do not treat persistent browser data as disposable SSH-key material. |
| BB-11 | P1 | Make browser/mode selection optional and backwards-compatible in stored profiles; legacy profiles still decode and never consent to ordinary-profile changes implicitly. |
| BB-12 | P1 | Keep manual PAC actions under Advanced, plus a clear indication that they configure ordinary browsers separately from Open Browser. |
| BB-13 | P1 | Surface launch status/errors independently of tunnel state: a browser launch failure must not destroy a healthy web or DCV connection. |
| BB-14 | P0 | Existing-browser setup requires scoped consent, prior-proxy/policy conflict detection and a minimal restricted restore journal. Restore must not overwrite later user/policy/extension changes. |
| BB-15 | P0 | Retained existing-browser setup survives ordinary tunnel/app shutdown; explain that matching sites fail closed while disconnected. A normal profile's proxy scope has one active workstation owner; switching workstations requires explicit checked Apply, not last-writer-wins. |

## 6. Routing Changes, Reuse and Lifecycle

The routing fingerprint includes workstation UUID, browser adapter, SOCKS endpoint and normalized
suffix list. Browser handles are app-owned records bound to that fingerprint; executable names
alone are never sufficient proof of ownership.

The isolated-instance rules below apply to Separate Browser. In Use My Browser, the fingerprint
also includes the consented browser/profile scope and ownership journal. Multiple workstation
profiles cannot simultaneously control the same ordinary browser proxy scope: selecting another
workstation stages an explicit Apply with conflict/restart checks. It does not overwrite routing
when merely switching the active workstation in Settings. Sessions/tabs remain the browser's own.
Closing an ordinary browser does not disconnect web/DCV. Restore is explicit and conditional as
specified in section 3; app exit leaves the consented routing in place and retains its artifacts.

- Same fingerprint, same managed profile: reuse/focus the instance using the adapter's verified
  mechanism. Do not create new temporary profiles on every click.
- Different workstation profiles: never share browser data directories or running instances,
  even when both use the same browser application.
- Tunnel reconnect with unchanged local routing: retain the browser profile and instance. No
  browser restart is required solely because SSH/SSM reconnects behind the same local endpoint.
- Saved suffix/SOCKS changes: the app must first apply the corresponding active web configuration.
  Where applying it interrupts an active tunnel, the user receives one explicit Apply Changes
  action rather than being required to remember a separate stop/start sequence.
- Stage the tunnel/browser routing change and obtain any required restart confirmation before
  replacing the active configuration. Cancelling keeps the current tunnel and browser routing
  intact; the saved configuration remains pending rather than partially applied.
- If the adapter can verifiably refresh PAC routing in place, use that mechanism. Otherwise show
  Restart Browser before closing the managed instance, because tabs or forms may contain unsaved
  work. Do not force-kill it, and do not silently ignore a cancelled restart.
- During pending refresh, the app distinguishes the currently applied routing from the new saved
  configuration. Open Browser must not claim that the new domain is available until it is applied.
- Browser exit does not disconnect the workstation, DCV or web tunnel. Browser restart reuses its
  dedicated data directory and does not trigger another SSH connection if the existing one is ready.
- Turning web forwards off or quitting SSM Connect keeps the browser's selective proxy rules;
  internal pages fail closed and public pages remain direct. The browser is not automatically killed.
- Retain the PAC/configuration artifacts required by an already running managed browser after app
  exit. Removing those files must not cause the browser to fall back to direct routing.
- Profile deletion does not silently delete managed browser data or close its windows. Any future
  reset/delete-browser-data action needs separate confirmation; that destructive feature is not
  included here.

## 7. Security and Data Boundaries

Store managed directories under the app's Application Support tree, for example
`Browsers/<profile-uuid>/<adapter-id>/`, creating app-owned parent directories as 0700. Let the
browser manage its own internal file permissions rather than recursively changing its files.
App-written routing/configuration files use 0600 and atomic writes.

Browser session data may contain authenticated sessions. SSM Connect never parses it, logs it, syncs it,
commits it, or deletes it as part of tunnel teardown. Other users' browser profiles are out of
scope even when they belong to the same browser application. Existing-browser setup may read/write
only its explicitly consented proxy configuration; that narrow exception is not permission to
inspect broader browser data. Setup and restore journals use 0600 files and 0700 directories,
contain no copied cookie/password databases, and are excluded from diagnostics.

Use structured launch arguments, not a shell-built command. User strings cannot inject flags,
preferences or JavaScript into PAC generation. Reuse existing suffix validation and the PAC
generator; do not introduce a separate list of hardcoded environment domains.

Do not pass AWS credentials, SSM session responses, private SSH keys, browser cookies or login
tokens to browser launch arguments or logs. Public application URLs are entered by the user;
identity-provider credentials and MFA are handled only in the browser.

Managed launch must not open a remote-debugging port, disable the browser sandbox, ignore TLS
errors or override enterprise policies. Managed profiles are a convenience boundary, not a
guarantee that SSO policies or browser-managed certificate requirements disappear.

## 8. Acceptance Criteria and Verification

| ID | Given / When | Required result and evidence |
|---|---|---|
| AC-B1 | Configured SOCKS profile, web forwards off; Open Browser clicked twice | Mocked/native tests show one connection and one launch after readiness; no DCV launch. |
| AC-B2 | Existing stored profile without browser settings | Decode unchanged; automatic selection chooses only installed verified adapters or reports none. |
| AC-B3 | Normal browser already running; Separate Browser selected | Open Browser creates/reuses the dedicated profile, leaves the normal process/preferences untouched, and does not import its sessions. |
| AC-B4 | Managed browser navigates to a configured domain whose DNS is unavailable on the Mac but available on the workstation | Request succeeds with workstation-side DNS and valid TLS; no hosts/system-DNS changes. Test each supported adapter. |
| AC-B5 | Internal app and public identity provider/public site | Internal domain uses SOCKS, public destinations stay direct, and user-confirmed SSO completes without credentials being read by the agent/app. |
| AC-B6 | Tunnel stopped while managed browser remains open | Internal request fails with a proxy error, public request still works; app exit/PAC load failure cannot silently leak internal traffic to DIRECT. |
| AC-B7 | Added domain or changed SOCKS port; existing managed instance running | New rules take effect through verified refresh or confirmed managed-instance restart. Cancel keeps the old rules explicitly pending; no ordinary browser is stopped. |
| AC-B8 | Open Browser repeated, browser closed/reopened, or app relaunched | Separate Browser reuses its workstation/adapter directory; Use My Browser retains the selected ordinary profile and checked proxy ownership. Retained-session behavior is human-confirmed without examining cookies. |
| AC-B9 | Two different workstation profiles | Separate Browser has separate data directories/ownership records. Use My Browser cannot assign both profiles to the same proxy scope or change its owner without explicit checked Apply. |
| AC-B10 | Selected browser missing, locked profile, launch failure or enterprise policy override | Actionable error; no insecure/direct fallback; existing web/DCV handles stay active. |
| AC-B11 | Certificate chain not trusted by the selected browser | Normal certificate failure remains visible; no ignore-certificate or sandbox-disabling flags. |
| AC-B12 | Browser bootstrap tested on a fresh Mac/user profile with an installed supported browser | App + AWS SSO suffice for routing; no shell scripts, manual PAC preferences, global proxy changes or pre-existing browser authentication are needed. |
| AC-B13 | Use My Browser selected; setup cancelled | No browser preference/configuration writes, restart or routing replacement occur; selecting the mode alone is not consent. |
| AC-B14 | Existing proxy/PAC/extension or managed policy detected | No silent replacement or generic PAC merge; verified replaceable configuration requires separate confirmation and minimal restore capture; managed policy stays untouched. |
| AC-B15 | Existing browser/profile setup confirmed | Only the approved proxy scope changes; its current login remains usable by human confirmation, with no cookie/history/password reads or data import. Selective DNS/routing, TLS and tunnel-off behavior pass in that mode. |
| AC-B16 | Restore requested after a successful owned setup | Prior affected values/control state are restored only when current values still match the app's installed state; unrelated preferences remain unchanged. |
| AC-B17 | User/policy/extension changed proxy settings after setup | Restore/update detects changed ownership, leaves the newer values untouched and presents a conflict rather than overwriting them. |
| AC-B18 | Existing browser is running and verified setup needs restart | Cancel preserves all settings/tabs; confirmation requests a graceful close and writes only after closure; failure never force-kills the browser. |

Unit tests cover discovery/selection, legacy decoding, pure argument/preferences construction,
fingerprint/reuse decisions, failure paths and app-owned data boundaries. Mocked orchestration
tests cover connection readiness and independence from DCV. Each declared browser adapter needs
executed native/end-to-end tests for DNS, selective routing, fail-closed behavior, SSO, updates,
normal-instance isolation and reuse. A green unit suite alone cannot establish browser support.

## 9. Proposed Implementation Boundaries

- Models/ConnectionProfile: optional browser preference within the web-forwards configuration.
- Existing-profile setup: a mode-specific consent/configuration/restore boundary separate from
  isolated launch, with injectable proxy-only readers/writers, conflict detection and ownership
  journal. No unrestricted browser preference or credential database access.
- Browser discovery/launch adapters: separate from SSH/EIC and DCV services, with injectable
  discovery, launch and managed-data-store interfaces following the existing DCV launch pattern.
  Share configuration/argument logic in Chromium and Firefox-family backends; keep product
  identification/version quirks in small descriptors rather than duplicating the implementation.
- WebForwardsStateMachine: browser-open orchestration after the existing ready web handle;
  browser status is not added to DCV's eight ConnectionState cases.
- MenuContentView: Open Browser, launch status/error handling and Advanced PAC actions.
- ProfileEditorView: installed verified browser picker next to existing SOCKS/domain settings.
- Existing SSMConnectKit test directories: focused unit/orchestration tests; native verification
  uses isolated preview preferences so active users' profiles are not changed.

The authorized implementation uses inline PAC configuration (no PAC-fetch dependency), persistent
per-workstation/product directories, recorded native PID/launch-date/routing identity, and
closed-profile Zen proxy writes protected by Firefox's profile lock. Routing refresh requires
closing the routed browser, then explicitly applying changes. The app never closes normal or
managed browser windows automatically. Existing-profile conflicts are refused, not replaced.

## 10. Accepted Choice and Remaining Decisions

- Accepted on 2026-10-13: offer Use My Browser and Separate Browser. Default first setup asks the
  user to choose; ordinary proxy changes still require explicit scoped confirmation at execution.
- Review the built mode-choice/consent/restore flow, including the separate first-use SSO login
  for isolated profiles and persistent routing/tunnel-off behavior for existing profiles.
- Accept the proposed supported-browser set and the rule that unverified adapters are not offered.
- Accept about:blank/address-bar navigation rather than a bookmark manager or inferred host URLs.
- Accept confirmation before any required browser restart that could lose unsaved work.
- Accept browser-by-mode support only where evidence establishes safe configuration, isolation
  or consented ownership, conflict behavior and restore; ordinary windows change only in the
  selected existing-browser proxy scope after confirmation.

## 11. Evidence Status

### Implemented Preview Matrix

| Product/version | Separate Browser | Use My Browser |
|---|---|---|
| Chrome 156.0.8078.12 | Native launch/isolation/reuse and real routing/outage tests passed. | Unavailable; an explicitly approved proxy extension is not implemented. |
| Zen 1.23.1b (Gecko 157.0.1) | Native launch/isolation/reuse and real routing/outage tests passed. | Closed-profile setup, real routing/outage and conditional restore passed on a disposable surrogate profile. Real-user login retention remains human verification. |
| Edge, Firefox, Safari, other versions | Unavailable until mode-specific verification. | Unavailable. |

Tests established Zen's `--new-instance --profile` launch flags from the installed executable's
`--help`. Chromium SOCKS5 hostname resolution is documented in
<https://chromium.googlesource.com/chromium/src/+/HEAD/net/docs/proxy.md>.
Gecko's SOCKS5 remote-DNS default and proxy preferences were checked against Mozilla's
`StaticPrefList.yaml`/`all.js` and executed against installed Zen. Foundation's default JSON slash
escaping is incompatible with Firefox preference strings; the generator disables slash escaping.
When Zen omits its true SOCKS5 remote-DNS default from prefs.js, verification uses that known
default. Unknown versions are deliberately not enabled by executable presence alone.

### Executed Checks

- Full direct Swift suite: 186 tests / 30 suites passed. Optional native/browser tests are
  opt-in and executed separately below.
- `node scripts/test-browser-bootstrap.mjs`: real installed Chrome and Zen; three product/mode
  scopes passed hostname-based SOCKS5 DNS, selective direct routing and fail-closed outage.
  The fixture hostname has no Mac DNS; a directly resolvable `outage.localtest.me` hostname
  detects internal DIRECT leakage after SOCKS stops. Public loopback requests still pass.
- Disposable Zen existing-profile setup/restore preserves an unrelated preference; update
  retains the original restore baseline. Unit checks cover cancelled consent, other-workstation
  ownership, running-browser refusal, proxy extension conflicts, later proxy edits and symlinks.
- `BROWSER_NATIVE_E2E=1 ... --filter realNativeOpenAndReuse`: macOS launch API creates new
  Chrome/Zen PIDs, repeated Open focuses the recorded PID, and pre-existing browser PIDs stay alive.
- `BROWSER_PREVIEW_E2E=1 ... --filter previewMenuOpenFromOff`: isolated preview preferences,
  native menu click from Off, actual EIC/SSM/SSH SOCKS readiness and recorded Chrome launch passed.
  No DCV listener was created by the preview. Only workstation configuration was cloned.
- The actual internal HTTPS endpoint through the preview's SSH listener returned HTTP 200,
  TLS verify result 0. No certificate exceptions, remote debugging ports or sandbox bypasses.
- Native preview Debug build and deep/strict signature checks passed; lockfile unchanged.

| Criteria | Evidence / Remaining Gate |
|---|---|
| AC-B1, B2, B9, B13, B14, B16, B17 | Automated orchestration/ownership/legacy/conflict/restore checks passed. |
| AC-B3 | Native Chrome/Zen separate-instance PID isolation/reuse passed; no normal-profile writes/imports. |
| AC-B4 | Real browser remote-DNS fixture passed for all three scopes; real workstation TLS endpoint passed through preview SSH. The combined private-site browser navigation still needs human confirmation. |
| AC-B5, B8, B15 | Automated routing/profile persistence passed; new-flow SSO and authenticated-session retention need human confirmation without inspecting credentials. |
| AC-B6 | Real browser cold-start routing/outage tests passed, including a directly reachable leak trap and retained inline PAC; same-window authenticated outage remains a human check. |
| AC-B7 | Unit pending/apply/cancel and closed-profile update checks passed. Native edited-domain/port UX confirmation remains pending. |
| AC-B10, B11, B18 | Missing/version/policy/conflict/lock refusal and safe arguments implemented. Normal close is user-driven, not force termination. Real enterprise policy/invalid-certificate environment and native consent dialogs remain additional checks. |
| AC-B12 | Fresh Mac/user verification not performed. |

No ordinary user browser profile was configured by this verification. Existing-mode mutations
were restricted to disposable test profiles. The built preview and its app-owned Chrome profile
are left open for human evaluation. The older working-day observer recorded missing web
listeners beginning 2026-10-13 03:42 UTC, before bootstrap implementation, and does not establish
a working-day pass. The preview's web transport is independently verified; no original-session
restart was performed.