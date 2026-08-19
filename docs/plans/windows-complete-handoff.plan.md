# Handoff: the Windows client is done — what is left is macOS

- **Date:** 2026-08-19
- **Branch:** `chore/windows-phase-0-spikes`, through commit `239ff09`
- **Written by:** an agent on Windows 11 24H2 x64
- **For:** whoever picks up the macOS side

Every Windows phase is complete. This is the closing summary, and the list of what now needs a Mac
or a purchase rather than a Windows host.

## State of play

| Phase | State |
|---|---|
| 0 — Feasibility spikes | Complete |
| 1 — Contracts and fixtures | Complete. 39 fixtures pass against .NET; 28 of them also pass against Swift |
| 2 — Swift target separation | **Partly done. macOS work.** Target split done; MR-05, MR-07, MR-08 remain |
| 3 — Windows domain and workflow | Complete |
| 4 — Windows adapters and tray shell | Complete |
| 5 — Packaging and release hardening | Complete except signing |

162 tests pass on Windows. Verify the whole repository with:

```bash
python3 contracts/validate.py --profiles windows/tests/SSMConnect.Domain.Tests/bin/Release/net10.0/artifacts/exported-profiles
dotnet test windows/SSMConnect.slnx
swift test --package-path SSMConnectKit   # needs macOS
```

## What the macOS side needs to do

### 1. Run the eleven new fixtures (blocking for AC-04)

Ten are described in [`macos-conformance-round-2.plan.md`](./macos-conformance-round-2.plan.md);
its addendum covers the eleventh and the workflow change behind it.

**The workflow change is the important part, not the fixture count.** Live testing established
that an abnormally exited client leaves its AWS-side SSM session reported as `Connected`. Both
clients must therefore close sessions server-side on graceful teardown *and* reap their own
leftovers before opening a new tunnel, matching on owner so a shared workstation is not disrupted.
macOS has neither behaviour yet, and `terminateTunnelForQuit`'s `kill(2)` has exactly the same blind
spot the Job Object did.

### 2. Finish Phase 2

MR-05 (move `Observation` out of the workflow), MR-07, and MR-08. Unchanged from the earlier
handoff.

### 3. Close AC-03 by exchanging a real document

Both clients read and write the portable profile, and both round-trip the fixtures. Neither has
consumed a document the *other* actually produced. Export one from the macOS app with synthetic
values, commit it, and a .NET test will import it. Either direction closes it.

## What needs a purchase, not a keyboard

**Release signing.** Authenticode-sign the MSI and the payload, then re-run
`packaging/Build-Release.ps1` so the WinGet manifest hash matches the signed file. The script stops
short of signing deliberately and says so, because an unsigned MSI must not reach a manifest.

OV versus EV is still open: EV carries SmartScreen reputation immediately, OV earns it over time.
This gates AC-09 and nothing else.

## What needs the workstation fixed, not the client

**The multi-user agent is not running** on `oneb2c-be-factory-prd-workstation-mu`. The tunnel to
port 8444 is healthy and accepts connections, but nothing serves on the far side —
`dev-harness agent-check` reports the far end accepting and then closing without a response.

The client handles it exactly as designed: it warns, keeps the tunnel up, and does not fall back to
a shared user, because MU-00a makes a multi-user host identity-only. Once the agent is running,
`dev-harness connect` should complete multi-user auto-login with no client change. That is the one
path never demonstrated end to end.

## Still unverifiable anywhere

- **Logoff and suspend/resume** (AC-07). Neither can be driven from inside the session under test,
  on either platform. Run them by hand, or in a VM that can drive the power state.
- **Windows baseline review on 2026-10-13** (§11.2). Windows 11 24H2 Home/Pro reaches end of updates
  then; the floor likely moves to 25H2, build 26200.

## Three things worth knowing before changing the Windows client

Each cost real time to find, and none is visible from reading the code.

1. **Do not point MSI's `Icon` element at the single-file executable.** It embeds the whole binary a
   second time: the installer went from 58 MB to 225 MB and installs became so slow they had to be
   killed.
2. **msiexec is not manifested for Windows 10 or later.** It reports `VersionNT` 603 and
   `WindowsBuild` 9600 — Windows 8.1 values — on a Windows 11 host, so any launch condition using
   them rejects every machine. The build number comes from the registry instead, and the literal is
   quoted because MSI evaluates a string-to-unquoted-integer comparison as false.
3. **Windows Forms costs 41 MB and all trimming.** The tray uses `Shell_NotifyIcon` directly for
   that reason. Trimming is unavailable regardless (WPF, NETSDK1168), but the Windows Forms
   reference was pure loss.

## A note on the fixtures

Nineteen of the current thirty-nine were written by an agent against its own implementation, so a
green bar on them proves less than it did for the original twenty-eight, which predicted a codebase
that agent could not run. Mutation testing is what actually load-bears here: each batch was verified
by deliberately breaking the behaviour and confirming that exactly the covering fixtures failed.
Worth continuing on the Swift side rather than trusting the pass.
