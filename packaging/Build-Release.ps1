<#
.SYNOPSIS
    Publishes the app, builds the per-user MSI, and generates the WinGet manifest.

.DESCRIPTION
    Everything a release needs except signing, which requires a purchased certificate. The script
    stops short of that deliberately rather than producing an unsigned artifact that looks final:
    an unsigned MSI must not reach the WinGet manifest, because the manifest pins a SHA-256 and
    signing changes it.

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
    [string] $PluginDirectory = 'C:\Program Files\Amazon\SessionManagerPlugin'
)

$ErrorActionPreference = 'Stop'

$packaging = $PSScriptRoot
$repository = Split-Path -Parent $packaging
$payload = Join-Path $packaging 'payload'
$output = Join-Path $repository 'dist'

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
wix build (Join-Path $packaging 'Package.wxs') `
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

Write-Host ''
Write-Host 'NOT DONE: the MSI and the payload are unsigned.' -ForegroundColor Yellow
Write-Host 'Authenticode-sign both, then re-run this script so the manifest hash matches the signed file.'
