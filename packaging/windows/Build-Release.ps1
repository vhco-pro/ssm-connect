# Copyright (c) 2026 VH & Co BV. Licensed under the Apache License 2.0. See LICENSE for details.
<#
.SYNOPSIS
    Builds the Windows release: the per-user MSI, its checksum and the WinGet manifest.

.DESCRIPTION
    The release workflow's Windows job runs this script, and it runs the same way on a developer's
    Windows machine. It:

    1. stamps the build into the Swift helper and editor proxy and the .NET shell, so the shell
       refuses a helper of another build at handshake and a proxy refuses another build's lease;
    2. builds SSMConnectHelper.exe and ssm-connect-proxy.exe with SwiftPM in release mode;
    3. copies the Swift runtime DLLs those two import, found by walking their PE import tables,
       from the installed Swift runtime;
    4. publishes the WPF shell self-contained, so the .NET runtime is not a prerequisite;
    5. adds the verified Session Manager plugin and the license notices;
    6. builds the MSI with WiX, writes its SHA-256, and generates and validates the WinGet manifest
       from that exact file, so the manifest's hash cannot drift from the asset.

    The release is unsigned: WinGet requires a signature only for MSIX. Users see SmartScreen's
    unknown-publisher warning; the published checksum is how they confirm the download.

.PARAMETER Version
    The release version, such as 1.4.0 or 0.0.0-test.1. The MSI's ProductVersion is its numeric part.

.PARAMETER Build
    The build ID shared by the shell, helper and proxy. Defaults to the version.

.PARAMETER Output
    Where the MSI, checksum and manifest are written. Defaults to dist\ in the repository.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Version,
    [string] $Build = $Version,
    [string] $Output
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($Version -notmatch '^(\d+\.\d+\.\d+)(-[0-9A-Za-z.-]+)?$') { throw "Expected a semantic version, got '$Version'." }
$msiVersion = $Matches[1]
$repository = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$kit = Join-Path $repository 'SSMConnectKit'
$work = Join-Path $repository '.build\windows-release'
$payload = Join-Path $work 'payload'
if (-not $Output) { $Output = Join-Path $repository 'dist' }
$WixVersion = '6.0.2'

# Runs a native command, passing its output through. Windows PowerShell turns a native command's
# stderr into error records, which Stop would make fatal; the exit code decides instead.
function Invoke-Native([string] $Description, [scriptblock] $Command) {
    $ErrorActionPreference = 'Continue'
    & $Command 2>&1 | ForEach-Object { Write-Host "$_" }
    if ($LASTEXITCODE -ne 0) { throw "$Description failed with exit code $LASTEXITCODE." }
}

# Returns the DLL names a PE image imports, directly or delay-loaded.
function Get-PEImports([string] $Path) {
    $bytes = [IO.File]::ReadAllBytes($Path)
    $pe = [BitConverter]::ToInt32($bytes, 0x3C)
    $sectionCount = [BitConverter]::ToUInt16($bytes, $pe + 6)
    $optionalSize = [BitConverter]::ToUInt16($bytes, $pe + 20)
    $optional = $pe + 24
    $directories = if ([BitConverter]::ToUInt16($bytes, $optional) -eq 0x20B) { $optional + 112 } else { $optional + 96 }
    $sectionTable = $optional + $optionalSize
    $toOffset = {
        param([uint32] $rva)
        for ($i = 0; $i -lt $sectionCount; $i++) {
            $section = $sectionTable + 40 * $i
            $address = [BitConverter]::ToUInt32($bytes, $section + 12)
            $size = [Math]::Max([BitConverter]::ToUInt32($bytes, $section + 8), [BitConverter]::ToUInt32($bytes, $section + 16))
            if ($rva -ge $address -and $rva -lt $address + $size) { return [int]($rva - $address + [BitConverter]::ToUInt32($bytes, $section + 20)) }
        }
        throw "RVA $rva is outside every section of $Path."
    }
    $readName = {
        param([uint32] $rva)
        $start = & $toOffset $rva
        $end = $start
        while ($bytes[$end] -ne 0) { $end++ }
        [Text.Encoding]::ASCII.GetString($bytes, $start, $end - $start)
    }
    # Import directory (entry 1): 20-byte descriptors, name at +12. Delay-load (entry 13): 32 bytes, name at +4.
    foreach ($table in @(@{ Entry = 1; Size = 20; Name = 12 }, @{ Entry = 13; Size = 32; Name = 4 })) {
        $rva = [BitConverter]::ToUInt32($bytes, $directories + 8 * $table.Entry)
        if ($rva -eq 0) { continue }
        $offset = & $toOffset $rva
        while (($name = [BitConverter]::ToUInt32($bytes, $offset + $table.Name)) -ne 0) {
            & $readName $name
            $offset += $table.Size
        }
    }
}

# The installed Swift runtime: the directory on PATH that holds swiftCore.dll.
function Find-SwiftRuntime {
    foreach ($directory in $env:Path -split ';') {
        if ($directory -and (Test-Path (Join-Path $directory 'swiftCore.dll'))) { return $directory }
    }
    throw 'No Swift runtime on PATH (swiftCore.dll). Install the Swift toolchain first.'
}

Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $payload, $Output | Out-Null

# 1-2. The helper and proxy, stamped with the build. The stamped file is restored afterwards so the
# working tree is left as it was.
$buildFile = Join-Path $kit 'Sources\SSMConnectWorkflow\InstalledBuild.swift'
$original = [IO.File]::ReadAllBytes($buildFile)
try {
    $text = [Text.Encoding]::UTF8.GetString($original)
    $stamped = $text.Replace('package static let current = "dev"', "package static let current = `"$Build`"")
    if ($stamped -eq $text) { throw "Could not stamp the build into $buildFile." }
    [IO.File]::WriteAllText($buildFile, $stamped, [Text.UTF8Encoding]::new($false))
    # Swift 6.4.2 bundles Clang 21; current MSVC STLs reject Clang older than 22 when swift-crypto's C++ builds.
    foreach ($product in 'SSMConnectHelper', 'ssm-connect-proxy') {
        Write-Host "Building $product ($Build)..."
        Invoke-Native "swift build $product" {
            swift build -c release --package-path $kit --product $product -Xcc -D_ALLOW_COMPILER_AND_STL_VERSION_MISMATCH
        }
    }
    $binaries = (& { $ErrorActionPreference = 'Continue'; swift build -c release --package-path $kit --show-bin-path 2>$null } |
        Select-Object -Last 1).Trim()
}
finally {
    [IO.File]::WriteAllBytes($buildFile, $original)
}
foreach ($executable in 'SSMConnectHelper.exe', 'ssm-connect-proxy.exe') {
    Copy-Item (Join-Path $binaries $executable) $payload
}

# 3. The Swift runtime DLLs the two executables import, transitively. System DLLs are not in the
# runtime directory and stay where Windows provides them.
$runtime = Find-SwiftRuntime
Write-Host "Copying the Swift runtime from $runtime..."
$queue = [Collections.Generic.Queue[string]]::new()
$copied = @{}
foreach ($executable in 'SSMConnectHelper.exe', 'ssm-connect-proxy.exe') { $queue.Enqueue((Join-Path $payload $executable)) }
while ($queue.Count -gt 0) {
    foreach ($import in Get-PEImports $queue.Dequeue()) {
        $key = $import.ToLowerInvariant()
        $candidate = Join-Path $runtime $import
        if ($copied.ContainsKey($key) -or -not (Test-Path $candidate)) { continue }
        $copied[$key] = $true
        Copy-Item $candidate $payload
        $queue.Enqueue((Join-Path $payload $import))
    }
}
Write-Host "Copied $($copied.Count) runtime DLLs: $(($copied.Keys | Sort-Object) -join ', ')"

# 4. The shell, self-contained and single-file, carrying the same build.
Write-Host 'Publishing the shell...'
Invoke-Native 'dotnet publish' {
    dotnet publish (Join-Path $repository 'windows\src\SSMConnect.App\SSMConnect.App.csproj') `
        -c Release -r win-x64 -p:SelfContained=true -p:PublishSingleFile=true `
        -p:IncludeNativeLibrariesForSelfExtract=true -p:DebugType=none `
        -p:Version=$msiVersion -p:SSMConnectBuild=$Build -o (Join-Path $work 'shell')
}
Copy-Item (Join-Path $work 'shell\SSMConnect.exe') $payload

# 5. The plugin, verified against its pinned hashes, beside the helper, with its notices.
$plugin = & (Join-Path $repository 'scripts\fetch-plugin.ps1') | Select-Object -Last 1
Copy-Item (Join-Path $plugin 'bin\session-manager-plugin.exe') $payload
New-Item -ItemType Directory -Force -Path (Join-Path $payload 'session-manager-plugin') | Out-Null
foreach ($notice in 'LICENSE', 'NOTICE', 'THIRD-PARTY') {
    Copy-Item (Join-Path $plugin $notice) (Join-Path $payload "session-manager-plugin\$notice")
}

Copy-Item (Join-Path $repository 'LICENSE') (Join-Path $payload 'LICENSE.txt')
$checkouts = Join-Path $kit '.build\checkouts'
$dotnet = Split-Path -Parent (Get-Command dotnet).Source
$notices = Join-Path $PSScriptRoot 'notices'
$sections = @(
    @{ Title = 'Swift runtime, Foundation and libdispatch (Apache License 2.0 with Runtime Library Exception)'; Files = @("$notices\Swift-LICENSE.txt") },
    @{ Title = 'ICU, used by Foundation (Unicode License V3 and ICU licenses)'; Files = @("$notices\ICU-LICENSE.txt") },
    @{ Title = 'SwiftCrypto, with the BoringSSL and XKCP code it vendors (Apache License 2.0)'; Files = @("$checkouts\swift-crypto\LICENSE.txt", "$checkouts\swift-crypto\NOTICE.txt") },
    @{ Title = 'Yams (MIT)'; Files = @("$checkouts\Yams\LICENSE") },
    @{ Title = 'LibYAML, vendored by Yams (MIT)'; Files = @("$notices\libyaml-LICENSE.txt") },
    @{ Title = '.NET runtime and WPF, bundled with SSMConnect.exe (MIT)'; Files = @("$dotnet\LICENSE.txt", "$dotnet\ThirdPartyNotices.txt") }
)
$builder = [Text.StringBuilder]::new()
[void] $builder.AppendLine("SSM Connect $Version for Windows: third-party notices")
[void] $builder.AppendLine('')
[void] $builder.AppendLine('SSM Connect is licensed under the Apache License 2.0 (LICENSE.txt). It includes the components')
[void] $builder.AppendLine('below. The AWS Session Manager plugin (session-manager-plugin.exe) is redistributed under the')
[void] $builder.AppendLine('Apache License 2.0; its LICENSE, NOTICE and THIRD-PARTY files are in the session-manager-plugin')
[void] $builder.AppendLine('folder. The Microsoft Visual C++ runtime DLLs are redistributed under the Visual Studio')
[void] $builder.AppendLine('redistribution terms.')
foreach ($section in $sections) {
    [void] $builder.AppendLine('')
    [void] $builder.AppendLine(('=' * 78))
    [void] $builder.AppendLine($section.Title)
    [void] $builder.AppendLine(('=' * 78))
    foreach ($file in $section.Files) {
        if (-not (Test-Path $file)) { throw "Missing notice input $file." }
        [void] $builder.AppendLine('')
        [void] $builder.AppendLine((Get-Content $file -Raw))
    }
}
[IO.File]::WriteAllText((Join-Path $payload 'ThirdPartyNotices.txt'), $builder.ToString(), [Text.UTF8Encoding]::new($false))

# The license page of the installer, as RTF.
$rtf = [Text.StringBuilder]::new('{\rtf1\ansi\deff0{\fonttbl{\f0 Segoe UI;}}\fs16 ')
foreach ($line in Get-Content (Join-Path $repository 'LICENSE')) {
    [void] $rtf.Append($line.Replace('\', '\\').Replace('{', '\{').Replace('}', '\}')).Append('\par ')
}
[void] $rtf.Append('}')
$licenseRtf = Join-Path $work 'License.rtf'
[IO.File]::WriteAllText($licenseRtf, $rtf.ToString(), [Text.Encoding]::ASCII)

# 6. The MSI. -arch x64 matters: the default x86 registers the product under WOW6432Node. The WiX
# tool and extensions come from nuget.org through this directory's nuget.config, so a machine with
# no NuGet source configured still builds.
Push-Location $PSScriptRoot
try {
    if (-not (Get-Command wix -ErrorAction SilentlyContinue)) {
        Invoke-Native 'Installing WiX' { dotnet tool install --global wix --version $WixVersion }
        $env:Path += ";$env:USERPROFILE\.dotnet\tools"
    }
    foreach ($extension in 'WixToolset.UI.wixext', 'WixToolset.Util.wixext') {
        Invoke-Native "Adding $extension" { wix extension add -g "$extension/$WixVersion" }
    }
    $msi = Join-Path $Output "SSMConnect-$Version-x64.msi"
    Write-Host 'Building the MSI...'
    Invoke-Native 'wix build' {
        wix build (Join-Path $PSScriptRoot 'Package.wxs') -arch x64 `
            -ext "WixToolset.UI.wixext/$WixVersion" -ext "WixToolset.Util.wixext/$WixVersion" `
            -d PackageVersion=$msiVersion -d PayloadDirectory=$payload -d LicenseRtf=$licenseRtf -o $msi
    }
}
finally { Pop-Location }
$hash = (Get-FileHash $msi -Algorithm SHA256).Hash
"$hash  $(Split-Path -Leaf $msi)" | Set-Content "$msi.sha256" -Encoding ascii -NoNewline
Write-Host "Built $msi ($([math]::Round((Get-Item $msi).Length / 1MB, 1)) MB), SHA-256 $hash"

# The WinGet manifest, from the file just built.
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

"msi=$msi"
"sha256=$hash"
"manifest=$manifest"
