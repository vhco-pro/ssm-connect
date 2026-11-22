# Copyright (c) 2026 VH & Co BV. Licensed under the Apache License 2.0. See LICENSE for details.
<#
.SYNOPSIS
    Inspects a built MSI and, with -Install, installs, upgrades over a running copy and removes it.

.DESCRIPTION
    Unpacks the MSI with an administrative install and checks that it holds the shell, the helper,
    the editor proxy, the Swift runtime they import, the Session Manager plugin and every required
    notice; that the helper starts from the unpacked folder with only System32 on PATH and reports
    the expected build; and that the WinGet manifest pins the MSI's SHA-256.

    With -Install (a disposable machine such as a CI runner), it also installs the MSI silently,
    starts SSM Connect, checks that a silent reinstall refuses while it runs and leaves it running,
    quits it, reinstalls, and uninstalls, checking that the program folder is gone afterwards.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Msi,
    [Parameter(Mandatory)] [string] $Build,
    [string] $Manifest,
    [switch] $Install
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$Msi = (Resolve-Path $Msi).Path
$failures = [Collections.Generic.List[string]]::new()
function Check([bool] $condition, [string] $message) {
    if ($condition) { Write-Host "ok   $message" } else { Write-Host "FAIL $message"; $failures.Add($message) }
}
function Invoke-Msi([string[]] $Arguments) {
    (Start-Process msiexec.exe -Wait -PassThru -ArgumentList $Arguments).ExitCode
}

# The unpacked image.
$image = Join-Path ([IO.Path]::GetTempPath()) ('ssm-msi-' + [guid]::NewGuid().ToString('N'))
$code = Invoke-Msi @('/a', "`"$Msi`"", '/qn', "TARGETDIR=`"$image`"")
Check ($code -eq 0) "administrative unpack exits 0 (got $code)"
$shell = Get-ChildItem $image -Recurse -Filter SSMConnect.exe | Select-Object -First 1
if (-not $shell) { throw 'The unpacked MSI holds no SSMConnect.exe.' }
$root = $shell.DirectoryName
Write-Host "Unpacked to $root"

$required = 'SSMConnect.exe', 'SSMConnectHelper.exe', 'ssm-connect-proxy.exe', 'session-manager-plugin.exe',
    'swiftCore.dll', 'Foundation.dll', 'FoundationEssentials.dll', '_FoundationICU.dll', 'vcruntime140.dll',
    'LICENSE.txt', 'ThirdPartyNotices.txt',
    'session-manager-plugin\LICENSE', 'session-manager-plugin\NOTICE', 'session-manager-plugin\THIRD-PARTY'
foreach ($file in $required) { Check (Test-Path (Join-Path $root $file)) "the MSI holds $file" }

$notices = Get-Content (Join-Path $root 'ThirdPartyNotices.txt') -Raw
foreach ($component in 'Swift runtime', 'ICU', 'SwiftCrypto', 'Yams', 'LibYAML', '.NET runtime', 'Session Manager plugin') {
    Check ($notices.Contains($component)) "the notices cover $component"
}

# The helper and proxy carry this build's marker and the bundled plugin's SHA-256, which they check
# before each launch.
$pluginHash = (Get-FileHash (Join-Path $root 'session-manager-plugin.exe') -Algorithm SHA256).Hash.ToLowerInvariant()
foreach ($executable in 'SSMConnectHelper.exe', 'ssm-connect-proxy.exe') {
    $bytes = [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes((Join-Path $root $executable)))
    Check ($bytes.Contains("ssm-connect-build:$Build;")) "$executable carries the build marker for $Build"
    Check ($bytes.Contains($pluginHash)) "$executable records the bundled plugin's SHA-256"
}

# The runtime closure is complete: with only System32 on PATH, a missing DLL fails the start with
# STATUS_DLL_NOT_FOUND (0xC0000135).
$saved = $env:Path
try {
    $env:Path = "$env:SystemRoot\System32"
    # Windows PowerShell turns native stderr into error records, which Stop would make fatal.
    $ErrorActionPreference = 'Continue'
    $reported = & (Join-Path $root 'SSMConnectHelper.exe') --build 2>$null
    Check ($LASTEXITCODE -eq 0 -and "$reported".Trim() -eq $Build) "the unpacked helper starts and reports build $Build (got '$reported', exit $LASTEXITCODE)"
    & (Join-Path $root 'ssm-connect-proxy.exe') 2>$null | Out-Null
    Check ($LASTEXITCODE -ne -1073741515) "the unpacked editor proxy loads its runtime (exit $LASTEXITCODE)"
    $ErrorActionPreference = 'Stop'
} finally { $env:Path = $saved }

if ($Manifest) {
    $hash = (Get-FileHash $Msi -Algorithm SHA256).Hash
    $installer = Get-Content (Join-Path $Manifest 'VHCo.SSMConnect.installer.yaml') -Raw
    Check ($installer -match "InstallerSha256: $hash") "the WinGet manifest pins the MSI's SHA-256 $hash"
    Check ($installer -match [regex]::Escape((Split-Path -Leaf $Msi))) 'the WinGet manifest points at the MSI by name'
}
Remove-Item $image -Recurse -Force -ErrorAction SilentlyContinue

if ($Install) {
    $folder = Join-Path $env:LOCALAPPDATA 'Programs\SSM Connect'
    Check ((Invoke-Msi @('/i', "`"$Msi`"", '/qn', '/norestart')) -eq 0) 'a silent install succeeds'
    foreach ($file in $required) { Check (Test-Path (Join-Path $folder $file)) "the install holds $file" }

    # A tray app has no window; running means still alive after a few seconds.
    $app = Start-Process (Join-Path $folder 'SSMConnect.exe') -PassThru
    Start-Sleep -Seconds 8
    Check (-not $app.HasExited) 'SSM Connect starts and keeps running'
    $helper = Get-Process SSMConnectHelper -ErrorAction SilentlyContinue
    Check ($null -ne $helper) 'SSM Connect starts its helper'

    $code = Invoke-Msi @('/i', "`"$Msi`"", '/qn', '/norestart')
    Check ($code -eq 1603) "a silent reinstall while SSM Connect runs is refused (exit $code)"
    Check (-not $app.HasExited) 'the refused reinstall leaves SSM Connect running'

    # The helper's job is kill-on-close: ending the shell ends it once Windows closes the shell's handles.
    $helperIds = @($helper | ForEach-Object Id)
    Stop-Process -Id $app.Id -Force
    $app.WaitForExit()
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ((Get-Process -Id $helperIds -ErrorAction SilentlyContinue) -and $watch.Elapsed.TotalSeconds -lt 15) { Start-Sleep -Milliseconds 200 }
    $remaining = @(Get-Process -Id $helperIds -ErrorAction SilentlyContinue)
    Check ($remaining.Count -eq 0) "quitting SSM Connect ends its helper (after $([math]::Round($watch.Elapsed.TotalSeconds, 1)) s)"
    Check ((Invoke-Msi @('/i', "`"$Msi`"", '/qn', '/norestart')) -eq 0) 'a silent reinstall after quitting succeeds'
    Check ((Invoke-Msi @('/x', "`"$Msi`"", '/qn', '/norestart')) -eq 0) 'a silent uninstall succeeds'
    Check (-not (Test-Path $folder)) 'the uninstall leaves no program folder'
}

if ($failures.Count -gt 0) { throw "$($failures.Count) package check(s) failed." }
Write-Host 'Every package check passed.'
# An explicit status: the last native command run above (the proxy, which exits 1 without
# arguments) would otherwise become this script's exit code under GitHub's pwsh wrapper.
exit 0
