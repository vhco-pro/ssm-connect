# SSM Connect

> Config-driven macOS menu-bar app that gets you into your cloud workstation with one click.

**SSM Connect** is a native macOS (Swift / SwiftUI) menu-bar utility that automates the whole
"connect to an EC2 workstation over AWS SSM" dance: AWS SSO authentication, instance discovery by
tag, instance start + SSM-readiness wait, an SSM port-forward tunnel, secret retrieval from Secrets
Manager, and launching the viewer (Amazon DCV by default) — with **zero manual terminal commands**.

Nothing is hardcoded. The connection is a **config-driven profile** (AWS account, SSO start URL,
SSO region, resource region, instance tag, secret id, ports, viewer command), so the same app can
drive **any** SSM-reachable EC2 workstation. Ships with one default profile seeded from
`~/.aws/config`; supports multiple named profiles.

## Status

🟡 **Design phase.** The specification is complete and ready for the planning agent. No application
code exists yet.

- Spec: [`docs/specs/ssm-connect.spec.md`](docs/specs/ssm-connect.spec.md)

## Why

The manual flow today requires AWS CLI v2, `aws sso login`, resolving a (frequently-replaced)
instance ID, `aws ssm start-session` with the right port-forward document, copying a DCV password
out of Secrets Manager, and pointing DCV Viewer at `localhost`. SSM Connect collapses all of that
into a single menu-bar icon and an optional launch-at-login auto-connect.

## How it works (high level)

```
SSO auth ──▶ resolve instance by tag ──▶ start if stopped ──▶ wait for SSM Online
        ──▶ open SSM port-forward tunnel ──▶ fetch secret ──▶ launch viewer
```

- **Auth, EC2, SSM, Secrets Manager** use the native [`aws-sdk-swift`](https://github.com/awslabs/aws-sdk-swift)
  (spike-verified against `1.7.13`).
- **The tunnel** reuses the official AWS `session-manager-plugin` binary, bundled in the app, behind
  a `TunnelProvider` protocol (the SDK only exposes `StartSession`; the port-forward data-channel
  protocol lives only in the plugin).

See the spec for the full state machine, requirements, acceptance criteria, and ADRs.

## Key decisions (ADRs in the spec)

| Decision | Summary |
|----------|---------|
| Auth + tunnel | Native `aws-sdk-swift` for AWS APIs; bundle `session-manager-plugin` for the tunnel (ADR-1) |
| Stack | Swift / SwiftUI menu-bar app, min macOS 14 (ADR-2) |
| Distribution | Homebrew tap cask, ad-hoc/personal-team signing, no paid Apple account for v1 (ADR-4/6) |
| Config | Config-driven multi-profile model; single workstation = one default profile (ADR-5) |
| Plugin sourcing | Bundle the official AWS-signed plugin, verified by checksum at build time (ADR-7) |

## Requirements (runtime)

- macOS 14 (Sonoma) or later, Apple Silicon
- Amazon DCV Viewer (for the default DCV connect action)
- Network access to AWS endpoints (directly or via VPN)

## Development

| Tool | Version (spike-confirmed) |
|------|---------------------------|
| Swift | 6.3.2 |
| Xcode | 26.5 |
| macOS | 26.4 |
| session-manager-plugin | 1.2.814.0 |

## Spec-driven development

This project follows the team SDD loop (Spec Author → Planner → Implementer → Reviewer). The spec is
the source of truth; plans land in `docs/plans/`.

## License

TBD.
