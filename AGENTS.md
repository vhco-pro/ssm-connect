# Repository instructions

Read the engineering conventions at
https://github.com/vhco-pro/docs/blob/0c983f6793bfe35eb96ae95ad0c361c6200af44f/AGENTS.md
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
Implement it only while it is accepted (`planned` or `in-progress`). Preserve
existing macOS behavior and distinguish portable checks from native platform
acceptance. The spec names two exceptions, both from its own AWS client: AWS
retry settings (environment variables and shared config) and configured AWS
endpoints no longer affect SSM Connect.

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
