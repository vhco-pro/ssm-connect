# Development harness

Drives the real `ConnectionWorkflow` against real AWS and real Windows, before any UI exists. The
specification requires one end-to-end connection from a harness before the WPF tray is written, so
that an adapter bug and a UI bug can never be mistaken for one another.

## Running it

The harness takes a **portable profile document** — the same format
[`contracts/connection-profile.schema.json`](../../../contracts/connection-profile.schema.json)
defines — so a real run also exercises the import half of AC-03.

```powershell
# Resolve the workstation without opening a tunnel. Start here.
dotnet run --project windows/tools/SSMConnect.DevHarness -- preflight <profile.json>

# Full connection, then disconnect and check for residue.
dotnet run --project windows/tools/SSMConnect.DevHarness -- connect <profile.json>

# Hold the connection open until Enter, for looking at the DCV session.
dotnet run --project windows/tools/SSMConnect.DevHarness -- connect <profile.json> --keep

# Does a hard-killed client leave its SSM session open server-side? (AC-07)
dotnet run --project windows/tools/SSMConnect.DevHarness -- orphan-check <profile.json>
```

A profile document for a real workstation contains a real AWS account ID, so **keep it outside the
repository**. Generate one from a `~/.aws/config` entry rather than writing it by hand.

## Sign-in is interactive by design

If the cached IAM Identity Center token has expired, the harness opens the browser and waits. That
is the required behavior, not a fault: without `SupportsGettingNewToken` and a verification callback
the SDK refreshes but never starts device authorization, so a stale token would fail outright
instead of recovering. It does mean a live run cannot be completed unattended — a person has to
approve the sign-in once, after which the cached token serves subsequent runs until it expires.

## What it prints, and what it never prints

State transitions, notifications, and log lines, so the sequence can be compared against the
conformance fixtures. It never prints credentials, tokens, presigned URLs, account IDs, or the DCV
password — the password event reports only its length. Point it at approved test infrastructure.

## `orphan-check` and AC-07

AC-07 says local process containment is not sufficient evidence on its own. The Job Object provably
reaps the plugin when the client dies, but that says nothing about the session AWS is holding.

`orphan-check` opens a real session, kills the plugin outright with no graceful teardown, waits, and
then asks AWS what state the session is in. If it reports anything other than `Terminated`, the
client needs to reap its own sessions on next start, and the harness cleans up the session it
created either way.
