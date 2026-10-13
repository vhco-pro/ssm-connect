<p align="center">
  <img src="img/bg-removed-1767172053004.png" alt="SSM Connect logo" width="180">
</p>

<h1 align="center">SSM Connect</h1>

<p align="center">
  One-click access to EC2 cloud workstations through AWS Systems Manager.
</p>

<p align="center">
  <a href="https://github.com/vhco-pro/ssm-connect/releases/latest"><img src="https://img.shields.io/github/v/release/vhco-pro/ssm-connect?display_name=tag&sort=semver" alt="Latest release"></a>
  <a href="https://github.com/vhco-pro/ssm-connect/actions/workflows/release.yml"><img src="https://github.com/vhco-pro/ssm-connect/actions/workflows/release.yml/badge.svg" alt="Release build"></a>
  <a href="https://github.com/vhco-pro/ssm-connect/actions/workflows/codeql.yml"><img src="https://github.com/vhco-pro/ssm-connect/actions/workflows/codeql.yml/badge.svg" alt="CodeQL"></a>
  <a href="LICENSE"><img src="https://img.shields.io/github/license/vhco-pro/ssm-connect" alt="Apache 2.0 license"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-000000?logo=apple" alt="macOS 14 or later">
</p>

**SSM Connect** is a working native macOS menu-bar app that automates the complete connection flow:
AWS SSO authentication, instance discovery and startup, SSM readiness checks, an encrypted
port-forwarding tunnel, and launching Amazon DCV Viewer. No manual terminal commands and no inbound
security-group rules are required.

It drives two kinds of host:

- a **single-user** box (vanilla `ec2-user` + a DCV password), and
- a **multi-user** box where each person lands in their **own isolated desktop**, authenticated by
  their **own AWS IAM Identity Center (SSO) identity** - no per-user passwords. The on-box half of
  that is the companion [`dcv-session-agent`](https://github.com/vhco-pro/dcv-session-agent).

Nothing is hardcoded. A connection is a **config-driven profile** (AWS account, SSO start URL,
SSO region, resource region, instance tag, connect mode, ports, and either a secret id or an agent
port), so the same app can drive **any** SSM-reachable EC2 workstation. On first launch you import
a profile from your `~/.aws/config`; you can keep multiple named profiles.

## The two connect modes

A profile's **connect mode** decides the path. Existing/legacy profiles default to **single-user**,
so nothing changes unless you opt in.

|  | **Single-user** (vanilla, default) | **Multi-user** |
|---|---|---|
| You log in as | the shared **`ec2-user`** | **your own** SSO identity (e.g. `dl6544-a`) |
| DCV session | the host's one **console** session | a **per-user virtual** session, created on demand |
| Authentication | a **DCV password** from Secrets Manager | a **presigned `sts:GetCallerIdentity`** identity token - **no password** |
| Isolation | everyone shares one desktop | each user gets their **own** desktop + home |
| Profile fields | `secretId` (the password secret) | `connectMode = multiUser`, `agentRemotePort` (default `8444`) |
| Extra AWS permission | `secretsmanager:GetSecretValue` | none - it proves *your own* identity |

### Dependencies per mode

**Single-user** needs:
- the workstation deployed in **vanilla/console** mode (`ec2-user`), and
- a **Secrets Manager** secret holding the `ec2-user` DCV password (its id goes in the profile).

**Multi-user** needs:
- the [`dcv-session-agent`](https://github.com/vhco-pro/dcv-session-agent) running on the host,
  listening on loopback `:8444`, and
- DCV configured for **virtual sessions + external token auth** (`create-session=false` +
  `auth-token-verifier`), which the agent's bootstrap sets up.
- No password, no broker, no web portal. The agent provisions your Linux user + virtual session on
  first connect.

> [!IMPORTANT]
> A multi-user host is **identity-only** - there is no `ec2-user`/shared fallback on it. Keep a
> separate single-user profile if you also have a vanilla box.

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

The app starts with **no profile** - nothing about any AWS environment is baked in.

1. Click the menu-bar icon → **Set Up a Workstation…** (opens Settings → Profiles).
2. Click **Import from `~/.aws/config`** and pick the profile for your workstation. The SSO start
   URL, SSO region, account, role, and resource region are filled in for you.
3. Set the **instance tag value** (e.g. `Name = my-workstation`) and pick the **Connect mode**:
   - **Single-user** → also set the **DCV password secret id**.
   - **Multi-user** → set the **agent port** (default `8444`); no secret needed.
4. **Save**, then **Connect**. With auto-connect enabled, it connects on launch/login from then on.

## About

Choose **About** in the menu for the installed version and build number, system
details, license, project and release-note links. Expand **Connection States** there for the
icon/color reference; the dropdown itself stays focused on the current connection and actions.

## Web Forwards

Enable **Web Forwards** in a profile to use internal web applications in the local browser,
independently of the DCV connection. Configure an optional SSH user (otherwise your mapped AWS
identity), a SOCKS port, dot-prefixed proxy suffixes and any named local forwards. Local forwards
with an open path appear as **Open** actions in the menu.

Under **Settings > Profiles > Edit > Web Forwards**, enable SOCKS and use **Add Domain** for
another suffix. Each row is editable and has a remove control. For example, `.internal.example.com`
routes its subdomains through the workstation. Empty or invalid domain rows prevent Save until
corrected or removed. Saved transport changes remain pending until **Apply Changes**; cancelling
does not replace the active tunnel or browser routing.

Choose a **Browser Mode**, then **Open Browser**. It starts web forwards when needed and opens
a blank browser only after SOCKS is ready, without starting DCV. **Separate Browser** retains
its own profile/logins per workstation and product. **Use My Browser** requires a selected Zen
profile folder, a closed browser and explicit proxy-setup confirmation. It keeps that profile's
logins in place without reading or importing them. **Restore Browser Settings** restores only
owned proxy values and refuses later user/extension/policy changes; close Zen first.

The verified preview matrix is Chrome **156.0.8078.12** (Separate Browser) and Zen **1.23.1b**
(both modes). Other versions/products are unavailable until verified. Chrome existing-profile
setup requires a separately approved extension and is not implemented. Shared Chromium/Firefox
backends do not automatically enable Edge/Firefox or untested forks.

**Advanced > Copy PAC URL / Reveal PAC File** remains available for manual browser setup.
Only configured suffixes use SOCKS with workstation-side DNS; public sites stay direct. Retained
routing keeps internal sites fail-closed while disconnected, including after SSM Connect quits.
No system proxy, certificate or corporate policy is changed. **Apply Browser Setup** explicitly
transfers a checked existing-profile proxy scope to another workstation; switching Settings
profiles alone does not overwrite its owner.

The host must support SSH key authorization through EC2 Instance Connect. The SSO role needs
`ec2-instance-connect:SendSSHPublicKey` and permission to start the `AWS-StartSSHSession` document.
The app generates a temporary key per attempt and deletes it on disconnect or quit. DCV Viewer
and AWS CLI are not needed for web forwards. Native UI, live HTTP/websocket, PAC and cleanup
checks have passed, and the earlier manual browser SSO flow is user-confirmed. Automated browser
bootstrap tests now cover Chrome/Zen selective DNS/routing, outage behavior, conditional restore,
native instance isolation/reuse, and the preview menu-to-SSH-to-browser path. SSO/session retention
in this new flow and a fresh-Mac-only-app setup remain human checks. The earlier working-day
observer recorded missing web listeners from 2026-10-13 03:42 UTC; it is not a working-day pass.

## Requirements

### Native VS Code

Enable **Remote Development** in the workstation profile, optionally set an absolute remote
folder, then choose **Open VS Code**. This uses your native Visual Studio Code and Microsoft's
Remote - SSH extension; VS Code owns its remote server, extensions, terminals and workspace UI.
SSM Connect supplies authenticated SSH-over-SSM channels and refreshes EC2 Instance Connect
authorization for every new SSH connection, including connections after the initial 60-second
key window. No public SSH ingress or DCV connection is required.

First setup asks before adding its owned Include to your SSH config. Existing SSH hosts remain
unchanged. **Restore Editor Setup** removes only a still-matching Include; **Stop Remote Access**
drops owned channels without closing VS Code or deleting remote code/server data. A missing
editor/Remote-SSH extension is a prerequisite error, not a silent install. Native setup/launch,
raw SSH commands across the authorization-expiry boundary and current server installation were
verified on the management VM. Folder open/save, IntelliSense, project test/debug and user
responsiveness remain acceptance checks in the opened native editor.

### Platform

- macOS 14 (Sonoma) or later, Apple Silicon
- [Amazon DCV Viewer](https://www.amazondcv.com) (for the default DCV connect action):
  `brew install --cask dcv-viewer`
- An AWS account reachable via IAM Identity Center (SSO), and an EC2 workstation registered with SSM
- Network access to AWS endpoints (directly or via VPN)

IAM permissions the app needs (whatever your SSO role provides): `ec2:DescribeInstances`,
`ec2:StartInstances`, `ec2:StopInstances`, `ssm:DescribeInstanceInformation`, `ssm:StartSession`,
`ssm:TerminateSession`. **Single-user** mode additionally needs `secretsmanager:GetSecretValue`;
**multi-user** mode needs nothing extra (it re-uses your own `sts:GetCallerIdentity`).

## How it works

Both modes share the front half (auth → discover → tunnel), then branch:

```mermaid
graph TD
    A["SSO login<br/>(aws-sdk-swift, ~/.aws/sso cache)"] --> B[Resolve instance by tag]
    B --> C{Instance stopped?}
    C -->|yes| D["StartInstances + wait running"]
    C -->|no| E
    D --> E[Wait for SSM Online]
    E --> F["Open SSM port-forward tunnel<br/>localhost:8443 → DCV"]
    F --> G{Connect mode}

    G -->|Single-user| H[Fetch DCV password<br/>from Secrets Manager]
    H --> I["Write .dcv: user=ec2-user + password<br/>(password also copied to clipboard)"]

    G -->|Multi-user| K["Resolve your identity:<br/>sts:GetCallerIdentity → Linux user"]
    K --> L["Open transient agent tunnel<br/>localhost:8444"]
    L --> M["POST /ensure-session<br/>(presigned-STS token, idempotent retry)"]
    M --> N["Agent provisions your user<br/>+ virtual session"]
    N --> O[Close agent tunnel]
    O --> P["Presign a fresh<br/>sts:GetCallerIdentity token"]
    P --> Q["Write .dcv: user + sessionId = you<br/>+ authToken - NO password"]

    I --> J[Launch DCV Viewer<br/>auto-login]
    Q --> J
    J --> R([Your desktop])
```

In multi-user mode the agent tunnel is **transient** - it's only needed for the one
`/ensure-session` call; DCV reaches its token verifier locally on the box, not through the client,
so the agent tunnel is torn down before the viewer launches. The `.dcv` file is short-lived (`0600`)
and deleted right after the viewer opens.

- **Auth, EC2, SSM, Secrets Manager, STS** use the native
  [`aws-sdk-swift`](https://github.com/awslabs/aws-sdk-swift). SSO tokens use the standard
  `~/.aws/sso/cache` (shared with the AWS CLI), so logins are reused and silently refreshed.
- **The tunnel** reuses the official AWS `session-manager-plugin` binary, bundled in the app behind a
  `TunnelProvider` protocol (the SDK only exposes `StartSession`; the port-forward data-channel
  protocol lives only in the plugin). The plugin is fetched + checksum-verified at build time.
- **The identity token** (multi-user) is a presigned `sts:GetCallerIdentity` request used as an
  opaque bearer token - the same credential the SSM tunnel already required. The agent proves your
  identity by re-executing it against STS. A fresh token is minted per attempt to avoid expiry.

Security: no secrets are written to UserDefaults or Keychain. DCV connection files and web-forward
SSH keys are temporary and cleaned up; private keys live in restricted temporary directories.
PAC files contain routing configuration, not credentials. No inbound security-group rules are
ever suggested - all traffic is outbound over the SSM tunnel.

## Development

The Xcode project is generated from `project.yml` via [XcodeGen](https://github.com/yonaskolb/XcodeGen)
(the generated `.xcodeproj` is gitignored - always regenerate).

```bash
brew install xcodegen
make run      # regenerate, build, launch the menu-bar app
make test     # run the Swift Testing suite
make rebuild  # clean build + launch
```

The first build downloads `session-manager-plugin` (pinned + SHA-256 verified) from AWS.

### Stability observation

The optional read-only observer requires Node.js 18 or later. With app-owned web forwards and
a real DCV Viewer session connected, supply the private HTTPS health endpoint and the profile's
ports:

```bash
source ~/.config/web-forwards/env
export WF_CHECK_URL
node scripts/observe-web-forwards.mjs --socks-port 1080 --local-port 4466 --dcv-port 8443
```

It writes a restricted JSONL log under `~/.web-forwards/observations/`, sampling HTTP status,
app-owned SSH and established Viewer streams every minute. Stop with Ctrl+C for a summary;
`--samples 1` performs a one-shot check. Sleep and sampling gaps are reported as missing coverage,
not a clean working-day result. Logs contain health data, not credentials or private target URLs.

### Releasing

```bash
./scripts/release.sh   # Release build -> dist/SSMConnect-<version>.zip + sha256
```

Upload the zip as the GitHub release asset. The Homebrew cask
(`vhco-pro/homebrew-tap` → `Casks/ssm-connect.rb`) **auto-syncs** to the latest release version +
sha256 via a scheduled workflow in that tap (no manual cask edit needed).

### Notarization (upgrade path)

The app is ad-hoc signed for personal/Homebrew distribution. To remove all Gatekeeper friction for
wider distribution, enroll in the Apple Developer Program, obtain a *Developer ID Application*
certificate, sign the app + plugin with `--options=runtime` (Hardened Runtime), then
`xcrun notarytool submit … --wait` and `xcrun stapler staple`. No code changes are required - only
the signing/release pipeline.

## License

[Apache License 2.0](LICENSE). The bundled `session-manager-plugin` is also Apache 2.0
([aws/session-manager-plugin](https://github.com/aws/session-manager-plugin)); its license is
included in the app bundle.
