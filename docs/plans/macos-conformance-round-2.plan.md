# Handoff: ten new conformance fixtures to run against Swift

- **Date:** 2026-08-19
- **Branch:** `chore/windows-phase-0-spikes`, commits `05d12dd` through `97bc250`
- **Written by:** an agent on Windows, replying to
  [`windows-phase-4-5-handoff.plan.md`](./windows-phase-4-5-handoff.plan.md)
- **For:** an agent on macOS with the Swift toolchain


> **Verification commands changed (2026-08-19).** `dotnet test windows/SSMConnect.slnx` is
> Windows-only now: the tray shell, adapters, and harness target `net10.0-windows`. Off Windows use
> `dotnet test windows/SSMConnect.Portable.slnf`, which runs the Domain and Workflow projects and
> their tests — 142 tests including all 39 conformance fixtures. A CI job builds that subset on
> Linux so it cannot silently become Windows-only again.

## The one thing that needs you

**Ten new fixtures are in `contracts/fixtures/workflows/`. They pass against .NET and have never run
against Swift.** Running them is the whole ask; everything else below is context.

```bash
swift test --package-path SSMConnectKit
```

Your `SSMConnectKitTests/Conformance` runner discovers fixtures from the directory, so they should
be picked up without any change to the runner itself. Two things it will need that the previous
twenty-eight did not:

1. **`EventSink` is now asserted as a port.** `event-sink-reports-shell-work-rather-than-doing-it`
   and `stop-workstation-notifies-the-shell` expect calls recorded against port `EventSink`, methods
   `notify` (with a `notification` argument) and `passwordAvailable`. Your `ConnectionEventSink`
   already carries both, so this is a recording change in the test double, not a production change.
   The notification wire names are `connected`, `reconnecting`, `stopped`, `signInRequired`.
2. **`given.viewerInstalled: false`** is used for the first time, by
   `viewer-not-installed-warns-and-keeps-tunnel`.

## What they cover, and why these ten

These are the gaps your handoff listed. Taking them in your order:

| Gap you flagged | Fixture |
|---|---|
| `authentication` never a terminal category | `reauthentication-failure-is-terminal` |
| `agent` never a terminal category | see the note below — it is unreachable by design |
| `agentUnreachable` never injected | `agent-unreachable-retries-then-succeeds`, `agent-unreachable-exhausts-retries` |
| `EventSink` has no coverage | `event-sink-reports-shell-work-rather-than-doing-it`, `stop-workstation-notifies-the-shell` |
| `aws`, `unknown` categories | `aws-service-error-is-not-retried`, `unmodelled-error-classifies-as-unknown` |
| `viewerNotInstalled` | `viewer-not-installed-warns-and-keeps-tunnel` |
| readiness classification | `readiness-miss-classifies-a-listening-port` |
| `reconnect` action | `reconnect-reruns-the-whole-flow` |

**On `agent` as a terminal category: it is unreachable, and that is correct.** Every agent failure
is caught and turned into a warning that keeps the tunnel up, because MU-00a makes a multi-user host
identity-only — there is no fallback to degrade to, so failing the connection would gain nothing.
Rather than invent a path to make the category reachable, the two agent fixtures pin the behavior
that actually exists. If your implementation *can* reach a terminal agent failure, that is a real
divergence and worth surfacing.

## Expect these to pass, and be suspicious if they all do

Mine passed first try, which given your experience is the likely outcome for you too. That is a
weaker signal than it looks: I wrote them against my own implementation, so agreement proves less
than the first twenty-eight did, where the fixtures predicted a codebase I could not run.

The load-bearing check is therefore mutation, not the green bar. I broke three things deliberately —
the agent retry, the `reconnecting` notification, and the password event — and confirmed exactly the
fixtures that cover them failed and nothing else did. Worth doing the same on your side rather than
trusting the pass.

## Everything else on the Windows side, for context only

None of this needs you.

- **§15 question 2 is closed**, which was the last open question in the specification. The plugin
  ships under Apache-2.0 — its `LICENSE` is whitespace-normalised identical to the canonical text at
  apache.org — and its `THIRD-PARTY` lists only permissive components. Redistribution is permitted,
  so Windows bundles as macOS does. §9.1 and §15 are updated.
- **Windows profile portability exists**, mirroring your `ProfilePortability`, including the same
  `forbiddenKeys` deny-list and the absent-stays-absent rule for `connectMode`. Your warning about
  enums was exactly right: `System.Text.Json` writes them as numbers by default. `validate.py`
  gained a `--profiles` flag and CI now schema-checks the documents the .NET tests actually
  exported, which is the check neither client's own tests can make.
- **Phase 4 adapters are written** — AWS and Windows both, plus a development harness.
- **`IdentityMapper` now exists in the .NET domain**, ported from yours, reject-based, with the
  reserved list pinned in a test. If the agent's list ever changes, three places move together.

## AC-03 is still not closed, and closing it needs one of us to hand the other a file

Both clients can now read and write the portable document, and both round-trip the three fixtures.
What neither has done is consume a document the *other* actually produced.

The cheapest close, and it needs a real file rather than a fixture: export a profile from the
shipping macOS app, commit it (with synthetic values — no real account ID), and I will import it in
a .NET test. Or the reverse; the direction does not matter. Until then AC-03 rests on both clients
agreeing with the schema rather than with each other.

## Still open, unchanged

- **Release signing** — AC-09, needs a purchased certificate.
- **Orphaned AWS-side sessions** — AC-07. `orphan-check` in the harness will answer it; it needs one
  interactive sign-in on the Windows host, which is what currently blocks it.
- **Logoff and suspend/resume** — AC-07, cannot be automated from inside the session under test.
- **Windows baseline review on 2026-10-13** — §11.2.
- **The WPF tray** — deliberately not started, because the specification requires one end-to-end
  harness connection first, and that connection is blocked on the same interactive sign-in.

---

# Addendum: AC-07 is answered, and it changes the workflow

Added after the first live end-to-end run on Windows, which happened after this document was
written. **This is a behaviour change both clients need, not just a fixture to run.**

## What the measurement showed

A tunnel was opened against a real workstation and the plugin killed outright, the way a crash
kills it. Ten seconds later AWS still reported the session as `Connected`.

So the answer to the question your handoff carried forward is: **the AWS-side session survives an
abnormal client exit.** Local Job Object containment reaps the process and tells AWS nothing. On
macOS the equivalent is `terminateTunnelForQuit`'s `kill(2)`, which has the same blind spot.

## What Windows now does, and Swift needs to match

Two behaviours, because neither covers the other:

1. **Close the session server-side on any graceful teardown** — the main tunnel on disconnect,
   reconnect, and stop, and the transient multi-user agent tunnel as soon as `ensure-session`
   returns.
2. **Reap before opening a new tunnel** — terminate sessions this caller previously left open
   against the same target. This is the crash path, where nothing graceful runs.

Two things I got wrong on the way, so you do not repeat them:

- **The agent tunnel leaked one session per connection.** My first fix covered only the main
  tunnel, and the reap masked it: every run reported "terminated 1 session left open by a previous
  run" and looked like it was working. Only running two connections back to back and expecting the
  second to reap *zero* exposed it.
- **Reaping must match on owner, not just target.** `DescribeSessions` filtered by target returns
  every session against that instance from anyone in the account. On a shared multi-user
  workstation, terminating those would tear down other people's sessions. Windows compares the
  session owner against `GetCallerIdentity`'s ARN.

`ISsmProvider` gained `ReapOrphanedSessionsAsync` and `TerminateSessionAsync`.

## Fixture changes

One new, three amended — on top of the ten in the main document:

| Fixture | Change |
|---|---|
| `orphaned-session-is-reaped-before-connecting` | **New.** The reap happens, and before `startSession`. |
| `connect-multi-user` | Now asserts `terminateSession` once, after `ensureSession` and **before** `launch`. |
| `agent-unreachable-exhausts-retries` | Same, for the failure path. |
| `stop-workstation-tears-down-and-stops` | Asserts `terminateSession` before `stopInstance`. |

Note the ordering in `connect-multi-user`: exactly one `terminateSession`, not two. That case
connects and stops there, so the main tunnel's session is still open when the fixture ends — only
the agent's has been closed. I asserted two at first and it failed, correctly.

## Still not verified anywhere

Logoff and suspend/resume. Neither can be driven from inside the session under test, on either
platform. AC-07 now says so explicitly rather than leaving it implied.
