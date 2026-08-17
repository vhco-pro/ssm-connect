# Windows Phase 0 Spike Results

- **Date:** 2026-08-17
- **Host:** physical Windows 11 Pro x64, build 26200
- **Status:** complete. All executable spikes passed, including the clean-environment installer lifecycle. The specification's §16 planning gate is met and Phase 1 may begin; remaining items are release-time gates, not feasibility unknowns.

## Tested versions

| Component | Version |
|-----------|---------|
| .NET SDK | 10.0.111 |
| .NET runtime | 10.0.11 |
| AWS CLI | 2.33.24 |
| AWS SDK for .NET | `AWSSDK.SSO`, `AWSSDK.SSOOIDC`, `AWSSDK.SecretsManager`, and `AWSSDK.SecurityToken` 4.0.100.8; `AWSSDK.SimpleSystemsManagement` 4.0.101 |
| Session Manager plugin | 1.2.835.0, valid Amazon Authenticode signature |
| Amazon DCV Client | 2025.0.9800.0, valid Amazon Authenticode signature |
| WiX | 6.0.2 passed; WiX 7.0.0 build blocked on the OSMF EULA |
| Windows Sandbox | MSIX `MicrosoftWindows.WindowsSandbox` 0.8.107.0; base image 10.0.26100 x64 |

## Supported Windows baseline

**Windows 11 24H2, OS build 10.0.26100, x64.**

- .NET 10 supports Windows 11 26H1, 25H2, 24H2, and 23H2 Enterprise/Education only. Windows 11 23H2
  Home/Pro is already past end of updates, so 24H2 is the lowest build that is both .NET-supported
  and serviced across editions.
- The Windows Sandbox base image is 10.0.26100, so the clean-environment test runs on exactly the
  declared floor rather than above it.
- The Amazon DCV Windows client requires 64-bit Windows 10 or 11 plus .NET Framework 4.6.2 and the
  Visual C++ Redistributable, and so does not raise the floor. Those remain separate prerequisites
  that the installer must account for.
- The floor is enforced in two places: `<TargetFramework>net10.0-windows10.0.26100.0</TargetFramework>`
  with a matching `SupportedOSPlatformVersion` (previously the default `Windows7.0`, which made the
  CA1416 platform-compatibility analyzer useless), and `MinimumOSVersion: 10.0.26100.0` in the WinGet
  installer manifest.
- Cost of pinning: the self-contained single-file publish grows from about 76 MB to about 103 MB
  because the Windows SDK projection assemblies are included. Enabling trimming before release is
  worth measuring.
- **Review date:** Windows 11 24H2 Home/Pro reaches end of updates on 2026-10-13. Re-review the
  floor then; it will likely move to 25H2 (build 26200).

## Results

1. `CredentialProfileStoreChain` resolves the modern shared `sso_session` profile on Windows. The default options attempt cache reuse and refresh but do not start interactive authorization. Set `SupportsGettingNewToken = true`, a `ClientName`, and `SsoVerificationCallback` (or PKCE). With those options, stale refresh failure fell back to the browser and the SDK completed `GetCallerIdentity`.
2. The official plugin preserves the macOS five-argument contract: session JSON, region, `StartSession`, empty profile argument, and request JSON. Direct `Process` launch, redirected output, live 8443/8444 forwarding, and kill-on-close Job Object containment all passed.
3. Windows registers `.dcv` as `DcvViewerProgId` with `dcvviewer.exe --connection-file="%1"`. The multi-user path passed against `oneb2c-be-factory-prd-workstation-mu`: presigned STS validation, agent `/ensure-session`, fresh DCV token, viewer launch, five-second file grace period, deletion, server-confirmed authentication, and cleanup.
4. The same host was switched reversibly to DCV system authentication with a real `console` session and an `ec2-user` password stored only in a disposable Secrets Manager entry. The Windows SDK retrieved the secret, the viewer auto-logged in, and the server confirmed an authenticated connection. A timed rollback plus immediate cleanup restored the original config hash, external token verifier, `create-session=false`, password hash, and zero sessions; both disposable secrets were force-deleted. A disposable clone was not possible because the SSO role lacks `iam:PassRole` for the workstation role.
5. The workstation certificate is self-signed for its private hostname/IP, while the SSM endpoint is `127.0.0.1`. The Windows viewer stops at a native trust prompt unless launched with `--certificate-validation-policy=accept-untrusted`. This is acceptable only because the endpoint is reached through the authenticated SSM tunnel; production code must make that policy explicit and must not apply it to arbitrary network endpoints.
6. A protected temporary directory whose ACL grants only the current user works for both connection-file formats. Startup cleanup should target only `ssm-connect-*.dcv` files below an application-owned directory and apply a bounded age.
7. WiX 6 produced a non-elevated per-user MSI under `%LOCALAPPDATA%`. Silent install, installed-payload launch, major upgrade, silent uninstall, and residue checks passed with exit code 0, on the host and again in a clean Windows Sandbox. This supports WiX/MSI over MSIX for the first client because it imposes no process-launch or local-file restrictions in the tested path.
8. The generated three-file `VHCo.SSMConnect` manifest passes strict local `winget validate`, including `MinimumOSVersion: 10.0.26100.0`. Its release URL and version are placeholders for spike artifacts; production generation must use the immutable signed release asset and its final SHA-256.
9. Windows Sandbox works; the earlier "Sandbox is broken" reading was a harness bug. On the packaged Sandbox app, `C:\Windows\System32\WindowsSandbox.exe` is a fire-and-forget launcher that returns exit code 0 in roughly 170–190 ms while the sandbox boots asynchronously. `Start-Process -Wait` therefore returns long before `LogonCommand` runs, and treating that exit code as the test result reports a false negative. A marker-only configuration proved the point: the launcher returned 0 immediately, and the mapped folder plus `LogonCommand` marker appeared about five seconds later. The original lifecycle run had in fact passed, writing its result roughly two minutes after the run was recorded as a failure.

   The fix is to signal completion out of band. `spikes/windows/sandbox/Invoke-SandboxLifecycle.ps1` clears the result file, launches the configuration, and polls the read-write mapped folder until the sandbox writes its verdict. Driven this way, the full clean-environment lifecycle passed end to end with driver exit code 0: install 0.0.1, launch the installed payload, Job Object close, Job Object crash containment, upgrade to 0.0.2, silent uninstall, and no payload or directory residue. Wall clock is about 260 seconds, nearly all of it sandbox boot.

   The packaged app also ships a real CLI at `wsb.exe` (`start`, `share`, `exec`, `list`, `stop`, `connect`, `ip`) with an `AppCli` entry point. That is the supported synchronous automation surface if the polling driver ever proves insufficient; `wsb list` is also the way to spot a sandbox left running.
10. WiX 7 cannot be adopted silently: its CLI requires acceptance of the OSMF EULA. Legal/project-owner review is required before choosing it over WiX 6.
11. Job Object containment survives a hard crash of the owning process. The `crash` probe starts a holder process that owns a kill-on-close job containing a child, then calls `TerminateProcess` on the holder only, so no managed `Dispose`, finalizer, or graceful shutdown path runs. The kernel reaped the contained child in 1–5 ms across every run, on the host and inside the clean Sandbox, with no process residue.

    Scope limit worth stating plainly: this proves *local* process-tree containment. It does not prove that the AWS-side SSM session is terminated when the client is killed, because the probe contains a stand-in child rather than a live plugin session. Logoff and suspend/resume are also still untested — see the remaining gates.

## Reproduction

```powershell
dotnet build .\spikes\windows\SSMConnect.WindowsSpikes\SSMConnect.WindowsSpikes.csproj
dotnet run --no-build --project .\spikes\windows\SSMConnect.WindowsSpikes\SSMConnect.WindowsSpikes.csproj -- host
dotnet run --no-build --project .\spikes\windows\SSMConnect.WindowsSpikes\SSMConnect.WindowsSpikes.csproj -- plugin
dotnet run --no-build --project .\spikes\windows\SSMConnect.WindowsSpikes\SSMConnect.WindowsSpikes.csproj -- dcv-files
dotnet run --no-build --project .\spikes\windows\SSMConnect.WindowsSpikes\SSMConnect.WindowsSpikes.csproj -- aws <profile> <resource-region>
dotnet run --no-build --project .\spikes\windows\SSMConnect.WindowsSpikes\SSMConnect.WindowsSpikes.csproj -- tunnel <profile> <region> <instance-id> <local-port> <remote-port>
dotnet run --no-build --project .\spikes\windows\SSMConnect.WindowsSpikes\SSMConnect.WindowsSpikes.csproj -- multi-user <profile> <region> <instance-id> <dcv-local-port> <agent-local-port>
dotnet run --no-build --project .\spikes\windows\SSMConnect.WindowsSpikes\SSMConnect.WindowsSpikes.csproj -- single-user <profile> <region> <instance-id> <dcv-local-port> <secret-id> <user> <expected-session-id>
dotnet run --no-build --project .\spikes\windows\SSMConnect.WindowsSpikes\SSMConnect.WindowsSpikes.csproj -- crash
winget validate --manifest .\spikes\windows\winget --disable-interactivity
```

Rebuilding the installer artifacts and running the clean-environment lifecycle:

```powershell
dotnet tool install --global wix --version 6.0.2
dotnet publish .\spikes\windows\SSMConnect.WindowsSpikes\SSMConnect.WindowsSpikes.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o .\spikes\windows\installer\payload
$payload = (Resolve-Path .\spikes\windows\installer\payload\SSMConnect.WindowsSpikes.exe).Path
wix build .\spikes\windows\installer\Package.wxs -d PackageVersion=0.0.1 -d Payload=$payload -o .\dist\SSMConnect-Windows-Spike-0.0.1.msi
wix build .\spikes\windows\installer\Package.wxs -d PackageVersion=0.0.2 -d Payload=$payload -o .\dist\SSMConnect-Windows-Spike-0.0.2.msi
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\spikes\windows\sandbox\Invoke-SandboxLifecycle.ps1
```

Do not read `WindowsSandbox.exe`'s exit code as the lifecycle result; use the driver, which polls the
mapped folder and exits non-zero on failure or timeout.

The live commands print no credentials, identity values, presigned URLs, tokens, account IDs, or agent-returned usernames. Use synthetic or approved test infrastructure only.

## Phase 0 outcome

The §16 planning gate in the specification is **met**: AWS SSO, the SSM plugin, DCV launch in both
auth modes, and the installer lifecycle all succeeded on real Windows 11 x64. Phase 1 may begin, and
Phase 0 findings have been folded into the normative sections of the specification (§9.0–§9.4,
§11.2, §12) rather than left as evidence here.

Nothing below blocks Phase 1. Each item is carried by a specification requirement or acceptance
criterion, listed here so the follow-up work is not lost.

- **Release signing** — gates the first general release under AC-09, not the refactor. Needs a
  purchased code-signing certificate; there is no engineering unknown left to spike. Scope:
  Authenticode-sign both the MSI and the self-contained payload executable, then regenerate the
  WinGet manifest against the signed, immutable, publisher-hosted release asset and its final
  SHA-256. An OV certificate builds SmartScreen reputation over time; an EV certificate carries it
  immediately. Decide which before the first general release.
- **Orphaned AWS-side sessions on abnormal exit** — carried by AC-07 and §9.3. Local Job Object
  containment is proven, but a hard-killed client has not been shown to terminate its SSM session
  server-side. Run the `tunnel` or `multi-user` probe, kill the owning process, and check whether
  the SSM and DCV sessions close or linger until timeout. If they linger, the client needs a
  reap-on-start path rather than relying on process cleanup.
- **Logoff and suspend/resume** — carried by AC-07 and §9.3. Untested, because both require
  disrupting the interactive session or the machine power state and cannot be automated from inside
  the session under test. Run them manually, or in a VM that can drive the power state.
- **Plugin redistribution terms** — §15 question 2, and the last thing blocking a choice between
  bundling the plugin and discovering a user installation. A licence read, not a test.
- **Baseline review on 2026-10-13** — see §11.2.