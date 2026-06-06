# SSM Connect

> Config-driven macOS menu-bar app that gets you into your cloud workstation with one click.

**SSM Connect** is a native macOS (Swift / SwiftUI) menu-bar utility that automates the whole
"connect to an EC2 workstation over AWS SSM" dance: AWS SSO authentication, instance discovery by
tag, instance start + SSM-readiness wait, an SSM port-forward tunnel, secret retrieval from Secrets
Manager, and launching the viewer (Amazon DCV by default) — with **zero manual terminal commands**.

Nothing is hardcoded. A connection is a **config-driven profile** (AWS account, SSO start URL,
SSO region, resource region, instance tag, secret id, ports, viewer command), so the same app can
drive **any** SSM-reachable EC2 workstation. On first launch you import a profile from your
`~/.aws/config`; you can keep multiple named profiles.

## Install

```bash
brew install --cask vhco-pro/tap/ssm-connect
```

The app is **ad-hoc signed (not notarized)**, so on first launch macOS Gatekeeper will block it.
Approve it once with either:

```bash
xattr -dr com.apple.quarantine "/Applications/SSMConnect.app"
```

…or right-click **SSMConnect.app** in Finder → **Open**. Updates ship through `brew upgrade`.

## First launch

The app starts with **no profile** — nothing about any AWS environment is baked in.

1. Click the menu-bar icon → **Set Up a Workstation…** (opens Settings → Profiles).
2. Click **Import from `~/.aws/config`** and pick the profile for your workstation. The SSO start
   URL, SSO region, account, role, and resource region are filled in for you.
3. Fill the **instance tag value** (e.g. `Name = my-workstation`) and the **DCV password secret id**
   (config doesn't carry those), then **Save**.
4. Click **Connect**. With auto-connect enabled, it connects on launch/login from then on.

## Requirements

- macOS 14 (Sonoma) or later, Apple Silicon
- [Amazon DCV Viewer](https://www.amazondcv.com) (for the default DCV connect action):
  `brew install --cask dcv-viewer`
- An AWS account reachable via IAM Identity Center (SSO), and an EC2 workstation registered with SSM
- Network access to AWS endpoints (directly or via VPN)

The app needs these IAM permissions (whatever your SSO role provides): `ec2:DescribeInstances`,
`ec2:StartInstances`, `ec2:StopInstances`, `ssm:DescribeInstanceInformation`, `ssm:StartSession`,
`ssm:TerminateSession`, `secretsmanager:GetSecretValue`.

## How it works

```
SSO auth ──▶ resolve instance by tag ──▶ start if stopped ──▶ wait for SSM Online
        ──▶ open SSM port-forward tunnel ──▶ fetch secret ──▶ launch viewer (auto-login)
```

- **Auth, EC2, SSM, Secrets Manager** use the native [`aws-sdk-swift`](https://github.com/awslabs/aws-sdk-swift).
  SSO tokens use the standard `~/.aws/sso/cache` (shared with the AWS CLI), so logins are reused and
  silently refreshed.
- **The tunnel** reuses the official AWS `session-manager-plugin` binary, bundled in the app behind a
  `TunnelProvider` protocol (the SDK only exposes `StartSession`; the port-forward data-channel
  protocol lives only in the plugin). The plugin is fetched + checksum-verified at build time.
- **DCV auto-login** writes a short-lived `0600` `.dcv` connection file, opens DCV Viewer on it, then
  deletes it. The password is also copied to the clipboard for the in-VM desktop login.

Security: no secrets are written to UserDefaults or Keychain; the only disk touch is the transient
`.dcv` file. No inbound security-group rules are ever suggested — all traffic is outbound over the
SSM tunnel.

## Development

The Xcode project is generated from `project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(the generated `.xcodeproj` is gitignored — always regenerate).

```bash
brew install xcodegen
make run      # regenerate, build, launch the menu-bar app
make test     # run the Swift Testing suite
make rebuild  # clean build + launch
```

The first build downloads `session-manager-plugin` (pinned + SHA-256 verified) from AWS.

### Releasing

```bash
./scripts/release.sh   # Release build -> dist/SSMConnect-<version>.zip + sha256
```

Upload the zip as the GitHub release asset and update the cask
(`vhco-pro/homebrew-tap` → `Casks/ssm-connect.rb`) with the new version + sha256.

### Notarization (upgrade path)

v1 is ad-hoc signed for personal/Homebrew distribution. To remove all Gatekeeper friction for wider
distribution, enroll in the Apple Developer Program, obtain a *Developer ID Application* certificate,
sign the app + plugin with `--options=runtime` (Hardened Runtime), then
`xcrun notarytool submit … --wait` and `xcrun stapler staple`. No code changes are required — only
the signing/release pipeline.

## License

[Apache License 2.0](LICENSE). The bundled `session-manager-plugin` is also Apache 2.0
([aws/session-manager-plugin](https://github.com/aws/session-manager-plugin)); its license is
included in the app bundle.
