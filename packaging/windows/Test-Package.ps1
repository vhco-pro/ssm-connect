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
    quits it, reinstalls, and uninstalls, checking that the program folder is gone afterwards. Then
    it upgrades a prior copy whose Swift runtime carries a higher file version than this package's,
    as a build from a newer toolchain leaves it, and checks that every file of this package is laid
    down and the helper starts.
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
    # WinGet finds the installed app for upgrade and uninstall by the MSI's product code.
    $api = New-Object -ComObject WindowsInstaller.Installer
    $database = $api.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $api, @([string] $Msi, 0))
    $view = $database.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $database, @("SELECT ``Value`` FROM ``Property`` WHERE ``Property`` = 'ProductCode'"))
    $view.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $view, $null) | Out-Null
    $record = $view.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $view, $null)
    $productCode = $record.GetType().InvokeMember('StringData', 'GetProperty', $null, $record, @(1))
    $view.GetType().InvokeMember('Close', 'InvokeMethod', $null, $view, $null) | Out-Null
    foreach ($handle in $record, $view, $database) { [Runtime.InteropServices.Marshal]::ReleaseComObject($handle) | Out-Null }
    Check ($installer.Contains("ProductCode: '$productCode'")) "the WinGet manifest names the MSI's product code $productCode"
}
$runtimeHash = (Get-FileHash (Join-Path $root 'swiftCore.dll')).Hash
Remove-Item $image -Recurse -Force -ErrorAction SilentlyContinue

# Late-bound calls into the Windows Installer automation object.
function Invoke-Com($target, [string] $member, [string] $kind = 'InvokeMethod', [object[]] $arguments = @()) {
    $target.GetType().InvokeMember($member, $kind, $null, $target, $arguments)
}

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

    # A prior copy of this package under another product and package code, so this MSI upgrades it.
    $prior = Join-Path ([IO.Path]::GetTempPath()) ('ssm-prior-' + [guid]::NewGuid().ToString('N') + '.msi')
    Copy-Item $Msi $prior
    $api = New-Object -ComObject WindowsInstaller.Installer
    # A plain string: COM rejects the wrapped string Join-Path returns.
    $database = Invoke-Com $api 'OpenDatabase' -arguments @([string] $prior, 1)
    $view = Invoke-Com $database 'OpenView' -arguments @("UPDATE ``Property`` SET ``Value`` = '{$([guid]::NewGuid().ToString().ToUpper())}' WHERE ``Property`` = 'ProductCode'")
    Invoke-Com $view 'Execute' | Out-Null
    Invoke-Com $view 'Close' | Out-Null
    $summary = Invoke-Com $database 'SummaryInformation' 'GetProperty' @(4)
    Invoke-Com $summary 'Property' 'SetProperty' @(9, "{$([guid]::NewGuid().ToString().ToUpper())}") | Out-Null
    Invoke-Com $summary 'Persist' | Out-Null
    Invoke-Com $database 'Commit' | Out-Null
    # Every handle is released, or msiexec cannot open the package.
    foreach ($handle in $summary, $view, $database) { [Runtime.InteropServices.Marshal]::ReleaseComObject($handle) | Out-Null }
    Check ((Invoke-Msi @('/i', "`"$prior`"", '/qn', '/norestart')) -eq 0) 'the prior copy installs'
    # Its Swift runtime now carries a higher file version than this package's (kernel32.dll's 10.0).
    Copy-Item (Join-Path $env:SystemRoot 'System32\kernel32.dll') (Join-Path $folder 'swiftCore.dll') -Force
    Check ((Invoke-Msi @('/i', "`"$Msi`"", '/qn', '/norestart')) -eq 0) 'the upgrade over the prior copy succeeds'
    $installed = Join-Path $folder 'swiftCore.dll'
    Check ((Test-Path $installed) -and (Get-FileHash $installed).Hash -eq $runtimeHash) "the upgrade lays down this package's swiftCore.dll over a higher-versioned one"
    $saved = $env:Path
    try {
        $env:Path = "$env:SystemRoot\System32"
        $ErrorActionPreference = 'Continue'
        $reported = & (Join-Path $folder 'SSMConnectHelper.exe') --build 2>$null
        Check ($LASTEXITCODE -eq 0 -and "$reported".Trim() -eq $Build) "the upgraded helper starts (exit $LASTEXITCODE)"
        $ErrorActionPreference = 'Stop'
    } finally { $env:Path = $saved }
    Check ((Invoke-Msi @('/x', "`"$Msi`"", '/qn', '/norestart')) -eq 0) 'the upgraded install uninstalls'
    Check (-not (Test-Path $folder)) 'that uninstall leaves no program folder'
    Remove-Item $prior -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) { throw "$($failures.Count) package check(s) failed." }
Write-Host 'Every package check passed.'
# An explicit status: the last native command run above (the proxy, which exits 1 without
# arguments) would otherwise become this script's exit code under GitHub's pwsh wrapper.
exit 0
