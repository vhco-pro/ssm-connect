# VHCO GitHub Actions and Update Automation Audit

- **Measured:** 2026-10-13; public default-branch snapshots, not the local feature worktree.
- **Scope:** every repository returned by the authenticated `vhco-pro` org inventory.
- **Artifact:** [2026-10-13-vhco-actions.json](./2026-10-13-vhco-actions.json), including exact
  commit/file links, action references, configuration contents and observed bot PRs.
- **Coverage:** 22 repositories, 81 workflow/action/config files, parsed YAML; fetch/parse gaps
  are recorded in the artifact. Bot activity is the newest 300 issues/PRs per repository, not
  complete historical absence. Transitive workflow expansion is not part of this inventory.
- **Installation gate:** org app-installation API returned a permission-limited 404 and requested
  `admin:org`; installed Renovate state cannot be proven with this token. No org settings/apps,
  issues, branches, PRs or existing bot PRs were changed.

## Answer

There is existing Dependabot automation, including GitHub Actions in the local repository.
There is no Renovate config or Renovate PR evidence in the measured repositories/activity window.
That establishes no observed active Renovate coverage, not that the app is definitely uninstalled.
See [org app settings](https://github.com/organizations/vhco-pro/settings/installations) to verify.

[SSM Connect PR #24](https://github.com/vhco-pro/ssm-connect/pull/24) is an open Dependabot Actions
group update. It was created 2026-08-10; it has not been merged/closed by this investigation.
Dependabot can update already SHA-pinned Actions, but its presence is not proof all refs are
pinned/current, every repository is covered, or runner retirement is monitored.

## Repository Coverage

The final generated table is appended from the parsed artifact below. A zero unpinned count is
not a latest-version verdict; a repository with no Actions/configuration is not automatically a
healthy dependency-maintenance setup. Default-branch state is distinct from local CodeQL edits.

<!-- coverage-table -->

| Repository | Dependabot Config | Recent Bot Evidence | Mutable Refs |
|---|---|---|---|
| [vhco-pro/stackweaver-api](https://github.com/vhco-pro/stackweaver-api) | [config](https://github.com/vhco-pro/stackweaver-api/blob/e2cdb5bf27decedc9189f75c788be740854305c2/.github/dependabot.yml) | [PR #195](https://github.com/vhco-pro/stackweaver-api/pull/195) | 0 |
| [vhco-pro/stackweaver-frontend](https://github.com/vhco-pro/stackweaver-frontend) | [config](https://github.com/vhco-pro/stackweaver-frontend/blob/b354a1d8e724b84ecc59071f0f2262946bd728cf/.github/dependabot.yml) | [PR #177](https://github.com/vhco-pro/stackweaver-frontend/pull/177) | 0 |
| [vhco-pro/stackweaver-orchestrator](https://github.com/vhco-pro/stackweaver-orchestrator) | [config](https://github.com/vhco-pro/stackweaver-orchestrator/blob/50e87477ef421303f687ae04ceb6b37bc1a42524/.github/dependabot.yml) | [PR #125](https://github.com/vhco-pro/stackweaver-orchestrator/pull/125) | 0 |
| [vhco-pro/stackweaver-zitadel-init](https://github.com/vhco-pro/stackweaver-zitadel-init) | [config](https://github.com/vhco-pro/stackweaver-zitadel-init/blob/25c36f34323e9a9f9f89a21c4df64cb0f2fcb419/.github/dependabot.yml) | [PR #36](https://github.com/vhco-pro/stackweaver-zitadel-init/pull/36) | 0 |
| [vhco-pro/stackweaver-ansible-runner](https://github.com/vhco-pro/stackweaver-ansible-runner) | [config](https://github.com/vhco-pro/stackweaver-ansible-runner/blob/907e8912c8b4ab40abd887f903bf3557dc1e025f/.github/dependabot.yml) | [PR #122](https://github.com/vhco-pro/stackweaver-ansible-runner/pull/122) | 0 |
| [vhco-pro/stackweaver-helm](https://github.com/vhco-pro/stackweaver-helm) | [config](https://github.com/vhco-pro/stackweaver-helm/blob/96e0a5a2ea0dcfd0cdbffedae32dbb0bca9c504e/.github/dependabot.yml) | [PR #50](https://github.com/vhco-pro/stackweaver-helm/pull/50) | 0 |
| [vhco-pro/distil](https://github.com/vhco-pro/distil) | None | No recent bot PR observed | 0 |
| [vhco-pro/stackgraph](https://github.com/vhco-pro/stackgraph) | None | No recent bot PR observed | 11 |
| [vhco-pro/terraform-provider-garage](https://github.com/vhco-pro/terraform-provider-garage) | None | No recent bot PR observed | 10 |
| [vhco-pro/stackweaver-operator](https://github.com/vhco-pro/stackweaver-operator) | None | No recent bot PR observed | 6 |
| [vhco-pro/.github](https://github.com/vhco-pro/.github) | [config](https://github.com/vhco-pro/.github/blob/10809272482a988fd95b1d72dca885764e7f4e41/.github/dependabot.yml) | [PR #12](https://github.com/vhco-pro/.github/pull/12) | 0 |
| [vhco-pro/homebrew-tap](https://github.com/vhco-pro/homebrew-tap) | None | No recent bot PR observed | 0 |
| [vhco-pro/ssm-connect](https://github.com/vhco-pro/ssm-connect) | [config](https://github.com/vhco-pro/ssm-connect/blob/2aa079d216fecf72d8bd6cae5ef8b758b4ce4acf/.github/dependabot.yml) | [PR #24](https://github.com/vhco-pro/ssm-connect/pull/24) | 5 |
| [vhco-pro/dcv-session-agent](https://github.com/vhco-pro/dcv-session-agent) | [config](https://github.com/vhco-pro/dcv-session-agent/blob/d0a72e0349424c9f2a8a773d113947706ac8c1f4/.github/dependabot.yml) | [PR #1](https://github.com/vhco-pro/dcv-session-agent/pull/1) | 3 |
| [vhco-pro/swift-release-action](https://github.com/vhco-pro/swift-release-action) | [config](https://github.com/vhco-pro/swift-release-action/blob/11f15d5bf0546c7d0899e4ac5f56c5ea8680bf70/.github/dependabot.yml) | [PR #3](https://github.com/vhco-pro/swift-release-action/pull/3) | 2 |
| [vhco-pro/claude-companion](https://github.com/vhco-pro/claude-companion) | [config](https://github.com/vhco-pro/claude-companion/blob/db11a2a2db50263eb99e45e59dc7072c81fd5529/.github/dependabot.yml) | [PR #18](https://github.com/vhco-pro/claude-companion/pull/18) | 3 |
| [vhco-pro/builders](https://github.com/vhco-pro/builders) | None | No recent bot PR observed | 0 |
| [vhco-pro/postbode](https://github.com/vhco-pro/postbode) | None | No recent bot PR observed | 5 |
| [vhco-pro/terraform-provider-stackweaver](https://github.com/vhco-pro/terraform-provider-stackweaver) | [config](https://github.com/vhco-pro/terraform-provider-stackweaver/blob/2d97f4b3b5f0e47d774993909807a69b85b06473/.github/dependabot.yml) | [PR #19](https://github.com/vhco-pro/terraform-provider-stackweaver/pull/19) | 8 |
| [vhco-pro/stackweaver-opentofu-runner](https://github.com/vhco-pro/stackweaver-opentofu-runner) | [config](https://github.com/vhco-pro/stackweaver-opentofu-runner/blob/fb672019c6804d48bef7b79f09e682556a73acfc/.github/dependabot.yml) | No recent bot PR observed | 0 |
| [vhco-pro/stackweaver-secrets-init](https://github.com/vhco-pro/stackweaver-secrets-init) | [config](https://github.com/vhco-pro/stackweaver-secrets-init/blob/768630dc1670c9b565a75668053d163016c991d8/.github/dependabot.yml) | [PR #10](https://github.com/vhco-pro/stackweaver-secrets-init/pull/10) | 0 |
| [vhco-pro/stackweaver-registry](https://github.com/vhco-pro/stackweaver-registry) | None | No recent bot PR observed | 11 |

Measured summary: 14 repositories configure Dependabot's GitHub Actions ecosystem; 64 of 214
direct action/reusable-workflow references remain mutable across ten repositories, as enumerated
above. No Renovate evidence was observed in the measured window. Fetch/parse gaps: `[]`.

## Dependabot-Only Decision

The user chose to retain Dependabot on 2026-10-13. No Renovate installation or migration is
required for automated dependency-update PRs in the supported ecosystems. Dependabot already
updates GitHub Actions tags and full commit SHAs, including same-line version comments.
Keep full SHA pins and readable version comments; pinning a mutable ref initially is a separate
hardening action, not evidence that an additional updater is required.

The follow-up [manifest coverage artifact](./2026-10-13-dependabot-coverage.json) records all 22
repositories, preserved exclusions and 15 missing ecosystem/directory entries. Eight complete
config drafts are staged under [dependabot-drafts](./dependabot-drafts/). They preserve existing
settings, exclude docs/test fixtures and leave Stackweaver synchronized manifests owned by the
source monorepo. YAML structure is validated; the drafts are not published.

Enable weekly version-update PRs for each applicable manifest directory. Group minor/patch
version updates, keep majors separate, retain existing security-update/alert ownership and do
not auto-merge as part of this setup. Confirm real Dependabot run/PR evidence after each config
lands. Public visibility does not make configuration automatic or grant this token write rights.
Every measured repository currently reports `push: false`; publication requires the user's
repository-writable identity. No existing bot PR was merged or closed.

Use a separate runner-retirement/pinning audit for runner labels, bespoke version constants,
download scripts and Homebrew release synchronization. Dependabot's supported manifest updates
do not imply universal parsing of arbitrary shell variables. Consider another updater only for
a concrete unsupported requirement, not as a duplicate replacement for working Dependabot.

Sources: [version-update PRs](https://docs.github.com/en/code-security/dependabot/dependabot-version-updates/about-dependabot-version-updates),
[Actions updates](https://docs.github.com/en/code-security/dependabot/working-with-dependabot/keeping-your-actions-up-to-date-with-dependabot),
[supported ecosystems](https://docs.github.com/en/code-security/dependabot/ecosystems-supported-by-dependabot/supported-ecosystems-and-repositories).

## Local CodeQL Change

Only the local [CodeQL workflow](../../.github/workflows/codeql.yml) was changed:

- `macos-14` -> `macos-26`, matching the existing release workflow/platform.
- checkout -> [v7.0.1](https://github.com/actions/checkout/releases/tag/v7.0.1),
  `3d3c42e5aac5ba805825da76410c181273ba90b1`.
- cache -> [v6.1.0](https://github.com/actions/cache/releases/tag/v6.1.0),
  `55cc8345863c7cc4c66a329aec7e433d2d1c52a9`.
- CodeQL init/autobuild/analyze -> [v4.38.3](https://github.com/github/codeql-action/releases/tag/v4.38.3),
  annotated tag peeled to `24c54180a607b1449ed407dd24f251e4e9147c8d`.
- Xcode discovery uses `find` instead of parsing `ls`; clean unsigned Swift tracing remains.

Release-date ordering is insufficient: cache has a later-published v5 maintenance release;
the CodeQL repo also publishes `codeql-bundle-*` releases. Semver action tags and peeled commit
identities were checked separately. Cache v6.1.0 still uses Node 24 and retains the configured
path/key/restore-key inputs. Hosted-runner execution remains a required CI gate.

[Official retirement notice](https://github.com/actions/runner-images/issues/13518): macOS 14
deprecation began July 6, 2026, with full retirement November 2, 2026. The
[current runner table](https://github.com/actions/runner-images#available-images) identifies
`macos-26` as ARM64. Runner build platform and the app's macOS 14 deployment minimum are different;
the application minimum was not changed.

## Verification and Next Actions

- YAML parsing/contracts passed: five full-SHA action refs, `macos-26`, clean Swift build retained.
- Actionlint 1.7.12 passed after the scoped Xcode-selector correction.
- Dependabot-only coverage drafts passed YAML structure validation; they are staged, not enabled on GitHub.
- Official release refs/manifests were read; no release, remote workflow dispatch or merge occurred.
- Local release workflow refs remain outside this CodeQL change and are listed in the artifact.
  SSM Connect's default-branch unpinned count includes both release and CodeQL workflows.
- A real Actions CodeQL run on macOS 26 is not yet observed; local lint is not a CodeQL analysis.

| Next | Link | Gate |
|---|---|---|
| Review the pending local CodeQL diff, publish through a reviewed PR and run CodeQL | [SSM Connect Actions](https://github.com/vhco-pro/ssm-connect/actions/workflows/codeql.yml) | A credential with repository write rights; no push attempted. |
| Publish the staged Dependabot coverage configs and verify update jobs/PRs | [Coverage artifact](./2026-10-13-dependabot-coverage.json) | Repository write rights; every measured repo is read-only for this token. |
| Preserve shared workflow/pinning policy and synchronized dependency ownership | [vhco-pro/.github](https://github.com/vhco-pro/.github) | Reviewed changes; no duplicate updater. |
| Review existing Dependabot proposals rather than duplicating/closing them | [SSM Connect PR #24](https://github.com/vhco-pro/ssm-connect/pull/24) | Human/bot-PR review; nothing merged or closed. |