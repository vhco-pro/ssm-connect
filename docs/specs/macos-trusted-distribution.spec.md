# SPECIFICATION: Developer ID Signing and Notarized macOS Distribution

- **Status:** direction requested by the owner on 2026-10-16; implementation is not started.
  The owner is arranging organization enrollment. No usable Developer ID Application identity
  was found on the development Mac during the read-only prerequisite check.
- **Baseline:** released macOS v0.6.0, main `b6956ee0b66f0ae50a6a392df1850a2cef6b8e73`.
  Its signatures are ad hoc and it is not notarized.
- **Outcome:** downloaded and Homebrew-installed releases identify the verified business publisher
  and pass normal macOS distribution assessment without users stripping quarantine attributes.
- **Related:** [client distribution](./ssm-connect.spec.md#63-distribution--signing),
  [workspace continuity](./remote-vscode.spec.md#16-upgrade-and-relaunch-workspace-continuity-2026-10-16).
- **Scope:** direct distribution through the existing GitHub Releases and Homebrew cask.
  No Mac App Store submission, Enterprise Program, sandbox rewrite, new updater or Windows signing.

## 1. Enrollment and Billing Prerequisites

Use the standard Apple Developer Program enrolled as an **organization**, under the business's
verified legal entity. The account holder needs an Apple Account with two-factor authentication,
authority to bind the organization, and its D-U-N-S number. The developer Apple Account may differ
from the Mac's iCloud account; changing the Mac's personal iCloud login is not a prerequisite.

Apple lists membership at USD 99 annually, with local-currency pricing and applicable tax shown
during enrollment. Developer ID signing/notarization requires active program access; the USD 299
Enterprise Program is not required. No separate per-app or per-notarization purchase is planned.
The D-U-N-S identifier is separate from the VAT number and can be requested without a fee.

Before paying, the owner must confirm the exact legal billing name/address, VAT details, local
price and tax treatment with Apple. An emailed order confirmation is not assumed to be the VAT
invoice. Apple documents invoices through the Apple Online Store account, or Developer Support
for purchases processed through its credit-card form. Do not promise reverse-charge treatment.

Enrollment, identity verification, agreements, payment and 2FA are human actions. Never request
passwords, 2FA codes, private keys or certificate-export passwords in chat or repository content.
Record readiness as pending until the actual organization team and signing/notarization access
exist; a normal Apple Account or an enrollment application is not signing readiness.

## 2. Stable Application and Publisher Identity

Retain `pro.vhco.ssm-connect`, native preferences, local profile UUIDs and existing remote SSH
authorities. Changing from ad-hoc to Developer ID signing must not deliberately create another
workstation profile, erase settings or reset editor/agent data.

The released application and its executable helpers must use the intended organization's
Developer ID Application identity. Pin the expected Team ID and application identifier in
verification. A usable identity must include its private key and trusted certificate chain;
an unrelated Apple Development or App Store distribution identity is not a substitute.

Keep the deployment target and supported architecture honest across every executable. The
current AWS plugin and proxy distribution target is ARM64. An x86_64 slice on the outer app
alone is not Intel support. Signing does not authorize advertising a new platform/runtime.

Preserve required AWS and YAML notices. Re-signing the embedded AWS executable does not change
its pinned download/checksum provenance or license obligations.

## 3. Credentials and CI Boundary

### 3.1 Provisioning

An authorized team member creates the Developer ID Application signing identity. Provision the
certificate and private key as a password-protected PKCS#12 export through a secure local flow.
Provision a dedicated App Store Connect API key accepted by `notarytool`, with the least role
that permits the required notarization operations. Verify the key type and authentication against
the actual enrolled team; key/issuer IDs or an untested key file alone do not establish access.

Proposed release-environment inputs:

| Input | Handling |
| --- | --- |
| Signing identity `.p12` | Encrypted GitHub environment secret, transported as Base64 only for serialization; Base64 is not encryption. |
| `.p12` password | Separate environment secret. |
| Notarization API private key `.p8` | Separate environment secret, restricted to the release job. |
| API Key ID and applicable Issuer ID | Explicit notarization authentication inputs; no Apple Account password/2FA in CI. |
| Expected Team ID and bundle ID | Non-secret verification configuration; never infer the intended team from the first available certificate. |

Credential upload/export requires an explicit owner-approved secure path. Never put credential
contents in shell history, process arguments where avoidable, debug output, build artifacts,
caches, release notes or pull-request comments. Do not expose secrets to agents for inspection.

### 3.2 Trusted Job

Only the trusted macOS release job on the accepted default-branch commit may access signing
credentials. Use a dedicated release environment with scoped access and owner-agreed deployment
rules. Untrusted/fork pull-request builds and dependency scripts must not receive these secrets.
Do not introduce `pull_request_target` checkout of untrusted code or expand organization settings.

Import the identity into a temporary keychain on the ephemeral GitHub-hosted runner. Keep private
key/keychain files owner-restricted, unlock only for the bounded job and restrict key access to
the necessary Apple signing tools. Restore the runner's keychain configuration and remove the
temporary keychain, key exports and notarization credentials in an unconditional cleanup step.
Do not cache signed build products or credentials across identities/teams.

Local Debug/developer builds may remain explicitly ad hoc. A trusted release that lacks valid
credentials must fail before publication; it must not silently fall back to ad-hoc output.

## 4. Release Artifact Sequence

1. Build the exact accepted version/commit with locked dependencies and verified AWS plugin.
   Apply version/build metadata before signing.
2. Enable Hardened Runtime and secure timestamps for the distributed application and appropriate
   executable helpers. Sign nested code from the inside out, then sign the final outer app.
   Enumerate embedded code deliberately; `--deep` verification is not a substitute for correct
   per-component signing. No bundle mutation is allowed afterward except supported stapling.
3. Start with the minimum required entitlements. Do not add disable-library-validation,
   unsigned-executable-memory, debug/task access or other broad exceptions speculatively.
   If a dependency requires an exception, prove the failure and scope it to the affected binary
   with a reviewed reason and regression evidence. Hardened Runtime is not App Sandbox.
4. Verify the outer app and each executable's certificate chain, expected Team ID, identifiers,
   timestamp, architecture, Hardened Runtime and effective entitlements.
5. Package a temporary submission ZIP and submit with `xcrun notarytool`; retain the submission ID.
   Wait or query with bounded timeouts. Require Apple's explicit **Accepted** status. Invalid,
   rejected, unreachable, timed-out or unparsable results are failures, never approval.
6. On failure, collect the notarization diagnostics in restricted artifacts with useful,
   credential-free errors. A retry resumes or rechecks the same known submission when appropriate;
   it must not loop indefinitely or publish before acceptance.
7. Staple the ticket to `SSMConnect.app`, validate the staple and run normal Gatekeeper assessment.
   A ZIP cannot itself be stapled. Recreate the final distribution ZIP from the stapled app.
8. Download/unpack or round-trip that exact final ZIP and verify it again. Compute the release
   SHA-256 **after stapling and final packaging**. A pre-notarization ZIP/checksum is not the
   release artifact.
9. Publish only the verified final ZIP through the existing version/release workflow. Retain the
   submission ID, commit/tag/version, publisher Team ID and artifact digest as non-secret evidence.
   Homebrew must consume that same final version/digest.
10. Update README/cask guidance only after the signed, accepted, stapled asset is actually public.
    Normal installation must not run `xattr -dr`, disable Gatekeeper or require another manual
    security bypass. macOS may still show its ordinary downloaded-app confirmation or enterprise
    policy messages; do not promise that all operating-system prompts disappear.

## 5. Failure, Retry and Rotation

Signing/notarization failures leave the last good published release and Homebrew digest intact.
The existing workflow creates its version tag before building; implementation must explicitly
support recovery from a failed tagged attempt without moving a published tag or disguising
another source commit as the same release.

Do not replace an already-published ZIP/checksum in place. If an ad-hoc version was previously
released, its first trusted-signed replacement must use a new version. Concurrent/manual retries
must not race to publish conflicting assets.

Track certificate/API-key expiry, rotation and revocation without logging private material.
For routine same-team rotation, verify existing profile/SSH/workspace identity is unchanged.
A Team ID change is a separately reviewed migration, not a routine certificate replacement.
If credentials are suspected compromised, stop release access and escalate rather than copying
keys into another environment or continuing with an untrusted identity.

## 6. Acceptance Criteria

| ID | Scenario | Required evidence |
| --- | --- | --- |
| SIGN-01 | Organization readiness | Active membership, verified legal publisher/team and usable Developer ID signing/notarization access; billing/invoice prerequisites confirmed by the owner. No private credential evidence is committed. |
| SIGN-02 | Exact release bundle and helpers | Automated checks confirm the expected Team ID/identifiers, secure timestamps, Hardened Runtime, architecture and minimal effective entitlements on all distributed code. |
| SIGN-03 | Accepted submission | Recorded Apple submission ID and explicit Accepted status for the submitted artifact; a successful HTTP upload alone fails this criterion. |
| SIGN-04 | Final stapled distribution | Staple validation and Gatekeeper assessment pass on the final unpacked ZIP; its published SHA-256 is computed after stapling and matches Homebrew. |
| SIGN-05 | Fresh-user/download launch | On an approved clean Mac/user, normal quarantined download and Homebrew install launch without stripping quarantine or an unverified-developer/malware-verification bypass. Ordinary first-download confirmation is distinguished from failure. |
| SIGN-06 | Hardened app functionality | Controlled native SSO, new SSH/EIC/SSM channel, browser/editor launch, DCV and helper cleanup pass with the signed build; old ad-hoc test evidence is not substituted. Existing unapproved sessions are not disturbed for testing. |
| SIGN-07 | Missing/wrong/expired/rejected credentials or submission | Deterministic failure tests block publication and cask advancement, preserve the last good release and provide actionable redacted diagnostics. No ad-hoc fallback. |
| SIGN-08 | CI isolation and cleanup | Untrusted PRs cannot obtain release secrets; successful, failed and cancelled jobs remove temporary keychains/key files and avoid caching/logging credentials. |
| SIGN-09 | Upgrade from v0.6.0 and routine certificate rotation | App/profile/SSH identity and host-key trust are preserved. The original workspace remains reconnectable under the separate upgrade-continuity contract; signing alone does not claim uninterrupted agents or lease continuation. |
| SIGN-10 | Failed tagged run and concurrent retry | Tests prove safe resumption/publication of the same intended source/version, with no moved published tag, asset replacement, duplicate release or incompatible checksum. |
| SIGN-11 | Actual published download | Independently downloaded final release passes signature/publisher/staple/assessment checks; cask fetches the identical final digest. Local candidate checks alone do not satisfy this. |
| SIGN-12 | Distribution documentation | Public guidance names the verified publisher, supported platform and normal install path, retains legal notices, removes mandatory quarantine-bypass instructions for the new signed release and states still-open continuity limitations. |

All criteria are **not verified** until implementation and the named evidence exist. Enrollment
alone does not make the existing v0.6.0 artifact signed/notarized or change its launch behavior.

## 7. Implementation Boundaries and Dependencies

Implementation changes the existing [release workflow](../../.github/workflows/release.yml),
[packaging script](../../scripts/release.sh), [project signing/embed phase](../../project.yml)
and [entitlements](../../SSMConnect/SSMConnect.entitlements), plus tests and directly related
distribution guidance. The Homebrew tap remains the existing independent sync consumer.

Ready now: spec, release-safety tests and credential-free pipeline preparation.
Blocked on enrollment: actual team verification, identity provisioning and notarization credentials.
Blocked on approved validation environment: clean-user launch and native signed workflow evidence.
No enrollment, credential export/upload, paid purchase, account-setting change or live signing
was performed while writing this specification.

## 8. Sources

Verified 2026-10-16:

- [Apple program enrollment, fees, taxes and invoices](https://developer.apple.com/help/account/membership/program-enrollment/)
- [D-U-N-S organization verification](https://developer.apple.com/support/D-U-N-S/)
- [Developer ID and notarization](https://developer.apple.com/developer-id/)
- [Developer ID certificates and lifecycle](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)
- [App Store Connect API key setup](https://developer.apple.com/help/app-store-connect/get-started/app-store-connect-api/)
- [GitHub Actions certificate/keychain handling](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)
