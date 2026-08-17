# Portable contracts

These documents are the shared product contract between the macOS (Swift) and Windows (.NET)
clients, per section 6 of [`cross-platform-client.spec.md`](../docs/specs/cross-platform-client.spec.md).
The two clients share behavior, not a runtime binary. Everything that would otherwise drift —
the profile interchange format and the connection workflow's observable behavior — is pinned here.

```text
contracts/
  connection-profile.schema.json   portable profile document (specification 6.1)
  state-machine.schema.json        workflow conformance fixture format (specification 6.2)
  fixtures/profiles/               profile documents used by the workflow fixtures
  fixtures/workflows/              28 behavioral cases both implementations must satisfy
  validate.py                      document-level checks, run in CI
```

## Status

**Executed against .NET. Not yet executed against Swift.**

| Implementation | State |
|---|---|
| .NET (`windows/`) | All 28 fixtures pass, via `windows/tests/SSMConnect.Workflow.Tests`. |
| Swift (`SSMConnectKit/`) | Not yet run. No fixture runner exists. |

The fixtures were derived by reading the Swift implementation — principally
`ConnectionStateMachine.swift`, the models under `Models/`, and the existing test suite — on a
Windows host with no Swift toolchain, and the .NET workflow was then written to satisfy them.

That ordering matters when reading a disagreement. These fixtures describe **intended** behavior
that two implementations now agree on, but only one of those implementations is the shipping
product. Running them against Swift is the remaining half of AC-04, and until that happens a
mismatch is more likely to be a fixture error than a macOS bug.

Running them against .NET has already earned its keep: it caught three ordering errors in the
fixtures, all in the `expect.calls` ordering rather than in the behavior itself. The correct order
is now recorded, and the same class of mistake would otherwise have been discovered as a spurious
"macOS is wrong" failure later.

The remaining Phase 1 task, on a macOS machine:

1. Build a fixture runner against the existing Swift implementation.
2. Run all 28 cases and reconcile every disagreement, treating shipping macOS behavior as the
   reference — a mismatch means the fixture is wrong unless it exposes a genuine macOS bug.
3. Where a fixture changes, re-run the .NET suite, which must then be brought back into agreement.

`windows/tests/SSMConnect.Workflow.Tests` is a working reference for step 1: the fixture model, the
outcome-queue semantics, and the assertion rules are all implemented there.

## Deliberate tightenings

Two places where the schema is stricter than today's Swift code. Both are intentional, and both
need confirming during step 2 above, because either could make an existing profile fail to export.

| Field | Swift today | Schema here | Why |
|-------|-------------|-------------|-----|
| `accountId` | any non-empty string | `^[0-9]{12}$` | AWS account IDs are always 12 digits. Catching a typo at export beats an opaque SDK failure at connect. |
| `secretId` on a multi-user profile | unconstrained | must be `null` | A multi-user host is identity-only (specification MU-00a). A secret ID there indicates a mistaken expectation of a shared-password fallback. |

The region pattern is *not* a tightening: it is byte-for-byte the rule the AWS SDK's endpoint
resolver applies, kept identical on purpose so a bad region is rejected with an actionable message
instead of an opaque client error.

## Fixture format

Each fixture states the inputs, what each injected port returns, the calls the workflow must make,
the ordered states it emits, and its terminal result.

```jsonc
{
  "profile": { "$ref": "../profiles/single-user.json" },  // plus optional field overrides
  "given": { "ports": { "EC2Provider": { "resolveInstance": [ /* outcome queue */ ] } } },
  "when":  [ { "action": "connect" } ],
  "expect": { "states": [ /* ordered */ ], "calls": [ /* ordered subset */ ], "terminal": { } }
}
```

Three details carry most of the design intent:

- **Outcomes are queues.** Each entry is consumed by one call, and the last entry repeats. That is
  how a case expresses "fails once, then succeeds" without any scripting.
- **Errors are portable kinds, not platform types.** A fixture says `expiredCredentials`, never
  `Smithy.ClientError`. Each implementation maps the kind onto its own error type.
- **Terminal failures assert a category, not a message.** AC-04 requires both clients to agree on
  ordered states and terminal error *categories*. Message wording is allowed to differ, so
  asserting it verbatim would encode a false requirement. `errorMessageContains` exists for the
  rare case where the specification fixes user-facing text, such as naming the offending field.

`harness` overrides retry counts, backoff, and stage timeouts so fixtures run fast and identically
on both platforms rather than depending on wall-clock behavior.

## Coverage

All ten required case groups from specification section 6.2 are covered:

| Required case | Fixtures |
|---|---|
| Reused SSO session and device login | `connect-reused-sso-session`, `connect-device-login` |
| Running, stopped, pending, stopping, terminated instances | `connect-reused-sso-session`, `connect-starts-stopped-instance`, `connect-starts-pending-instance`, `connect-starts-stopping-instance`, `connect-terminated-instance-fails`, `connect-shutting-down-instance-fails` |
| SSM readiness timeout and successful recovery | `ssm-readiness-timeout-fails`, `ssm-readiness-recovers` |
| Tunnel startup, local-port collision, unexpected drop, bounded reconnect | `connect-reused-sso-session`, `tunnel-local-port-collision-fails`, `tunnel-drop-auto-reconnects`, `tunnel-drop-reconnect-exhausted`, `tunnel-drop-without-auto-reconnect` |
| Single-user secret retrieval and DCV launch | `connect-reused-sso-session` |
| Multi-user identity, agent provisioning, token refresh, DCV launch | `connect-multi-user`, `connect-multi-user-agent-unauthorized` |
| Expired credentials during each AWS stage | `expired-credentials-during-resolve`, `expired-credentials-during-ssm`, `expired-credentials-during-start-session`, `expired-credentials-during-secret-fetch` |
| Disconnect and stop-workstation cancellation | `disconnect-cancels-in-flight-connect`, `stop-workstation-tears-down-and-stops` |
| Application shutdown while a tunnel is active | `application-shutdown-with-active-tunnel` |
| Workstation instance replacement | `instance-replacement-resets-stale-tunnel-state` |

Beyond the required set, because Phase 0 or a shipped bug fix made them worth pinning:
`connect-invalid-region-fails-preflight`, `readiness-miss-re-establishes-then-connects`,
`readiness-miss-exhausts-attempts`, `system-wake-reconnects-a-dead-tunnel`,
`launch-does-not-auto-connect-unconfigured-profile`.

### Known gaps

- **Warning-path assertions are coarse.** `warningPresent` is a boolean. A case where the viewer is
  missing and a case where the secret fetch fails both keep the tunnel up with a warning, and no
  fixture currently distinguishes them.

## Running the checks

```bash
python3 -m pip install jsonschema
python3 contracts/validate.py
```

`validate.py` checks that every document parses with no duplicate keys, that both schemas are valid
JSON Schema 2020-12, that every fixture validates, that profile references resolve, that IDs are
unique and match filenames, and that nothing resembling real credential material has crept in.
CI runs it on any change under `contracts/` via
[`.github/workflows/contracts.yml`](../.github/workflows/contracts.yml).

Fixtures MUST contain synthetic identifiers only. The account ID `000000000000` and the
`i-0aaaaaaaaaaaaaaa1`-style instance IDs are placeholders; `validate.py` fails the build on anything
that looks like a real account ID, access key, ARN, or presigned URL signature.
