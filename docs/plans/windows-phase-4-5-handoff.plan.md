# Handoff: Windows work for Phases 4 and 5

- **Date:** 2026-08-18
- **Branch:** `chore/windows-phase-0-spikes` (new commits on top of yours, from `d14e645` onward)
- **Written by:** an agent on a macOS host, which cannot build, run, or package anything for Windows
- **For:** an agent on a real Windows 11 24H2 x64 host with the .NET 10 SDK, WiX, and Windows Sandbox

This is the reply to [`macos-phase-1-2-handoff.plan.md`](./macos-phase-1-2-handoff.plan.md). Read
it alongside [`cross-platform-client.spec.md`](../specs/cross-platform-client.spec.md), which is
the source of truth. Where this document and the specification disagree, the specification wins.

## The short version

Your fixtures were right. All 28 passed against the shipping `ConnectionStateMachine` **with no
fixture changes**, so nothing in `contracts/` moved under you and `windows/` needed no correction.
Phase 1 is closed, AC-04 is met, and §15 question 6 is answered.

Your side of the repository is untouched apart from three profile fixtures losing a `preferences`
object (see below). `dotnet test windows/SSMConnect.slnx` passes exactly as you left it: 63 tests.

## What changed while you were away

| Area | State |
|---|---|
| Phase 1 contracts | **Complete.** 28 fixtures pass against .NET *and* Swift. AC-04 met. |
| §15 question 6 | **Closed.** Profiles only; `preferences` removed from the profile schema. |
| Both schema tightenings | **Confirmed against real stored profiles.** Neither relaxed. |
| Phase 2 Swift separation | **Target split done** (five Swift targets, composition root, app unchanged). MR-05 and MR-08 remain. |
| §6.1 profile export/import | **macOS half done**, Windows half is yours. Neither client had it before. AC-03 half met. |
| Phase 3 Windows domain/workflow | Complete, unchanged, still 63 tests. |
| Phase 4–5 Windows adapters, shell, packaging | **Not started. Yours.** |

### The one contract change that touches your code path

`preferences` is gone from `connection-profile.schema.json` and from the profile fixtures. Nothing
in `windows/` read it — `FixtureProfileLoader` never looked at it and `ConnectionProfile` has no
such member — so the .NET suite passed unchanged. Flagging it anyway because it constrains Phase 4:

**When you build Windows profile persistence and import/export, do not put `autoConnect`,
`autoReconnect`, or `clipboardAutoClearSeconds` on the profile.** They are global `AppSettings`, as
your `ConnectionWorkflow` already treats them. The deciding evidence was that the shipping macOS
app stores them under a separate `ssmconnect.settings.v1` key, next to and not inside
`ssmconnect.profiles.v1`. Both clients already agreed; the schema was the odd one out.

### Profile export and import: the macOS half now exists, the Windows half is yours

When I wrote the first draft of this document I implied macOS could already export a profile. It
could not. §6.1 says both clients MUST support export and import of the portable document, and
**neither client implemented it** — the schema existed and nothing produced or consumed a document
conforming to it, so AC-03 was unmeetable by either side.

The macOS half is now done: `SSMConnectKit/Sources/SSMConnectDomain/PortableProfile.swift`, with
`PortableProfileTests` round-tripping all three `contracts/fixtures/profiles/*.json` documents. Yours
is Phase 4. Three things cost me real time and will cost you the same if you mirror your native
model instead of writing a separate document type:

1. **Do not serialize `ConnectionProfile` directly.** On macOS `ConnectAction` has no raw value, so
   the synthesized encoder emits `{"dcvViewer":{}}` where the schema demands `"dcvViewer"`. A naive
   export is schema-invalid in a way no unit test on the native model would catch. Check what
   `System.Text.Json` does with your `ConnectAction` and `ConnectMode` enums before trusting them —
   by default it writes enums as **numbers**, so you would emit `"connectAction": 0`.
2. **An absent `connectMode` must stay absent on re-export.** The single-user profile the shipping
   macOS app has stored has no `connectMode` key at all — it predates the field, and `null` means
   `singleUser`. Resolving it to `"singleUser"` while writing silently rewrites the document and
   makes AC-03 pass against synthetic data only. Same for `agentRemotePort` and its 8444 default.
3. **Preserve unknown optional fields, except the forbidden ones.** The schema asks for preservation
   on round-trip, but its security clause forbids `accessKeyId`, `password`, `authToken` and a dozen
   more. Preserve-everything plus that clause means a document carrying a secret must be *rejected*,
   not carried through. `ProfilePortability.forbiddenKeys` is the list I enforce; mirror it.

AC-03 stays open until a document actually crosses between the two clients. The cheapest close: your
importer reads `contracts/fixtures/profiles/*.json` in a test, and one of the documents in that
directory is one the macOS app really exported.

## Your task 1: Phase 4, Windows adapters

Implement the ports in `SSMConnect.Workflow/Ports.cs` against real Windows and real AWS, then get
one end-to-end connection working from a development harness **before** writing any WPF.

Phase 0 already proved every risky piece of this on real hardware, so this is assembly rather than
discovery. `spikes/windows/SSMConnect.WindowsSpikes/` is working code for the hard parts — the SSO
options, the five-argument plugin contract, the Job Object, the presigner, the `.dcv` file dance —
and [`windows-phase-0-spikes.plan.md`](./windows-phase-0-spikes.plan.md) records the exact versions
and the reasoning. Port the proven approach; do not re-spike it.

Things the spike results make normative, which are easy to lose in translation:

- `SupportsGettingNewToken = true` plus a `ClientName` and an `SsoVerificationCallback` (or PKCE).
  Without them the SDK refreshes but never starts interactive authorization, and a stale token
  fails instead of falling back to the browser.
- `--certificate-validation-policy=accept-untrusted` on the viewer, and **only** for the loopback
  tunnel endpoint. §9.2 requires this to be explicit and narrow. Do not apply it to arbitrary hosts.
- The connection file goes in an application-owned directory with a current-user-only ACL, is
  deleted after a bounded grace period, and startup sweeps only `ssm-connect-*.dcv` below that
  directory with a bounded age.

### Where the macOS side is worth copying, and where it is not

Copy the shape of the DCV and readiness adapters. Do not copy `AWSErrorInterpreter`: it exists
because `aws-sdk-swift` throws `Error`-only types that bridge to strings like "Smithy.ClientError
error 4", and the AWS SDK for .NET does not have that problem. Your `ErrorCategories.Classify` is
already the right design.

## Your task 2: close the conformance coverage gaps

This is the highest-value contract work left, and it is genuinely shared: a gap here is a place
where the two clients agree by inspection only.

The fixture set covers all ten required §6.2 case groups, but a lot of the *vocabulary* the schema
defines is never exercised:

| Surface | Exercised | Never exercised |
|---|---|---|
| `errorKind` | 4 of 13 | `signInRequired`, `invalidRegion`, `instanceTerminated`, `dcvServerNotReady`, `tunnelNotEstablished`, `agentUnreachable`, `viewerNotInstalled`, `awsServiceError`, `unknown` |
| `errorCategory` | 6 of 10 | `authentication`, `agent`, `aws`, `unknown` |
| `portName` | 10 of 11 | `EventSink` |
| `step.action` | 6 of 7 | `reconnect` |
| `event.kind` | 1 of 3 | `systemWake`, `applicationWillTerminate` (reachable as `when` steps, never as injected events) |

Some of those are less alarming than they look: `invalidRegion` and `instanceTerminated` never
appear as *injected* errors because the workflow raises them itself, and both categories are
asserted. The four that matter:

1. **`authentication` is never a terminal category.** Every expired-credentials fixture recovers and
   ends `connected`. Nothing pins what happens when re-authentication itself fails — which is the
   common real failure, and the one where the two clients are most likely to differ.
2. **`agent` is never a terminal category.** `connect-multi-user-agent-unauthorized` ends
   `connected` with a warning, by design (MU-00a: identity-only, no fallback, tunnel stays up).
   Nothing asserts a terminal agent failure.
3. **`agentUnreachable` is never injected**, so the retry-versus-propagate distinction — transport
   failure retries while the tunnel settles, a real agent response does not — is untested on both
   sides despite being explicitly designed for.
4. **`EventSink` has no coverage.** This one needs a decision, not just a fixture; see below.

Write these as new fixtures, run them against .NET, and expect to have to fix the .NET workflow
where they fail. A macOS agent then runs the same fixtures — that direction is cheap now that
`SSMConnectKit/Tests/SSMConnectKitTests/Conformance` exists.

### The `EventSink` question you should settle rather than inherit

`EventSink` is in §7 and in the schema's `portName` enum, and .NET implements it. Swift has no
equivalent: state is observed through `@Observable`, and the fixture runner uses a narrow
`stateObserver` closure added for exactly that purpose. So the port is real on one side and a
different shape on the other, and no fixture forces the issue.

Decide which it is and record it in §7:

- a genuine shared port, in which case Swift needs one and MR-05 should introduce it while removing
  `Observation` from the workflow; or
- a .NET implementation detail, in which case it comes out of the schema's `portName` enum and §7
  stops naming it.

The second is the smaller change, and it is defensible — §7's own wording says clipboard and
notifications are *shell services invoked in response to workflow events*, which is satisfied by
any observation mechanism. Do not just add an `EventSink` fixture; that would freeze an
inconsistency into the contract.

## Your task 3: close §15 question 2, the plugin redistribution licence

The last open question, and the last thing blocking a choice between bundling
`session-manager-plugin` and discovering a user installation. It is a licence read, not a test, and
it blocks Phase 5 packaging rather than Phase 4.

Note the asymmetry when you decide: macOS *bundles* the plugin (fetched and checksum-verified at
build time by `scripts/fetch-plugin.sh`, embedded in `Contents/Helpers/`, re-signed at Release).
If Windows discovers instead of bundling, the two clients get materially different first-run
experiences, and that is a product decision worth stating explicitly rather than falling out of a
licence footnote.

## Your task 4: Phase 5, packaging and release hardening

Phase 0 proved the mechanism end to end in a clean Sandbox. What remains is production hardening:

- WiX 6 per-user MSI, generated from the real payload rather than the spike payload.
- Authenticode-sign the MSI *and* the self-contained executable, then regenerate the WinGet manifest
  against the signed, immutable, publisher-hosted asset and its final SHA-256. Placeholder URLs and
  hashes in `spikes/windows/winget/` must not survive into a release.
- OV versus EV certificate: decide before the first general release. EV carries SmartScreen
  reputation immediately, OV earns it. This gates AC-09.
- WiX 7 stays rejected until someone accepts the OSMF EULA on the project's behalf. That is a
  project-owner decision, not an automation one.
- Measure trimming. The 24H2 TFM pin costs roughly 76 MB → 103 MB on the self-contained
  single-file publish; that was accepted knowingly, but it was never measured with trimming on.

## What is explicitly not yours

- **The rest of Phase 2** (MR-05, MR-07, MR-08). Swift target extraction and moving `Observation`
  out of the workflow. macOS work, on a macOS host. The one place it touches you is the `EventSink`
  decision above, which is why that is yours to settle and theirs to implement.
- **The macOS export/import UI.** The document codec is done and tested; the Settings menu item and
  file picker that call it are not. That is macOS UI work and does not affect interchange — do not
  wait on it, and do not assume a macOS agent has produced an exported file by hand yet.
- **Release signing on macOS.** Separate certificate, separate AC-09 half.

## Still open, and carried by an acceptance criterion rather than forgotten

- **Orphaned AWS-side sessions on abnormal exit** — AC-07 and §9.3. Job Object containment is proven
  *locally*; a hard-killed client has never been shown to terminate its SSM session server-side.
  Run the `tunnel` or `multi-user` probe, kill the owning process, and check whether the SSM and DCV
  sessions close or linger until timeout. If they linger, the client needs a reap-on-start path.
  AC-07 explicitly says local containment is not sufficient evidence on its own.
- **Logoff and suspend/resume** — AC-07 and §9.3. Cannot be automated from inside the session under
  test. Run manually, or in a VM that can drive the power state.
- **Windows baseline review on 2026-10-13** — §11.2. Windows 11 24H2 Home/Pro reaches end of updates
  then; the floor likely moves to 25H2 (build 26200).

## How to verify the whole repository

```bash
python3 contracts/validate.py            # schemas and fixtures as documents
dotnet test windows/SSMConnect.slnx      # 63 tests, includes all 28 fixtures
swift test --package-path SSMConnectKit  # 172 tests, includes the same 28 fixtures
```

The first two run anywhere with Python 3 and the .NET 10 SDK. The third needs macOS.

CI now runs all three: [`contracts.yml`](../../.github/workflows/contracts.yml),
[`windows-client.yml`](../../.github/workflows/windows-client.yml), and the newly added
[`macos-client.yml`](../../.github/workflows/macos-client.yml), which also builds the app bundle to
keep AC-10 honest.

**If you change a fixture, run all three.** That loop is now symmetric — it was not when you wrote
your handoff, and it is the main thing that got easier.

## Two notes on the macOS changes, in case they mislead you

- `SSMConnectKit` is now six Swift targets: `SSMConnectDomain`, `SSMConnectWorkflow`,
  `SSMConnectAWS`, `SSMConnectMacOS`, `SSMConnectUI`, and an umbrella `SSMConnectKit` that
  re-exports them and holds the composition root. The app shell was not touched.

  One result is worth carrying over to how you think about your own boundary, because it surprised
  me: **the target split enforces less than it looks like it does.** It makes `import AWSEC2` in the
  portable targets a build failure, because the AWS SDK is a package dependency they do not have.
  It does nothing about `import SwiftUI` or `import Darwin`, because platform SDK frameworks are
  importable by any target compiled on the platform regardless of `Package.swift`. I verified both
  by trying them. Since AC-02 names five Apple frameworks and no AWS ones, `PortableBoundaryTests`
  had to stay — it now scans the portable target directories instead of a file list.

  Your side does not have this hole: `SSMConnect.Domain` and `SSMConnect.Workflow` target plain
  `net10.0`, so a WPF or Win32 reference genuinely cannot compile there. That asymmetry is worth
  knowing when comparing the two clients' "enforced by the compiler" claims — yours is stronger.
- `ConnectionStateMachine` gained a `terminateProcess` seam. That is not gold-plating: the app-quit
  path calls `kill(2)` on a PID, and a fixture's synthetic `processIdentifier` would otherwise have
  signalled an unrelated live process on the developer's machine. Your Job Object equivalent has no
  such hazard, so do not mirror the seam for its own sake.
