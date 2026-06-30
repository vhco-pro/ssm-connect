# BUG REPORT: DCV "endpoint is unreachable" — `localhost` resolves to IPv6 `::1`, SSM tunnel is IPv4-only

- **Status:** FIXED — shipped in v0.2.2 (`host=127.0.0.1` on every `.dcv` entry point + readiness/cert-trust probes; PRs #11/#12), verified live (token accepted, display channel over `127.0.0.1`). The launch-path resilience gap that *hid* this (#9) shipped in v0.3.0 and was corrected in v0.3.1.
- **Severity:** P0 — blocks all connections on affected Macs (no workaround inside the app)
- **Area:** F-09 (SSM tunnel) / F-10 (DCV viewer auto-login)
- **Reported:** 2026-06-29 — author's Mac, against the multi-user workstation (`i-0e0d7f2d6366e9205`, eu-central-1)
- **Related:** GitHub issue [#9](https://github.com/vhco-pro/ssm-connect/issues/9) (viewer-launch hardening). This bug is a distinct, confirmed root cause; #9 is the resilience gap that *hid* it.

## Symptom

On connect, the app authenticates and reports ready, the DCV Viewer opens, then fails with:

> Unable to connect: cannot connect a new stream: endpoint is unreachable

Reconnecting does not help. The same error string is documented in **F-10** but was previously attributed only to a DCV-server-not-ready *timing* race (probe fix, 2026-06-06). That timing fix does not cover this cause.

## Root cause (proven)

The `.dcv` connection file and the readiness probe use the hostname **`localhost`** (F-10; `DCVConnectionFile.host` default; `WorkstationReadiness` probes `https://localhost:<port>`). On macOS, `/etc/hosts` maps `localhost` to **both** `127.0.0.1` and `::1`, and `getaddrinfo("localhost")` returns **`::1` (IPv6) first**. The SSM `session-manager-plugin` port-forward binds the local listener to **IPv4 `127.0.0.1` only**. So:

| Client → | Result |
|---|---|
| `127.0.0.1:<port>` (IPv4) | reaches dcvserver (HTTP 404 on `/`) ✅ |
| `[::1]:<port>` (IPv6) | nothing listening — connection fails ❌ |
| `localhost:<port>` | resolves `::1` first; **DCV Viewer connects to `::1` and does not fall back to IPv4** → "endpoint is unreachable" ❌ |

`curl localhost:<port>` works only because curl falls back to IPv4 (happy-eyeballs); the DCV Viewer does not, so it never opens a socket to the (IPv4-only) tunnel.

### Evidence (live, 2026-06-29)

- Tunnel listener: `lsof` → `session-manager-plugin … TCP 127.0.0.1:8443 (LISTEN)` (IPv4 only).
- `/etc/hosts`: `127.0.0.1 localhost` **and** `::1 localhost`; `getaddrinfo` → `::1` first.
- `curl -4 127.0.0.1:8443` → `404`; `curl -6 [::1]:8443` → `000` (fails).
- With `host=localhost`: dcvserver logs **zero** client connections; agent stays `connections=0`; viewer opens no socket.
- With **`host=127.0.0.1`** + sessionid + a valid presigned token: agent logs `token accepted user=dl6544-a`; dcvserver establishes **all** channels (display/input/audio/clipboard/…); `Received layout … 1920x1016 (head 1 primary)`. Full connection + stream succeed.
- Manual viewer connect to `https://127.0.0.1:8443` changed the error from "endpoint is unreachable" to "expected HTTP 101 … got 404" (a stream-path artifact of a session-less manual connect) — confirming IPv4 reaches the server.

### Why it surfaced now (not a config the user changed)

`/etc/hosts` last changed 2025-11-14 (months prior); the Viewer (2025.0 r8846, Jun 4) and bundled plugin (1.2.814.0, Jun 15) are unchanged. The IPv4/IPv6 mismatch is **latent** — `localhost` hitting `::1` and only *sometimes* falling back to IPv4 in time is timing-dependent. A fresh workstation instance (different connect/handshake timing) tipped the Viewer from "fell back in time" to "gave up on `::1`." The server, QUIC, cert, and auth were all ruled out; the instance replacement was coincidental.

## Proposed fix

Use the explicit IPv4 loopback **`127.0.0.1`** instead of `localhost` everywhere the client targets the local tunnel — removing all dependence on resolver order and on the Viewer's (absent) IPv4 fallback:

1. `Models/DCVConnectionFile.swift` — change `host` default and the `vanilla(...)` / `multiUser(...)` factory defaults from `"localhost"` to `"127.0.0.1"`.
2. `DCV/WorkstationReadiness.swift` — probe `https://127.0.0.1:<port>/` instead of `https://localhost:<port>/`.
3. Spec **F-10** — update the documented `.dcv` `host=localhost` to `host=127.0.0.1` and add a note that `localhost` is IPv6-ambiguous against an IPv4-only SSM port-forward.

Optional defense-in-depth (not required; the plugin already binds `127.0.0.1`): none needed. Do **not** rely on binding the tunnel to `::1` — the canonical, simplest fix is the client targeting `127.0.0.1`.

### Acceptance

- New unit assertion: `DCVConnectionFile.iniContent()` emits `host=127.0.0.1`.
- Manual: on a Mac with `::1 localhost` present, a normal connect launches the Viewer and the desktop streams (no "endpoint is unreachable").

## Immediate workaround (until a release ships)

Comment out the `::1 localhost` line in `/etc/hosts` so `localhost` resolves to IPv4 only. (System-wide; low risk. Reverts on demand.)
