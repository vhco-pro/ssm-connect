# SPECIFICATION: Resilient DCV Viewer Launch (readiness gating + reconnect safety)

- **Status:** implemented — shipped in v0.3.0 (PR #15, #9 closed). See [`resilient-dcv-viewer-launch.plan.md`](../plans/resilient-dcv-viewer-launch.plan.md).
- **Tracking:** GitHub issue [#9](https://github.com/vhco-pro/ssm-connect/issues/9)
- **Related:** [#11](https://github.com/vhco-pro/ssm-connect/issues/11) / `bug-ipv6-localhost-endpoint-unreachable.spec.md` (the IPv4 fix). This spec hardens the launch path that *masked* #11 — a failure that should have been a clear, retryable error instead launched the viewer into a dead endpoint.
- **Touches:** F-09 (tunnel), F-10 (viewer auto-login), §5 state machine, §8 edge cases.

## 1. Overview & Problem

On connect (both vanilla and multi-user), the app probes the DCV endpoint and then launches DCV Viewer. Today, on a readiness-probe miss it logs *"DCV server not reachable … launching viewer anyway"* and launches regardless ([`ConnectionStateMachine`](../../SSMConnectKit/Sources/SSMConnectKit/StateMachine/ConnectionStateMachine.swift) ~lines 386-392 / 443-449). The viewer then hits a not-ready (or wrong-family / torn-down) endpoint and the user sees a raw DCV error (`cannot connect a new stream: endpoint is unreachable`) on a manual connection screen, with no automatic recovery.

This made the #11 IPv6/IPv4 bug look like a viewer problem and left the user stuck. Even with #11 fixed, the launch path must fail **loudly and recoverably** when the endpoint genuinely isn't ready, must verify the tunnel is actually up, and must not silently target a replaced instance.

## 2. Goals / Non-Goals

**Goals:** never launch the viewer into an unverified endpoint; make every pre-launch failure a clear, retryable state; verify tunnel liveness; survive workstation instance replacement.

**Non-Goals:** changing the DCV protocol/transport (done in #11); changing auth; multi-monitor/display behavior (server-side, separate); replacing the `session-manager-plugin`.

## 3. Functional Requirements

| ID | Priority | Requirement | Notes |
|----|----------|-------------|-------|
| RVL-1 | P0 | **Hard-gate the viewer launch on readiness.** The viewer MUST NOT be launched unless the readiness probe has confirmed the DCV endpoint answers. Remove the "launching viewer anyway" fallback on both the vanilla (F-10) and multi-user paths. | The probe already polls `127.0.0.1:<localPort>` to `timeouts.dcvReady`; this changes the *timeout outcome* from "launch anyway" to "fail retryably". |
| RVL-2 | P0 | **Bounded retry with backoff before giving up.** Readiness uses a bounded poll budget (existing `dcvReady` timeout + interval), optionally with linear/expo backoff. On exhaustion → a distinct `dcvServerNotReady` error state; **no launch**. | Keep the budget tunable via `ConnectionTimeouts`. Don't retry forever (the host idle-stops on zero connections). |
| RVL-3 | P0 | **Distinct "tunnel not listening" diagnosis.** A failed/half-open `session-manager-plugin` MUST surface as a distinct `tunnelNotEstablished` error, not a generic viewer error. **Implementation note (v0.3.1):** the readiness poll (which connects to `127.0.0.1:<localPort>`) is the gate; the IPv4 TCP listener check runs *only when readiness fails*, to classify the message. An earlier standalone pre-check (v0.3.0) false-blocked healthy tunnels and was removed. | The plugin binds IPv4 `127.0.0.1` (ties to #11). |
| RVL-4 | P1 | **Instance-replacement detection.** Persist the last-connected instance-id per profile. On a new connect, if the resolved instance-id differs (workstation rebuilt), reset cached connection state (handle, `localPort`, tunnel PID) before establishing — never reuse a tunnel/handle bound to a terminated instance. | Workstations are stock-AMI + cloud-init; instance-id changes on every rebuild. |
| RVL-5 | P1 | **Auto-retry the full connect on a pre-launch failure (bounded).** On `dcvServerNotReady` / `tunnelNotEstablished`, attempt a bounded automatic re-establish (tear down + re-tunnel + re-probe) N times with backoff before surfacing the error. Distinct from the existing tunnel-drop auto-reconnect (§5). | N + backoff tunable; default small (e.g. 2). Must be idempotent and cancellable by `disconnect()`. |
| RVL-6 | P1 | **Clear, actionable error UX.** Each pre-launch failure maps to a specific user-facing message + a one-click **Retry**: `tunnelNotEstablished`, `dcvServerNotReady`, (existing) auth/`signInRequired`. No generic "operation couldn't be completed". | Extend the existing `LocalizedError` enums; surface in the menu (§5 menu layout). |

## 4. Acceptance Criteria

- **AC-1 (RVL-1/2):** With the DCV server not listening (probe never answers within budget), the app ends in a `dcvServerNotReady` state and the viewer is **never** launched (assert `DCVLauncher.launch` not called). Unit test with a probe stub that always fails.
- **AC-2 (RVL-3):** With the tunnel handle "up" but nothing listening on `127.0.0.1:<localPort>`, the app surfaces `tunnelNotEstablished` (distinct from `dcvServerNotReady`) and does not probe/launch.
- **AC-3 (RVL-4):** Given a profile whose stored instance-id ≠ the freshly resolved instance-id, the prior handle/port/PID are reset before `establishTunnel`; no reuse of stale state. Unit test.
- **AC-4 (RVL-5):** A transient pre-launch failure that clears on the 2nd attempt results in a successful connect with exactly one re-establish; a persistent failure surfaces the mapped error after the bounded attempts.
- **AC-5 (RVL-6):** Each failure path yields its specific `errorDescription`; the menu shows a Retry affordance. Unit assertions on the error enums.
- **AC-6 (regression):** Existing happy-path + auto-reconnect tests still pass; no "launch anyway" code path remains (grep guard).

## 5. Design Notes (for the plan step)

- Replace the two `!ready → log → launch` blocks with `!ready → throw DCVReadinessError.dcvServerNotReady` inside the connect `do` (so it routes to `fail(error)` / retry).
- Add a `tunnelIsListening(port:)` check (lightweight TCP connect to `127.0.0.1:<port>`) used by RVL-3; reuse the `HTTPSReadinessProbe` host (#11).
- `ConnectionProfile`/store: add `lastInstanceId` (UserDefaults, no secrets) for RVL-4.
- New error enum(s) conforming to `LocalizedError`; map in the menu/notifier.
- Keep all new timing in `ConnectionTimeouts`.

## 6. Open Questions

1. **Retry budget defaults** — `dcvReady` timeout value, and RVL-5 attempt count/backoff. Propose: probe budget unchanged; RVL-5 = 2 retries, 2s/4s backoff.
2. **Backoff shape for RVL-2** — keep flat interval (current) or add backoff? Propose: keep flat for the probe; backoff only on RVL-5 re-establish.
3. **Instance-replacement UX** — silent reset (RVL-4) vs a one-line "workstation was rebuilt, reconnecting" log/notice. Propose: silent + a log line.
