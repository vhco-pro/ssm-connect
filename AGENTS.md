# Repository instructions

Read the engineering conventions at
https://github.com/vhco-pro/docs/blob/d8f07c9dd69038375a535af8ad586086688f85ab/AGENTS.md
and follow the task routes there before implementation.

For code, read `conventions/coding.md` at that revision. For feature work, read
`conventions/feature-documents.md`. For CI and releases, also read
`conventions/delivery.md` and `knowledge/shared-delivery.md`.
Load only the relevant pages. If they cannot be retrieved, report that and stop.
Preserve local instructions and report conflicts.

## Feature workflow

Feature documents: docs/specs/

Use vh-adlc for specification, acceptance, tasks, implementation, review and
shipping. Each new or revised feature has one document containing its spec and
plan. The old separate plans and reviewer summaries are retained in Git history,
not as an active workflow. Do not recreate `docs/plans/` or `summaries/` as a
second task store.
Migrate historical specs when they are actively revised, not in an unrelated
repository-wide conversion.

The shared-core migration is specified in
[cross-platform-client.spec.md](docs/specs/cross-platform-client.spec.md).
Its draft status is not permission to implement. Preserve existing macOS
behavior and distinguish portable checks from native platform acceptance.

## Commands and constraints

- The package test command is `swift test --package-path SSMConnectKit`.
- `make test` calls `scripts/run.sh`, which currently terminates a running app
  before checking its test mode. Use the package command directly for
  non-disruptive validation.
- `make generate` runs XcodeGen. `make run` and `make rebuild` build and launch
  the app; do not use them as non-disruptive validation commands.
- Do not install, launch, replace or restart an application, or run live AWS,
  browser or editor scenarios, without the selected task's authority.
- Do not treat successful cross-compilation as Windows or Linux runtime proof.
