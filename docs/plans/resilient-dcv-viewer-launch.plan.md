---
status: in-progress
status_description: "Plan for #9 — hard-gate the DCV viewer launch on readiness, assert tunnel liveness, detect instance replacement, and bounded auto-retry the establish. Defaults locked from spec open questions: RVL-5 = 2 retries (2s/4s backoff); flat probe interval; silent instance-replacement reset + log line."
description: "Implementation plan for resilient DCV viewer launch (readiness gating + reconnect safety)"
spec: docs/specs/resilient-dcv-viewer-launch.spec.md
tracking: "https://github.com/vhco-pro/ssm-connect/issues/9"
author: "SDD Planner (automated), run by michielvha <ytaccgsm@gmail.com>"
goal: "Never launch DCV Viewer into an unverified endpoint; make every pre-launch failure a clear, retryable error; verify tunnel liveness; survive workstation instance replacement."
priority: high
created: 2026-06-30
---

# Plan: Resilient DCV Viewer Launch

Translates `docs/specs/resilient-dcv-viewer-launch.spec.md` (#9) into a single-phase change in `SSMConnectKit`. This hardens the launch path that *masked* the #11 IPv6/IPv4 bug: a readiness miss currently logs "launching viewer anyway" and launches into a dead endpoint, surfacing a raw DCV error with no recovery.

## Context

Today the readiness probe + launch live inside the two per-mode launch helpers, and both treat a readiness miss as non-fatal (`if !ready { log "…launching viewer anyway" }`). The DCV step is otherwise "best-effort" (F-16): a missing viewer / launch failure keeps the tunnel up with a warning. We keep that best-effort semantics for *genuinely* non-fatal conditions (viewer not installed, launch failure, clipboard/token), but make **endpoint readiness** a hard, retryable gate.

Key code (all in `SSMConnectKit/Sources/SSMConnectKit`):
- [`ConnectionStateMachine.swift`](../../SSMConnectKit/Sources/SSMConnectKit/StateMachine/ConnectionStateMachine.swift) — `runConnect()` (step 5 `establishTunnel`, then per-mode launch), `fetchSecretAndLaunchDCV()` (~386-393 "launch anyway"), `ensureSessionAndLaunchMultiUser()` (~443-450 "launch anyway"), `teardownTunnel()`, the main `catch` → `teardownTunnel` + `fail`.
- [`WorkstationReadiness.swift`](../../SSMConnectKit/Sources/SSMConnectKit/DCV/WorkstationReadiness.swift) — `WorkstationReadinessProbing` (HTTPS probe to `127.0.0.1:<port>`).
- [`ConnectionTimeouts.swift`](../../SSMConnectKit/Sources/SSMConnectKit/StateMachine/ConnectionTimeouts.swift) — per-stage budget.
- Menu/UX already supports a retryable error: `state == .error` → "Retry Connect" button → `connect()` ([`+Menu.swift`](../../SSMConnectKit/Sources/SSMConnectKit/StateMachine/ConnectionStateMachine+Menu.swift), [`MenuContentView.swift`](../../SSMConnectKit/Sources/SSMConnectKit/App/MenuContentView.swift)). So RVL-6 is mostly "route pre-launch failures to `.error` with a specific `LocalizedError`".

## Locked decisions (spec open questions)

1. **Retry budget** — probe budget unchanged (`dcvReady` = 30s, 1s interval). RVL-5 full re-establish = **2 retries**, backoff **2s then 4s** (`establishRetryBackoff * attempt`).
2. **Backoff shape** — flat interval for the in-establish readiness poll; backoff only on the RVL-5 re-establish.
3. **Instance-replacement UX** — silent reset + one log line (no modal).

## Design

### New error type (RVL-6)
Add `DCVReadinessError: LocalizedError, Equatable` in `WorkstationReadiness.swift`:
- `.tunnelNotEstablished(port:)` — "The secure tunnel isn't listening on 127.0.0.1:<port>…"
- `.dcvServerNotReady(port:)` — "The workstation's DCV server didn't become ready in time…"

Both route through the existing `runConnect` `catch` → `teardownTunnel()` + `fail(error)` → `state = .error`, where `detailLine` shows `errorDescription` and the menu shows "Retry Connect". No UI changes required.

### Tunnel-up assertion (RVL-3)
New seam `TunnelListenerProbing { func isListening(host:port:timeout:) async -> Bool }` + default `TCPListenerProbe` (Network framework `NWConnection` raw TCP to `127.0.0.1:<port>`; `.ready` → true, `.failed/.waiting/.cancelled` or timeout → false). The `session-manager-plugin` binds the local port as soon as it's up, so a TCP refusal cleanly distinguishes *tunnel-not-listening* (`tunnelNotEstablished`) from *tunnel-up-but-DCV-not-answering* (`dcvServerNotReady`, the HTTPS probe).

### Centralized gate (RVL-1/RVL-2/RVL-3)
Add `assertEndpointReady(port:)`:
1. `guard await tunnelListener.isListening(...) else { throw .tunnelNotEstablished }`
2. `guard await readiness.waitUntilReady(port:, timeout: dcvReady, interval: dcvReadyPollInterval) else { throw .dcvServerNotReady }`

Call it in `runConnect` **between** `establishTunnel` (step 5) and the per-mode auto-login switch (step 6), so it applies uniformly to vanilla + multi-user and throws into the main `catch`. Remove the `if !ready { log "launching anyway" }` blocks (and their now-redundant readiness probe) from both launch helpers (RVL-1, AC-6 grep guard). The viewer-not-installed / launch-failure / token paths stay best-effort warnings.

### Bounded auto-retry of the establish (RVL-5)
Replace the bare `establishTunnel` call in step 5 with `establishReadyTunnel(instanceId:)`:
```
attempt = 0
loop:
  attempt += 1
  handle = try await establishTunnel(instanceId)        // fresh tunnel
  do { try await assertEndpointReady(port: localPort); return handle }
  catch let e as DCVReadinessError {
    await teardownTunnel()
    if attempt > timeouts.establishRetryAttempts { throw e }   // 2 retries → 3 tries total
    log("endpoint not ready (\(e)); re-establishing attempt \(attempt)…")
    try await reconnectSleep(timeouts.establishRetryBackoff * attempt)  // 2s, 4s
    try Task.checkCancellation()
  }
```
Idempotent (each iteration tears its own tunnel down) and cancellable (`disconnect()`/`reconnect()` cancel the connect task; `CancellationError` propagates). Distinct from the existing tunnel-*drop* auto-reconnect (§5), which is unchanged.

### Instance-replacement detection (RVL-4)
New seam `InstanceIdPersisting { lastInstanceId(forProfile:) / setLastInstanceId(_:forProfile:) }` + default `UserDefaultsInstanceIdStore` (key `ssmconnect.lastInstanceId.<profileUUID>`; no secrets). In `runConnect`, right after the instance is resolved (step 2):
```
if let prev = instanceIds.lastInstanceId(forProfile: profile.id), prev != instance.id {
    log("workstation instance changed (\(prev) → \(instance.id)); resetting stale tunnel state.")
    await teardownTunnel(); localPort = nil; tunnelPID = nil
}
instanceIds.setLastInstanceId(instance.id, forProfile: profile.id)
```
Guarantees no reuse of a handle/port bound to a terminated instance before `establishTunnel`.

### Timeouts (new fields in `ConnectionTimeouts`)
- `tunnelListen: Duration = .seconds(3)` (RVL-3 TCP assertion)
- `establishRetryAttempts: Int = 2` (RVL-5)
- `establishRetryBackoff: Duration = .seconds(2)` (RVL-5 base; × attempt)

### Dependency injection
Add `tunnelListener: TunnelListenerProbing = TCPListenerProbe()` and `instanceIds: InstanceIdPersisting = UserDefaultsInstanceIdStore()` to the full `init`. Convenience inits unaffected (defaults). Test builder gains stub defaults so existing tests don't hit the real TCP probe.

## Files

**Modify**
- `StateMachine/ConnectionStateMachine.swift` — `establishReadyTunnel`, `assertEndpointReady`, RVL-4 block, remove "launch anyway", new deps.
- `StateMachine/ConnectionTimeouts.swift` — 3 new fields.
- `DCV/WorkstationReadiness.swift` — `DCVReadinessError`, `TunnelListenerProbing` + `TCPListenerProbe`.

**Add**
- `Services/InstanceIdStore.swift` — `InstanceIdPersisting` + `UserDefaultsInstanceIdStore`.

**Tests**
- `StateMachine/StateMachineTestDoubles.swift` — `StubTunnelListenerProbe`, `MockInstanceIdStore`, extend `StubReadinessProbe` with a result sequence.
- `StateMachine/ConnectionStateMachineTests.swift` — add `tunnelListener`/`instanceIds` to builder; new tests AC-1..AC-5; fix `wakeDeadTunnelReconnects` to use a readiness sequence `[true,false,true]` (gate now fatal).
- `DCV/WorkstationReadinessTests.swift` (or existing) — `DCVReadinessError.errorDescription` assertions (AC-5).

## Acceptance → tests

| AC | Test |
|----|------|
| AC-1 (RVL-1/2) | readiness always false → `state == .error`, `dcv.launchCount == 0`, error is `dcvServerNotReady`, `startCount == 3` |
| AC-2 (RVL-3) | listener false → `tunnelNotEstablished`, `readiness.calls == 0`, no launch |
| AC-3 (RVL-4) | stored id ≠ resolved id → "instance changed" log + store updated to new id; unchanged id → no such log |
| AC-4 (RVL-5) | readiness `[false,true]` → connected, `startCount == 2`, `launchCount == 1`; always-false → error after 3 tries |
| AC-5 (RVL-6) | `DCVReadinessError` cases yield specific `errorDescription`; `state==.error` → `actionTitle == "Retry Connect"` |
| AC-6 (regression) | existing happy-path/auto-reconnect/wake tests green; `rg "launching viewer anyway"` → no hits |

## Release

`fix:`/`feat:`-prefixed commit so GitVersion bumps the cask (current v0.2.2 → v0.2.3). After merge: `brew upgrade`/reinstall, launch from `/Applications`, verify a real connect gates correctly (and a forced not-ready surfaces a retryable error, not a raw DCV error).

## Risks

- **Breaking existing tests** via the centralized gate: mitigated by stub defaults (listener=true, readiness=true) in the builder and the `wakeDeadTunnelReconnects` sequence fix.
- **`TCPListenerProbe` false-negatives** on a slow loopback: 3s budget + RVL-5 re-establish covers transient cases; the HTTPS probe remains the real readiness signal.
