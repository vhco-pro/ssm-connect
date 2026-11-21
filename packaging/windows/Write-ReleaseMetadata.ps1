# Copyright (c) 2026 VH & Co BV. Licensed under the Apache License 2.0. See LICENSE for details.
<#
.SYNOPSIS
    Writes an MSI's SHA-256 file and WinGet manifest, both derived from that exact file.

.DESCRIPTION
    Build-Release.ps1 runs this on the MSI it built. The release workflow runs it again when the
    release already holds the MSI (a rerun job): MSI builds are not byte-reproducible, so the
    checksum and manifest must come from the published file, never from a rebuild.

    The results go to release-outputs.txt in the output directory as key=value lines.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Msi,
    [Parameter(Mandatory)] [string] $Version,
    [Parameter(Mandatory)] [string] $Output
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$msi = (Resolve-Path $Msi).Path

# Runs a native command with its output going straight to the console (see Build-Release.ps1).
function Invoke-Native([string] $Description, [scriptblock] $Command) {
    $ErrorActionPreference = 'Continue'
    & $Command
    if ($LASTEXITCODE -ne 0) { throw "$Description failed with exit code $LASTEXITCODE." }
}

$hash = (Get-FileHash $msi -Algorithm SHA256).Hash
"$hash  $(Split-Path -Leaf $msi)" | Set-Content "$msi.sha256" -Encoding ascii -NoNewline
Write-Host "$msi ($([math]::Round((Get-Item $msi).Length / 1MB, 1)) MB), SHA-256 $hash"

# The WinGet manifest, from that exact file.
$manifest = Join-Path $Output "winget-$Version"
New-Item -ItemType Directory -Force -Path $manifest | Out-Null
$id = 'VHCo.SSMConnect'
$url = "https://github.com/vhco-pro/ssm-connect/releases/download/v$Version/$(Split-Path -Leaf $msi)"
@"
# yaml-language-server: `$schema=https://aka.ms/winget-manifest.version.1.9.0.schema.json
PackageIdentifier: $id
PackageVersion: $Version
DefaultLocale: en-US
ManifestType: version
ManifestVersion: 1.9.0
"@ | Set-Content (Join-Path $manifest "$id.yaml") -Encoding utf8
@"
# yaml-language-server: `$schema=https://aka.ms/winget-manifest.installer.1.9.0.schema.json
PackageIdentifier: $id
PackageVersion: $Version
InstallerType: wix
Scope: user
MinimumOSVersion: 10.0.26100.0
InstallModes:
  - interactive
  - silent
  - silentWithProgress
UpgradeBehavior: install
ReleaseDate: $((Get-Date).ToString('yyyy-MM-dd'))
Installers:
  - Architecture: x64
    InstallerUrl: $url
    InstallerSha256: $hash
ManifestType: installer
ManifestVersion: 1.9.0
"@ | Set-Content (Join-Path $manifest "$id.installer.yaml") -Encoding utf8
@"
# yaml-language-server: `$schema=https://aka.ms/winget-manifest.defaultLocale.1.9.0.schema.json
PackageIdentifier: $id
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
  SSM Connect opens an Amazon DCV session, a VS Code remote workspace or web forwards to an EC2
  workstation over AWS Systems Manager, with no inbound security-group rules, signed in with your
  own AWS IAM Identity Center identity.
Tags:
  - aws
  - ec2
  - ssm
  - dcv
ManifestType: defaultLocale
ManifestVersion: 1.9.0
"@ | Set-Content (Join-Path $manifest "$id.locale.en-US.yaml") -Encoding utf8

if (Get-Command winget -ErrorAction SilentlyContinue) {
    Invoke-Native 'winget validate' { winget validate --manifest $manifest --disable-interactivity }
    Write-Host "Validated the WinGet manifest in $manifest"
} else {
    Write-Warning 'winget is not available here; the manifest was not validated.'
}

# The results, as key=value lines in a file rather than on the output stream, so callers never
# capture this script's output (see Invoke-Native).
$results = Join-Path $Output 'release-outputs.txt'
@("msi=$msi", "sha256=$hash", "manifest=$manifest") | Set-Content $results -Encoding ascii
Write-Host "Wrote the results to $results"
exit 0
