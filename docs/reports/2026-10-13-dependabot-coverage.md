# Dependabot Coverage Follow-Up

- **Decision:** retain Dependabot; no Renovate installation or duplicate updater.
- **Evidence:** [coverage JSON](./2026-10-13-dependabot-coverage.json), 22 repositories,
  fetch/parse gaps `[]`, recorded public default-branch commits and per-repo write permissions.
- **Result:** 15 missing supported ecosystem/directory entries across eight repositories.
  Complete config drafts preserve existing scopes and have passed YAML structure validation.
- **Access correction (2026-10-13):** the original audit used the active CLI account
  `DL6544_engieco`, not the intended personal account `michielvha`. Its recorded per-repo
  permissions remain a historical snapshot, not a statement about the personal account.
  Fresh requests explicitly using `michielvha` verified active organization admin membership,
  `ADMIN` access to all 23 visible repositories, and `admin: true` / `push: true` on SSM Connect.
  The same 22 active repositories are in the audit; one additional private archived repository
  is outside the active updater scope. No active-repository visibility gap was found.
- **Publication:** not published. Personal-account permissions are sufficient; the previous
  read-only blocker was caused by using the wrong identity. Reviewed configuration changes
  and actual updater execution still need publication approval. No global account was switched.

## Drafts To Publish

| Repository | Missing Coverage | Complete Draft |
|---|---|---|
| [vhco-pro/stackweaver-helm](https://github.com/vhco-pro/stackweaver-helm) | Helm `/chart` | [config](./dependabot-drafts/vhco-pro--stackweaver-helm/dependabot.yml) |
| [vhco-pro/distil](https://github.com/vhco-pro/distil) | GitHub Actions `/` | [config](./dependabot-drafts/vhco-pro--distil/dependabot.yml) |
| [vhco-pro/stackgraph](https://github.com/vhco-pro/stackgraph) | Actions, Docker, Go `/` | [config](./dependabot-drafts/vhco-pro--stackgraph/dependabot.yml) |
| [vhco-pro/terraform-provider-garage](https://github.com/vhco-pro/terraform-provider-garage) | Actions, Go `/` | [config](./dependabot-drafts/vhco-pro--terraform-provider-garage/dependabot.yml) |
| [vhco-pro/stackweaver-operator](https://github.com/vhco-pro/stackweaver-operator) | Actions, Docker, Go `/` | [config](./dependabot-drafts/vhco-pro--stackweaver-operator/dependabot.yml) |
| [vhco-pro/homebrew-tap](https://github.com/vhco-pro/homebrew-tap) | Actions `/` | [config](./dependabot-drafts/vhco-pro--homebrew-tap/dependabot.yml) |
| [vhco-pro/postbode](https://github.com/vhco-pro/postbode) | Actions, Go `/` | [config](./dependabot-drafts/vhco-pro--postbode/dependabot.yml) |
| [vhco-pro/stackweaver-registry](https://github.com/vhco-pro/stackweaver-registry) | Actions, Go `/` | [config](./dependabot-drafts/vhco-pro--stackweaver-registry/dependabot.yml) |

Use each draft as the corresponding repo's `.github/dependabot.yml` in a reviewed PR. These are
weekly automated version-update PRs, not automerge. Minor/patch version updates are grouped;
majors remain separate. Keep existing security-update/alert settings and existing bot PRs.
After merge, verify a successful Dependabot run or actual update PR for every new entry; YAML
parsing alone cannot prove the updater resolved the repository's dependencies.

## Preserved Boundaries

Stackweaver satellite comments assign synchronized manifests to the source monorepo. Those
exclusions were retained rather than creating satellite PRs that synchronization overwrites.
Docs, examples and intentionally failing acceptance fixtures were excluded from automatic new
scopes. Existing configs were not narrowed, replaced or moved between bots.

Dependabot supports full-SHA Actions and updates readable same-line version comments. Initial
pinning and runner-retirement migrations are separate hardening work. Keep versioned action
identities; a SHA unrelated to a release can follow a newer commit rather than a stable release.

Arbitrary script constants/download URLs and Homebrew cask release synchronization are not
covered merely by an Actions/Docker entry. Retain the existing release-sync mechanism or use a
specific updater only where an actual unsupported pin requires it. The JSON lists candidate
script/cask surfaces for follow-up; it does not claim every listed script contains a version pin.

The source monorepo's own update health, security-update settings and any inactive/paused
Dependabot jobs are not verified by this manifest inventory. Review updater job evidence and
existing stalled PRs after publication. Nothing was merged, closed or pushed by this run.

Sources: [automatic version-update PRs](https://docs.github.com/en/code-security/dependabot/dependabot-version-updates/about-dependabot-version-updates),
[Actions updates](https://docs.github.com/en/code-security/dependabot/working-with-dependabot/keeping-your-actions-up-to-date-with-dependabot),
[supported ecosystems](https://docs.github.com/en/code-security/dependabot/ecosystems-supported-by-dependabot/supported-ecosystems-and-repositories).