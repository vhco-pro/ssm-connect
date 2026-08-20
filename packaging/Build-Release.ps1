<#
.SYNOPSIS
    Publishes the app, builds the per-user MSI, and generates the WinGet manifest.

.DESCRIPTION
    Builds a complete, publishable release.

    The release is deliberately unsigned. WinGet only requires a signature for MSIX, and this ships
    a WiX MSI, so nothing about distribution is blocked. What is lost is the SmartScreen publisher
    name: users see an "unknown publisher" warning on first download, and no metadata changes that,
    because only a signature does.

    Attribution therefore rests on two things this script produces: publisher fields carried in the
    MSI and in every assembly, and a checksum file users can verify the download against. If a
    certificate is obtained later, sign the payload and the MSI and re-run this script, because the
    manifest pins a SHA-256 and signing changes it.

.PARAMETER Version
    Product version for the MSI and the manifest.

.PARAMETER SelfContained
    Bundle the .NET runtime. Default. Measured at roughly 166 MB against 33 MB framework-dependent,
    but framework-dependent adds the .NET Desktop Runtime as a prerequisite the user must install.
    Trimming is not an option either way: WPF is not supported with trimming (NETSDK1168).
#>
[CmdletBinding()]
param(
    [string] $Version = '0.1.0',
    [bool] $SelfContained = $true,
    [string] $PluginDirectory
)

$ErrorActionPreference = 'Stop'

$packaging = $PSScriptRoot
$repository = Split-Path -Parent $packaging
$payload = Join-Path $packaging 'payload'
$output = Join-Path $repository 'dist'

# Default to a verified download rather than whatever happens to be installed on the build machine.
# Local builds and CI then package byte-identical plugin binaries, and the provenance is asserted
# rather than assumed.
if (-not $PluginDirectory) {
    $PluginDirectory = & (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts/fetch-plugin.ps1') |
        Select-Object -Last 1
}

foreach ($required in @(
    (Join-Path $PluginDirectory 'bin\session-manager-plugin.exe'),
    (Join-Path $PluginDirectory 'LICENSE'),
    (Join-Path $PluginDirectory 'NOTICE'),
    (Join-Path $PluginDirectory 'THIRD-PARTY'))) {
    if (-not (Test-Path $required)) {
        throw "Missing plugin redistribution input: $required"
    }
}

if (-not (Get-Command wix -ErrorAction SilentlyContinue)) {
    throw 'WiX is not installed. Run: dotnet tool install --global wix --version 6.0.2'
}

Write-Host "Publishing the application (self-contained: $SelfContained)…"
Remove-Item $payload -Recurse -Force -ErrorAction SilentlyContinue
dotnet publish (Join-Path $repository 'windows\src\SSMConnect.App\SSMConnect.App.csproj') `
    -c Release -r win-x64 `
    -p:SelfContained=$($SelfContained.ToString().ToLowerInvariant()) `
    -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -p:DebugType=none `
    -o $payload
if ($LASTEXITCODE -ne 0) { throw 'Publish failed.' }

New-Item -ItemType Directory -Force -Path $output | Out-Null
$msi = Join-Path $output "SSMConnect-$Version-x64.msi"

Write-Host 'Building the MSI…'
# Without -arch the MSI is built x86, which lands the product in WOW6432Node and contradicts the
# x64 the WinGet manifest declares. The payload is x64-only, so the package must say so.
wix build (Join-Path $packaging 'Package.wxs') `
    -arch x64 `
    -d PackageVersion=$Version `
    -d PayloadDirectory=$payload `
    -d PluginDirectory=$PluginDirectory `
    -d RepositoryRoot=$repository `
    -o $msi
if ($LASTEXITCODE -ne 0) { throw 'MSI build failed.' }

$hash = (Get-FileHash $msi -Algorithm SHA256).Hash
$sizeMb = [math]::Round((Get-Item $msi).Length / 1MB, 1)
Write-Host "Built $msi ($sizeMb MB)"
Write-Host "SHA-256: $hash"

# The checksum is how a user confirms the download is the file this build produced. On an unsigned
# release it is the only such mechanism, so it is published as a file rather than only printed.
$checksums = Join-Path $output "SSMConnect-$Version-x64.msi.sha256"
"$hash  $(Split-Path -Leaf $msi)" | Set-Content $checksums -Encoding ascii
Write-Host "Wrote $checksums"

# The manifest is generated from the artifact that was actually built, so its hash can never drift
# from the file it describes. It is written next to the MSI rather than into the repository,
# because the URL is only real once the release exists.
$manifestDirectory = Join-Path $output "winget-$Version"
New-Item -ItemType Directory -Force -Path $manifestDirectory | Out-Null
$installerUrl = "https://github.com/vhco-pro/ssm-connect/releases/download/v$Version/$(Split-Path -Leaf $msi)"
$releaseDate = (Get-Item $msi).LastWriteTime.ToString('yyyy-MM-dd')

@"
# yaml-language-server: `$schema=https://aka.ms/winget-manifest.version.1.9.0.schema.json
PackageIdentifier: VHCo.SSMConnect
PackageVersion: $Version
DefaultLocale: en-US
ManifestType: version
ManifestVersion: 1.9.0
"@ | Set-Content (Join-Path $manifestDirectory 'VHCo.SSMConnect.yaml') -Encoding utf8

@"
# yaml-language-server: `$schema=https://aka.ms/winget-manifest.installer.1.9.0.schema.json
PackageIdentifier: VHCo.SSMConnect
PackageVersion: $Version
InstallerType: wix
Scope: user
MinimumOSVersion: 10.0.26100.0
InstallModes:
  - silent
  - silentWithProgress
UpgradeBehavior: install
ReleaseDate: $releaseDate
Installers:
  - Architecture: x64
    InstallerUrl: $installerUrl
    InstallerSha256: $hash
ManifestType: installer
ManifestVersion: 1.9.0
"@ | Set-Content (Join-Path $manifestDirectory 'VHCo.SSMConnect.installer.yaml') -Encoding utf8

@"
# yaml-language-server: `$schema=https://aka.ms/winget-manifest.defaultLocale.1.9.0.schema.json
PackageIdentifier: VHCo.SSMConnect
PackageVersion: $Version
PackageLocale: en-US
Publisher: VHCo
PublisherUrl: https://github.com/vhco-pro
PublisherSupportUrl: https://github.com/vhco-pro/ssm-connect/issues
PackageName: SSM Connect
PackageUrl: https://github.com/vhco-pro/ssm-connect
License: Apache-2.0
LicenseUrl: https://github.com/vhco-pro/ssm-connect/blob/main/LICENSE
ShortDescription: Connect to EC2 workstations through AWS Systems Manager.
Description: |-
  SSM Connect opens an Amazon DCV session to an EC2 workstation over an AWS Systems Manager
  tunnel, with no inbound security-group rules. It supports a shared single-user workstation and
  per-user multi-user sessions authenticated by your own AWS identity.
Tags:
  - aws
  - ec2
  - ssm
  - dcv
  - remote-desktop
ManifestType: defaultLocale
ManifestVersion: 1.9.0
"@ | Set-Content (Join-Path $manifestDirectory 'VHCo.SSMConnect.locale.en-US.yaml') -Encoding utf8

Write-Host "Wrote the WinGet manifest to $manifestDirectory"

if (Get-Command winget -ErrorAction SilentlyContinue) {
    winget validate --manifest $manifestDirectory --disable-interactivity
    if ($LASTEXITCODE -ne 0) { throw 'winget validate failed.' }
}

$releaseNotes = Join-Path $output "RELEASE-NOTES-$Version.md"
@"
# SSM Connect $Version

From **vhco-pro** (https://github.com/vhco-pro/ssm-connect), Apache-2.0.

## This release is not code-signed

Windows will show **"Windows protected your PC"** the first time you run the installer, and the
publisher will read as unknown. That is expected. Choose **More info**, then **Run anyway**.

Verify you have the file this build produced before you do:

``````powershell
Get-FileHash .\$(Split-Path -Leaf $msi) -Algorithm SHA256
``````

Expected SHA-256:

``````
$hash
``````

Once installed, Windows Settings > Installed apps lists the publisher as **VHCo**, and the
executable's Properties > Details tab carries the same identity.

## What it installs

- SSM Connect itself, per-user under ``%LOCALAPPDATA%\Programs\SSM Connect`` (no administrator
  rights needed).
- The AWS Session Manager plugin, redistributed under the Apache License 2.0 with its LICENSE,
  NOTICE, and THIRD-PARTY files.

Amazon DCV Viewer is a separate prerequisite and is not bundled.
"@ | Set-Content $releaseNotes -Encoding utf8

Write-Host "Wrote $releaseNotes"
Write-Host ''
Write-Host 'Release is complete and unsigned by design.' -ForegroundColor Yellow
Write-Host 'Users will see a SmartScreen warning on first run; the release notes explain it and'
Write-Host 'the .sha256 file lets them verify the download.'
Write-Host 'If a certificate is obtained later, sign both artifacts and re-run this script.'
