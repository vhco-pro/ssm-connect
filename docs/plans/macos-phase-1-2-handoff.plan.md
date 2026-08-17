# Handoff: macOS work for Phases 1 and 2

- **Date:** 2026-08-18
- **Branch:** `chore/windows-phase-0-spikes` (three commits: `c372fcb`, `0ae0277`, `cd1f322`)
- **Written by:** an agent working on Windows, which cannot build or run any Swift in this repository
- **For:** an agent on a macOS host with Xcode, XcodeGen, and the existing test suite working

## Why this handoff exists

The repository now has two clients' worth of work in it, and the split is not by preference but by
capability. The macOS app builds through XcodeGen and Xcode; `swift`, `swiftc`, `xcodebuild`, and
`xcodegen` do not exist on Windows and cannot be installed there. Everything Swift-side is therefore
untouched, including work that is genuinely blocking.

Read this alongside [`cross-platform-client.spec.md`](../specs/cross-platform-client.spec.md), which
is the source of truth. Where this document and the specification disagree, the specification wins.

## What is already done, so you do not redo it

| Area | State |
|---|---|
| Phase 0 Windows spikes | Complete. §16 planning gate met. See [`windows-phase-0-spikes.plan.md`](./windows-phase-0-spikes.plan.md). |
| Phase 1 contracts | Schemas and 28 fixtures authored, and **passing against .NET**. Not run against Swift. |
| Phase 3 Windows domain and workflow | Complete. 63 tests pass. |
| Phase 2 Swift separation | **Not started.** Yours. |
| Phase 4–5 Windows adapters, shell, packaging | Not started. Windows-side work, not yours. |

Nothing in `SSMConnectKit/`, `SSMConnect/`, `project.yml`, or `Makefile` has been modified. The
macOS app is exactly as it was.

## Your task 1 (blocking): run the conformance fixtures against Swift

This is the remaining half of AC-04 and the thing that closes Phase 1.

`contracts/fixtures/workflows/` holds 28 cases describing the connection workflow's observable
behavior: the ordered states it emits, the calls it makes, and its terminal result. They were
derived by **reading** `ConnectionStateMachine.swift` on a Windows host. They have never been run
against the code they describe.

**Build a fixture runner for `ConnectionStateMachine` and make all 28 pass.**

### Read these first

- [`contracts/README.md`](../../contracts/README.md) — the format, the three design decisions behind
  it, the coverage matrix, and two deliberate schema tightenings that need your confirmation.
- [`contracts/state-machine.schema.json`](../../contracts/state-machine.schema.json) — the fixture
  format, fully commented.
- `windows/tests/SSMConnect.Workflow.Tests/` — **a working reference implementation of exactly the
  runner you need to build.** `FixtureModel.cs` is the document shape, `PortRecorder.cs` implements
  the outcome-queue semantics and the portable-error mapping, `FakePorts.cs` is one fake per port,
  and `ConformanceTests.cs` is the assertion logic. Port the design, not the code.

### Three semantics that are easy to get wrong

1. **Outcome queues.** Each entry in a port method's array is consumed by one call, and the last
   entry repeats. That is how a fixture expresses "fails once, then succeeds" without scripting.
2. **Errors are portable kinds.** A fixture says `expiredCredentials`, never a platform type. Your
   runner maps each kind to the Swift error the state machine actually catches — `expiredCredentials`
   in particular must be whatever `isExpiredCredentials` returns true for, or the re-auth cases will
   not exercise the path they are meant to.
3. **Terminal failures assert a category, not a message.** `errorCategory` is the contract;
   `ConnectionStateMachine` currently has no such concept and only produces a message string, so you
   will need to derive or add one. Do not weaken the fixtures to compare message text — different
   wording between the two clients is allowed and expected.

### How to treat a disagreement

**Shipping macOS behavior is the reference.** A mismatch means the fixture is wrong, unless you can
show the macOS behavior is itself a bug. When you change a fixture:

1. Change it in `contracts/`.
2. Re-run `python3 contracts/validate.py`.
3. Re-run the .NET suite: `dotnet test windows/SSMConnect.slnx`. It will now fail, and the .NET
   workflow must be corrected to match. **Do not leave the two implementations disagreeing.**

Running these fixtures against .NET already caught three ordering errors *in the fixtures*, so
expect more. The likely areas, where I inferred rather than observed:

- **Exact emitted-state sequences.** The fixtures assume no duplicate consecutive states are emitted
  and that re-authentication does not return to `authenticating`. Both are read from the Swift
  source, not observed.
- **Call ordering around instance-replacement detection.** `setLastInstanceId` is asserted
  immediately after resolve; verify against the real ordering.
- **`disconnect` and `stopWorkstation` cancellation.** Fixtures assume the cancelled connect emits
  nothing further and the cancelling action owns the terminal state.
- **Warning-versus-failure boundaries.** Secret-fetch and agent failures are asserted as warnings
  that keep the tunnel up. Confirm the macOS client agrees.

## Your task 2: close specification §15 question 6

Should profile export carry app preferences, or only connection profiles? The proposal is
profiles-only for schema v1. `connection-profile.schema.json` currently includes a small
`preferences` object (`autoConnect`, `autoReconnect`, `clipboardAutoClearSeconds`), which is
**broader than the proposal** and needs an explicit decision rather than inheriting mine.

Decide, record it in §15, and make the schema match.

## Your task 3: confirm two deliberate schema tightenings

Both are stricter than today's Swift code, and either could make an existing profile fail to export.

| Field | Swift today | Schema | Confirm |
|---|---|---|---|
| `accountId` | any non-empty string | `^[0-9]{12}$` | Do any real stored profiles violate this? |
| `secretId` on a multi-user profile | unconstrained | must be `null` | Does any real multi-user profile carry one? |

If either breaks a real profile, relax the schema rather than the profile.

## Your task 4 (the large one): Phase 2, behavior-preserving Swift separation

Only start this once task 1 passes. The fixtures are your regression net for the extraction, and
extracting first means doing it without one.

The specification's §10 and §5.1 define the target. The critical constraints:

- Move **one dependency boundary at a time**, running the existing focused tests after every move,
  with a rollback point after each.
- AC-01 requires the existing macOS tests to pass before *and* after, with no user-visible change.
- AC-02 requires the workflow and domain targets to import no AppKit, SwiftUI, ServiceManagement,
  UserNotifications, or Darwin.
- AC-10 requires the macOS app to stay independently buildable and releasable throughout.

Two known concrete obstacles, both visible from the source:

- `StateMachine/ConnectionState.swift` imports **SwiftUI** purely to type a `Color` property, and
  also carries SF Symbol names and tooltips. A domain state enum cannot own presentation. Split the
  value from its presentation before anything else depends on the split.
- `ConnectionStateMachine` imports **Darwin** for `kill`/`SIGTERM` in `terminateTunnelForQuit`, and
  imports `ClientRuntime`/`Smithy` for SDK error inspection in `describe(_:)`. Both are MR-04 and
  MR-06 respectively; the .NET side solved the equivalent problems with an `IEventSink` for shell
  policy and an `ErrorCategory` on typed domain errors, which may be worth mirroring.

The .NET `SSMConnect.Workflow` is a useful cross-check for what the portable half should contain:
it targets plain `net10.0`, so anything it does *not* need is a good candidate for staying on the
macOS side of your split.

## How to verify the whole repository after your changes

```bash
python3 contracts/validate.py            # schemas and fixtures as documents
dotnet test windows/SSMConnect.slnx      # 63 tests, includes all 28 fixtures
make test                                # the existing macOS suite
```

The first two run on any platform with Python 3 and the .NET 10 SDK. CI runs the first two
automatically ([`contracts.yml`](../../.github/workflows/contracts.yml),
[`windows-client.yml`](../../.github/workflows/windows-client.yml)); there is no CI job running the
macOS suite yet, which is worth adding while you are here.

## What is deliberately still open, and not yours

Recorded so you do not think they were forgotten:

- **Release signing.** Needs a purchased certificate. Gates AC-09, not the refactor.
- **Orphaned AWS-side sessions on abnormal exit.** Local process containment is proven; server-side
  session teardown is not. Carried by AC-07 and §9.3.
- **Logoff and suspend/resume.** Cannot be automated from inside the session under test.
- **Plugin redistribution terms.** §15 question 2. A licence read, not a test.
- **Windows baseline review on 2026-10-13.** §11.2.
- **Phases 4 and 5.** Windows adapters, WPF tray shell, and packaging. A future Windows session.
