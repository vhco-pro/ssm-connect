# SPECIFICATION: Web forwards (internal web UIs in the local browser, over the SSM tunnel)

- **Status:** shipped in macOS v0.5.0 on 2026-10-15; native UI and live transport tested 2026-10-13.
  Automated and native evidence is recorded below. Interactive browser SSO was user-confirmed
  on 2026-10-13; the deferred working-day/DCV observation remains unverified, not a release claim. The shell script
  ([`scripts/web-forwards.sh`](../../scripts/web-forwards.sh)) remains the reference mechanism.
- **Area:** new tunnel type next to the DCV port-forward (F-09). Touches `ConnectionProfile`,
  `SSMProviding`/`SSMService`, the `Tunnel/` layer, the menu and the profile editor.
- **Related:** [`ssm-connect.spec.md`](./ssm-connect.spec.md) (F-09, F-13, F-18, ADR-1, ADR-5),
  [`cross-platform-client.spec.md`](./cross-platform-client.spec.md) (Windows parity comes later).

## 0. Start here (handover)

This spec was written on the workstation side, where the mechanism was built and measured. It is
handed to an agent on the Mac because the app can only be built and run there. Do the two parts in
order.

On 2026-10-12 the user explicitly authorized Part B before the working-day/DCV observation,
deferring that observation and manual testing of the built feature until after implementation.
Those checks remain pending, not passed.

**Part A: prove it from this Mac with the script. No code changes.**

1. Ask the user for their settings and put them in `~/.config/web-forwards/env` (the header of
   `scripts/web-forwards.sh` lists the variables). They are environment-specific and deliberately
   not in this public repository.
2. `scripts/web-forwards.sh up`, then `status`. Record cold connect time and per-request times.
3. Point a browser at the PAC file (`scripts/web-forwards.sh pac`, see section 6.4) and open one
   internal UI that logs in through the identity provider. Record whether the login completes from
   this network. That is the one result the workstation could not produce.
4. Open the local forward in the browser and click through a page that uses websockets.
5. Leave the tunnel up for a working day next to a normal DCV session. Record whether it survives.
6. Write the results into section 3.2. If a step fails, stop and report it before Part B: a
   failure here changes the design, not just the numbers.

**Part B: build it into the app.** Write `docs/plans/web-forwards.plan.md` in the format of the
existing plans, then implement the requirements in section 4. `make test` must stay green. The
script stays in the repository as the reference for behaviour.

## 1. Overview and problem

SSM Connect gets a user onto a remote desktop. A lot of what people then do on that desktop is use
web UIs that are only reachable from inside the VPC: a GitOps console, a Kubernetes dashboard, an
internal portal. Used through DCV, every click is a video frame encoded on the host and sent down
the tunnel, so those UIs feel slow.

The app already holds everything needed to do better: an authenticated AWS session and a way to
open SSM sessions to the host. This feature adds a second kind of tunnel that carries HTTP instead
of pixels, so internal web UIs render in the browser on the user's own machine.

## 2. Goals and non-goals

**Goals**

- Internal web UIs open in the local browser at their real URLs, single sign-on included.
- Web apps that listen only on the host's loopback (for example a Kubernetes dashboard that uses
  the host's kubeconfig) open in the local browser too.
- No per-client setup on the host. A fresh Mac with only the app and an SSO login can connect.
- Usable without launching DCV Viewer, and next to a running DCV session.
- Adding another internal host or another local forward is a profile edit.

**Non-goals**

- Replacing the DCV tunnel or changing its behaviour.
- Installing or managing the web apps on the host. Section 6.5 documents one example.
- Routing all local browsing through the host.
- Changing system-wide proxy settings on the user's behalf.
- Windows. It follows the cross-platform spec once the macOS behaviour is settled.

## 3. Evidence

### 3.1 Proven on the host side (2026-10-10 to 2026-10-12)

The client in these runs was a Linux host inside the same network as the target, running the
script and a headless Chromium. The target was a multi-user Amazon Linux 2023 host with no inbound
security group rules.

| Check | Result |
|---|---|
| `AWS-StartSSHSession` to the host, key pushed through EC2 Instance Connect, empty `authorized_keys` | `sshd` accepted the key |
| Cold `up` (lookup, key push, session, SSH) | about 4.5 s |
| Request to an internal HTTPS app through SOCKS5 over SSM | 0.09 to 0.20 s |
| Request to a loopback web app on the host through a local forward | about 0.06 s |
| Browser with the PAC file: internal app at its real hostname, certificate valid | Login page in about 3 s cold |
| "Log in with SSO" on that app | Redirected to the identity provider, which the browser fetched directly, sign-in form shown |
| Websockets through the local forward | A dashboard opened its watch sockets and filled its tables |
| Tunnel killed | Internal hosts fail with a proxy error; everything else still loads |
| Forwarded connections on the host | Arrive as the SSH user's uid, not root |
| A plain `AWS-StartPortForwardingSession` to a loopback port that admits only the owner's uid | Refused. It connects on the host as the SSM agent, not as the user. |

### 3.2 To be measured from the Mac (Part A)

Mac preflight on 2026-10-12: AWS CLI, Session Manager plugin, SSH and Swift/Xcode
tools are present. The supplied settings were saved outside the repository with
restricted permissions, and PAC generation passed. The configured AWS profile
matches the requested account and role, and AWS authentication now succeeds.
The first connection attempt failed with `TargetNotConnected` after 47.05 s.
Read-only checks subsequently showed EC2 running with both health checks OK and
SSM Online; a later attempt connected successfully. The tunnel was left running,
and an isolated Chrome profile was opened with the generated PAC for the user's
interactive internal-app login. No system proxy settings were changed.
The user deferred the working-day/DCV coexistence check on 2026-10-12 and authorized Part B.

| Check | Result |
|---|---|
| Cold `up` from a network outside the VPC | Successful session startup: 3.75 s, after the initial failure. Local key already existed from the earlier attempt; network location was not independently verified. |
| Per-request time, SOCKS and local forward | Three samples, all HTTP 200. SOCKS: 0.543 / 0.409 / 0.583 s. Local: 0.145 / 0.286 / 0.276 s. A later health check also returned HTTP 200: SOCKS 0.375 s, local 0.122 s. |
| SSO login to an internal app completes from this network | Passed, user-confirmed on 2026-10-12: the user completed Okta login in the PAC-configured Chrome window. The agent verified internal HTTPS with valid TLS and the identity-provider redirect, but did not inspect the authenticated session or handle credentials. |
| Websocket page through the local forward | Passed in real Chrome at `http://127.0.0.1:4466`: cluster metrics populated and a read-only namespace watch with `resourceVersion=0` received an 840-byte frame. No CORS errors or failed requests were observed. The earlier shared-browser hostname mismatch was not reproduced in real Chrome; no host configuration changes were required. |
| Tunnel survives a working day next to a DCV session | Initially deferred until after implementation; app-owned web forwards are now under observation alongside real DCV (section 3.5). A full working-day result is not yet available. |

Additional Mac checks on 2026-10-12:

| Check | Result |
|---|---|
| Repeated `up` | Reports `already up`; does not replace the active connection. |
| Listener addresses | Both local listeners verified as IPv4 `127.0.0.1`, not wildcard or IPv6 listeners. |
| PAC routing with tunnel up | Internal HTTPS and public HTTPS both returned HTTP 200 in isolated Chrome, without disabling TLS verification. |
| PAC routing with tunnel down | Internal HTTPS failed with `ERR_PROXY_CONNECTION_FAILED`; public HTTPS still returned HTTP 200 in a separate tab. This verifies fail-closed internal routing and direct public routing. |
| Stop and reconnect | Successful; measured reconnect 5.21 s. Subsequent SOCKS and local requests returned HTTP 200. Tunnel restored after outage tests. |
| Existing app regression suite | `make test` passed: 151 tests in 26 suites on Swift 6.4 / Xcode 27. Existing concurrency warnings were emitted; no source changes were made. These are existing app tests, not tests of the unimplemented web-forwards feature. |
| Existing macOS app build | Debug Xcode build completed with `-skipPackagePluginValidation -skipPackageUpdates` after cancelling a stalled dependency fetch. App executable, embedded plugin version and plist verified. CoreDevice/CoreSimulator version-mismatch and existing concurrency warnings were emitted. Xcode resolved four newer transitive dependency pins; those test-generated lockfile changes were restored to the branch's original contents. The produced artifact therefore does not establish a build with exactly the original transitive pins. No app source changes or app launch. |
| Bundled plugin invocation | Package and binary checksums passed through `scripts/fetch-plugin.sh`; binary reports `1.2.814.0`. A live isolated SSM/SSH tunnel used `AWS_SSM_START_SESSION_RESPONSE` as argument 1, region, `StartSession`, empty profile, and request JSON, with no endpoint argument. Connected in 3.74 s; internal HTTPS returned HTTP 200 in 0.248 s. The wrapper rejected non-environment response arguments. Probe tunnel stopped and private key removed; main tunnel remained active. |

### 3.3 App implementation verification

`make test` passed with 165 tests in 28 suites. The native arm64 Debug app built successfully
with package updates and automatic package resolution disabled. Its executable, plist,
code signature, embedded plugin version (`1.2.814.0`) and web-forward symbols in the Debug
dylib were verified. The tracked dependency lockfile is unchanged. Existing toolchain and
concurrency warnings remain; no Xcode installation or system settings were changed.

| Criterion | Executed evidence |
|---|---|
| AC-1 | ConnectionProfileCodableTests decodes a stored legacy profile with the new block absent; default and explicit-null SOCKS configurations also round-trip. |
| AC-2 | SSHTunnelTests verifies the pure argument builder, loopback SOCKS/local forwards and ProxyCommand; a spawned-process test verifies that the token is only in the environment. |
| AC-3 | WebForwardsStateMachineTests verifies key generation, key push, SSH session start and SSH spawn in order, plus the actionable permission error and mapped-user fallback. |
| AC-4 | A mocked web connection reaches on with no DCV launch; a separate DCV connection is then connected/disconnected while the SSH handle remains active. |
| AC-5 | An unexpected SSH exit pushes a different key and respawns; user stop cleans up without reconnecting. |
| AC-6 | PAC suffix branches contain SOCKS5 and no DIRECT fallback. |
| AC-7 | Partially verified in the built app (sections 3.4 and 3.5), including user-confirmed browser SSO through the app PAC. A fresh-Mac-only-app setup and the exact no-DCV-at-any-point sequence remain unverified. |

Additional executed tests cover conflicting ports, invalid ports/suffixes/SSH inputs, real
local key generation with a 0700 directory and cleanup, and both independent quit callbacks.
The working-day/DCV observation is running (section 3.5), not complete. No changes were committed or published.

### 3.4 Native app and live transport checks (2026-10-13)

After the user enabled Accessibility access, the built Debug app was exercised through its
actual Settings and menu controls. Only the web-forward block of the matching active profile
was edited; other profile fields and the other saved profile were left alone. No system proxy
settings or remote application configuration were changed.

| Check | Result |
|---|---|
| Native editor | Enabled the block, entered proxy/local-forward settings, and saved. A deliberate duplicate SOCKS/local port disabled Save and showed the uniqueness error; correcting it enabled Save. Persisted values matched the private configuration. |
| Live profile refresh | Found and fixed a cached-menu bug: onAppear alone did not pick up saved profile edits. The menu now explicitly observes active-profile and settings changes. A saved local-forward name change appeared without restarting the app. Focused regression: 15 tests in 3 suites passed. |
| Independent connection | Native Turn On Web Forwards reached On with the desktop still Disconnected and no DCV Viewer process. Real EC2 Instance Connect and SSH-over-SSM were used, not mocks or the reference script. |
| HTTP and bindings | Internal HTTPS through the app SOCKS proxy returned HTTP 200 in 0.195 s; the dashboard forward returned HTTP 200 in 0.110 s. Both listeners were verified as IPv4 127.0.0.1 and owned by the app's SSH child. |
| Local-forward host policy | The dashboard rejected a temporary alternate local port with invalid Host header. The same forward returned 200 with its expected Host header; using the expected local port made ordinary browser requests work. No host policy was changed. |
| Native Open action | Invoked the configured dashboard Open item. The dashboard rendered populated CPU/memory panels in the shared browser while the app owned the listener; the read-only metrics endpoint returned a NodeMetricsList with three records. |
| PAC controls | Copy PAC URL produced the actual app PAC file, with SOCKS-only internal suffix branches. Reveal PAC File opened its Application Support folder in Finder. |
| Real Chrome with app PAC | Internal HTTPS, public HTTPS and the dashboard all returned 200. A read-only namespace watch with resourceVersion=0 received an 840-byte websocket frame. The probe recorded no browser console errors, but an immediate metrics-text assertion did not pass. |
| Browser rendering caveat | A separate cold deep-link metrics assertion timed out. The normal home-page-to-cluster workflow subsequently displayed CPU and memory in real Chrome on the restored reference tunnel. Shared-browser API/CRD warnings were observed; no changes were made to that separate application. |
| PAC with app off | Internal HTTPS failed with ERR_PROXY_CONNECTION_FAILED; public HTTPS returned 200 in a separate Chrome tab. |
| Stop and key cleanup | Native Turn Off stopped the app listener. The temporary key directory was mode 0700 while connected; no app key directories remained after stop. |
| Reference tunnel preservation | The reference SSH master and SOCKS listener remained running. Its dashboard listener was temporarily handed to the app for the expected Host header, then restored on the same master; dashboard HTTP 200 verified after restoration. |

The follow-up Debug build returned exit 0 and its new refresh method and bundle signature were
verified. Existing toolchain/concurrency warnings remained. At that checkpoint the app test
connection was stopped and the reference tunnel restored. Subsequent browser SSO confirmation
and ongoing DCV coexistence are recorded in section 3.5, separately from those initial checks.

### 3.5 Live DCV independence and ongoing observation (2026-10-13)

The built app's normal DCV action reached Connected while web forwards remained On. DCV Viewer
had seven established connections to the local desktop tunnel, and the dashboard still returned
HTTP 200. Native Disconnect then removed only the DCV connection: the dashboard and SOCKS HTTPS
both continued returning 200. DCV was reconnected for the stability observation.

The read-only `scripts/observe-web-forwards.mjs` helper records one sample per minute outside
the repository, in `~/.web-forwards/observations/` (0700 directory, 0600 log). It checks SOCKS
and local HTTP status, whether the SOCKS listener's SSH parent is SSM Connect, and established
DCV Viewer streams. It records sleep/coverage gaps and never infers an uninterrupted working day
from elapsed wall time. No URLs, instance identifiers, usernames, cookies or tokens are written
to its sample log.

At the updated checkpoint, twelve samples over eleven minutes were healthy: both HTTP targets were
200, app-owned SSH was verified, seven Viewer streams remained established, and no coverage gaps
were recorded. This is a successful short coexistence check, **not a completed working-day test**.
The observer was left running with both app connections active. The reference SSH master and
its separate SOCKS listener remain alive; its dashboard listener is temporarily handed to the app.
When ending the app test, stop app web forwards before restoring the reference local listener.

An isolated Chrome profile was launched with the app PAC for interactive identity-provider login.
On 2026-10-13 the user confirmed completion: "done sso logged in". This is a user-confirmed pass
for browser SSO through the app PAC, not an agent-inspected authenticated session. No credential
fields, cookies or tokens were read. The fresh-Mac-only-app setup, exact no-DCV-at-any-point
sequence for AC-7 and completed working-day observation remain outstanding.

Later, during isolated About UI verification, the observer first reported zero DCV Viewer
streams at elapsed 3661 seconds. SOCKS and local HTTP remained 200 and SSH ownership remained
the live app's; no coverage gap was recorded. The native app still reported desktop Connected
and web forwards On, and Viewer remained running. Its connection-status message was not exposed
through Accessibility, so the reason for the stream loss is not established. The live app and
its binary were not restarted or overwritten for the UI preview. This deviation is retained in
the private observation log; it must not be reported as a clean working-day coexistence pass.

## 4. Functional requirements

| ID | Priority | Requirement | Notes |
|----|----------|-------------|-------|
| WF-1 | P0 | **Profile carries an optional web-forwards block.** `enabled`, `sshUser` (optional), `socksPort` (default 1080, optional), `proxySuffixes` (list of domain suffixes), `localForwards` (list of `name`, `localPort`, `remoteHost`, `remotePort`, optional `openPath`). | All new fields optional so stored profiles keep decoding, the same way `connectMode` and `agentRemotePort` were added. |
| WF-2 | P0 | **One SSH connection inside one SSM session.** `SSM.StartSession` with document `AWS-StartSSHSession` and `portNumber=["22"]`, handed to the bundled `session-manager-plugin` acting as the `ProxyCommand` of `/usr/bin/ssh`. | The existing DCV tunnel keeps using `AWS-StartPortForwardingSession`, untouched. |
| WF-3 | P0 | **Per-connect key through EC2 Instance Connect.** Generate an ed25519 key pair for the connection, call `SendSSHPublicKey` for the instance and OS user, then start SSH within the key's 60 second validity. Nothing is written on the host. | Needs `ec2-instance-connect:SendSSHPublicKey` in addition to the permissions the app uses today. |
| WF-4 | P0 | **SOCKS5 and local forwards hang off that connection.** `-D 127.0.0.1:<socksPort>` when a SOCKS port is set, one `-L 127.0.0.1:<localPort>:<remoteHost>:<remotePort>` per local forward. | Bind `127.0.0.1` explicitly, never `localhost` (see the IPv6 bug spec). |
| WF-5 | P0 | **OS user defaults to the mapped identity.** When `sshUser` is empty, use the same STS-ARN to Linux-user mapping as multi-user mode (`IdentityMapper`). | Keeps "log in as yourself" without extra configuration. |
| WF-6 | P0 | **Independent of the DCV connect.** Web forwards have their own on/off and their own state. Turning them on must not launch DCV Viewer, and disconnecting DCV must not drop them. | They share the front half: auth, instance lookup, instance start, SSM-online wait. |
| WF-7 | P0 | **Supervised like the DCV tunnel.** An unexpected exit of the SSH process triggers a reconnect with the same backoff policy as F-13, pushing a fresh key each time. A user-initiated stop does not reconnect. | The key from the previous attempt is expired by then. |
| WF-8 | P0 | **Port conflicts are reported, not fought.** If a local port is taken by something that is not our own stale process, fail with the existing `localPortInUse` error naming the port. | Reuse `PortProbing`. |
| WF-9 | P1 | **PAC file.** Write a PAC file from `proxySuffixes` and `socksPort` to Application Support and offer "Copy PAC URL" and "Reveal PAC file" in the menu. The internal branch returns only `SOCKS5 127.0.0.1:<port>`, with no `DIRECT` fallback. | The app does not touch system proxy settings. |
| WF-10 | P1 | **Menu.** A "Web Forwards" section: on/off, state line, and one "Open <name>" item per local forward that has an `openPath`. | Opens `http://127.0.0.1:<localPort><openPath>`. |
| WF-11 | P1 | **Profile editor.** Fields for the block in WF-1 with the same validation style as the existing editor (ports 1 to 65535, no duplicate local ports, suffixes start with a dot). Proxy suffixes appear as editable domain rows with Add Domain and per-row removal controls. | Empty or invalid added rows prevent Save. |
| WF-12 | P1 | **No session token in process arguments.** Pass the `StartSession` response to the plugin through the `AWS_SSM_START_SESSION_RESPONSE` environment variable instead of as its first argument. | See 6.2. This is how AWS CLI v2 invokes the plugin. |
| WF-13 | P2 | **Key material is ephemeral.** The private key lives in a `0700` temporary directory and is deleted when the connection ends or the app quits. | It is useless without an authorised push, but there is no reason to keep it. |

## 5. Acceptance criteria

- **AC-1 (WF-1).** A profile JSON written by the current release decodes with web forwards absent
  and behaves exactly as today. Unit test with a stored legacy profile.
- **AC-2 (WF-2, WF-4, WF-12).** The SSH argument builder is a pure function with unit tests: given
  a profile and a session it emits the expected `-D`, `-L` and `ProxyCommand` values, and the
  session token appears nowhere in the argument list.
- **AC-3 (WF-3).** With mocks, the connect sequence is: generate key, `SendSSHPublicKey`,
  `StartSession`, spawn SSH, in that order, and a `SendSSHPublicKey` failure surfaces as a clear
  error naming the missing permission.
- **AC-4 (WF-6).** Turning web forwards on with DCV disconnected reaches "on" without the DCV
  launch seam being called. Disconnecting DCV while web forwards are on leaves the SSH handle
  active.
- **AC-5 (WF-7).** A simulated unexpected SSH exit pushes a new key and respawns. A user stop does
  not.
- **AC-6 (WF-9).** The generated PAC contains one `dnsDomainIs` line per suffix and no `DIRECT`
  on those lines.
- **AC-7 (manual).** On a Mac with only the app and an SSO login: turn web forwards on, open an
  internal UI in the browser through the PAC file, complete its SSO login, open a local forward
  from the menu. DCV Viewer is not running at any point.

## 6. Design notes

### Replacement continuity follow-up

Local native routing settings survive a VM replacement, but the live SSH/SSM tunnel does not.
Current retry bounds and SSM registration alone do not prove readiness of a fresh user/home,
private DNS/routes or persisted user services. The separate
[replacement contract](./logical-workstation-replacement.spec.md) defines expected-rebuild waiting,
same-profile rediscovery and actual domain/dashboard recovery acceptance. It is not implemented
by the editor's same-owner rolling-lease fix or by changing an AMI reference alone.

### 6.1 Why SSH inside SSM, and not more port-forward sessions

The app could open extra `AWS-StartPortForwardingSession[ToRemoteHost]` sessions, which is what it
already knows how to do. That was rejected for three reasons:

- **Real hostnames.** An internal app behind a load balancer has a certificate and an SSO callback
  bound to its hostname on port 443. A raw forward gives `127.0.0.1:<port>`, so it needs
  `/etc/hosts` entries and a listener on local port 443. SOCKS5 with proxy-side DNS needs neither:
  the browser keeps the real URL and TLS runs end to end.
- **One session instead of many.** Each port-forward is its own SSM session and its own plugin
  process. SSH multiplexes any number of forwards over one.
- **Whose connection it is on the host.** A port-forward session connects on the host as the SSM
  agent, which is root. An SSH forward connects as the SSH user. On a shared host that difference
  is what lets a loopback web app be restricted to its owner (section 6.5).

### 6.2 Process shape

```
/usr/bin/ssh -N -i <tmp>/key -o IdentitiesOnly=yes
  -o ProxyCommand="<bundled plugin> AWS_SSM_START_SESSION_RESPONSE <region> StartSession '' '<params JSON>'"
  -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3
  -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
  -D 127.0.0.1:<socksPort> -L 127.0.0.1:<lp>:<host>:<rp> ...
  <user>@<instance-id>
```

- The `StartSession` response JSON goes in the environment of the `ssh` process under
  `AWS_SSM_START_SESSION_RESPONSE`; the plugin reads it when its first argument is that variable's
  name. A live Mac test on 2026-10-12 confirmed this exact five-argument form against the
  checksum-verified bundled version `1.2.814.0` (section 3.2), including an empty profile argument
  and no endpoint argument. No command-line response fallback is needed for that version.
- `<params JSON>` is `{"Target":"<id>","DocumentName":"AWS-StartSSHSession","Parameters":{"portNumber":["22"]}}`.
  It contains no single quotes, so single-quoting it inside `ProxyCommand` is safe.
- Host key checking is off on purpose. The session is brokered by AWS for an instance id the app
  resolved in the user's own account, and a host that is rebuilt from an image changes its host
  keys every time.
- `ServerAliveInterval` keeps traffic on the session so Session Manager's idle timeout (20 minutes
  by default) does not close it.
- No `-f` and no control socket in the app: the app owns the process and its lifetime, like
  `BundledPluginTunnelHandle` does for the plugin. The script uses a control socket only because
  it has no supervisor.

### 6.3 Where it lands in the code

- `Models/ConnectionProfile.swift`: optional `webForwards` block (WF-1).
- `Services/SSMProviding.swift`, `SSMService.swift`: a second start method for
  `AWS-StartSSHSession`. Leave `portForwardDocument` and the existing method alone.
- New `Services/InstanceConnectProviding.swift` with an SDK-backed implementation. Add the
  `AWSEC2InstanceConnect` product in `Package.swift` (confirm the product name against the pinned
  `aws-sdk-swift`).
- New `Tunnel/SSHTunnel.swift` implementing a tunnel handle with the same contract as
  `BundledPluginTunnelHandle` (`isActive`, `onDisconnect`, `terminate`). Reuse `PluginSpawning`
  and `PortProbing`; they are already generic over the executable.
- Key generation: shell out to `/usr/bin/ssh-keygen -t ed25519 -N ''` into a `0700` temporary
  directory. It avoids hand-serialising the OpenSSH private key format.
- `StateMachine/`: a small separate state holder for web forwards (off, starting, on, error) that
  reuses the auth, resolve, start and SSM-online steps. Do not add cases to `ConnectionState`; its
  eight states describe the DCV connection and are tested as such.
- `App/MenuContentView.swift`, `Settings/ProfileEditorView.swift`: WF-10, WF-11.

### 6.4 Browser side

The existing implementation exposes PAC files for manual browser integration. A proposed
first-class Open Browser flow is specified separately in
[browser-bootstrap.spec.md](./browser-bootstrap.spec.md); it requires acceptance before coding
and is not implemented or implied by the manual browser tests above.

The current routing mechanism is:

```js
function FindProxyForURL(url, host) {
  if (dnsDomainIs(host, ".internal.example.com")) return "SOCKS5 127.0.0.1:1080";
  return "DIRECT";
}
```

- Chromium-based browsers resolve names on the proxy side for SOCKS5, which is required: internal
  names usually do not resolve on the client. Firefox needs "Proxy DNS when using SOCKS v5".
- Only listed suffixes use the tunnel. The identity provider is normally public and must stay
  direct. If its sign-on policy only admits the corporate network, add its hostname to the
  suffixes.
- Do not proxy everything. A host that sits behind a TLS-inspecting egress would hand the browser
  certificates it does not trust.
- For a quick test without touching browser settings:
  `open -na "Google Chrome" --args --user-data-dir=/tmp/wf-profile --proxy-pac-url="data:application/x-ns-proxy-autoconfig;base64,$(scripts/web-forwards.sh pac | base64 | tr -d '\n')"`

### 6.5 Example: a dashboard on the host's loopback

Not part of the app, documented because it is the main use of local forwards and has two traps.
The setup that was tested is Headlamp's server binary run as a systemd user unit with the host
user's kubeconfig, bound to `127.0.0.1:4466`.

- **Restrict it to its owner.** A dashboard in kubeconfig mode has no login of its own. On a shared
  host, loopback is shared between users, and anyone allowed to start an SSM port-forward session
  to the host can reach any loopback port as root. An owner match closes both:

  ```
  iptables -I OUTPUT -o lo -p tcp --dport 4466 -m owner ! --uid-owner <uid> -j REJECT --reject-with tcp-reset
  ```

  With that rule the owner's SSH forward works, other users and a plain SSM port-forward are
  reset. Install it from the unit's `ExecStartPre` so the app does not start without it.
- **Keep the port.** Headlamp rejects requests whose `Host` header is not its own address and
  port. The local port on the client must equal the remote port, which is why WF-1 has no
  automatic port remapping.

## 7. Security

- **Authority.** Opening the tunnel takes the user's AWS session with `ssm:StartSession` and
  `ec2-instance-connect:SendSSHPublicKey` on the instance. There is no long-lived secret: the key
  works for 60 seconds after an authorised push.
- **The pushed key is a normal login.** Instance Connect keys cannot carry `authorized_keys`
  restrictions, so for its validity the key can open a shell as that OS user and the tunnel can
  reach anything the host can. For a user tunnelling to their own account this adds nothing to
  what DCV already gives them. Deployments that want a forward-only credential can use a static
  key with `restrict,port-forwarding,command="/bin/false",permitopen="..."` instead; `restrict`
  and `port-forwarding` alone still allow running commands.
- **Scope `SendSSHPublicKey` by OS user.** On a multi-user host, a role that may push a key for
  any OS user can log in as any of them. The IAM condition key `ec2:osuser` limits a role to its
  own user. This is a property of the host's IAM setup, not of this app, but the README should say
  it.
- **Local listeners.** The SOCKS port and local forwards are open to any process on the Mac while
  the tunnel is up. Bind loopback only, and close them on disconnect and on quit.
- **Session logging.** Session Manager does not record the content of SSH or port-forward
  sessions. Same as the DCV tunnel.

## 8. Open questions

1. Does the SSO login to an internal app complete from the user's own network (Part A, step 3)?
2. Should web forwards auto-start with the profile, like auto-connect does for DCV?
3. A managed-browser action is requested; its proposed contract is in
  [browser-bootstrap.spec.md](./browser-bootstrap.spec.md), awaiting acceptance before implementation.
4. Should the SOCKS destination set be limited from the app side? SSH cannot restrict a dynamic
   forward without `permitopen` on the key, which Instance Connect keys cannot carry.
