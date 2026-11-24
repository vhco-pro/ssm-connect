# Copyright (c) 2026 VH & Co BV. Licensed under the Apache License 2.0. See LICENSE for details.
<#
.SYNOPSIS
    Inspects a built MSI and, with -Install, installs, upgrades over a running copy and removes it.

.DESCRIPTION
    Unpacks the MSI with an administrative install and checks that it holds the shell, the helper,
    the editor proxy, the Swift runtime they import, the Session Manager plugin and every required
    notice; that the helper starts from the unpacked folder with only System32 on PATH and reports
    the expected build; that the WinGet manifest pins the MSI's SHA-256; that the MSI removes the
    prior version only after InstallFinalize; and that no custom action runs between RegisterUser and
    InstallFinalize.

    With -Install (a disposable machine such as a CI runner), it also installs the MSI silently,
    starts SSM Connect, checks that a silent reinstall refuses while it runs and leaves it running,
    quits it, reinstalls, and uninstalls, checking that the program folder is gone afterwards. Then
    it upgrades a prior copy whose Swift runtime carries a higher file version than this package's,
    as a build from a newer toolchain leaves it, and checks that every file of this package is laid
    down and the helper starts. It then fails an upgrade of a prior copy with a copy of this MSI whose
    deferred custom action fails once its files are laid down, and checks that the rollback
    leaves the prior copy installed and registered, so this MSI then replaces it and uninstalls with
    nothing left. Last, it upgrades a prior copy whose own removal fails under an upgrade, checks
    that the new version works and uninstalls, and reports what the failed removal left.

    With -Interactive as well (run from the signed-in user's session, which shows the installer), it
    cancels an upgrade of a running prior copy at Restart Manager's files-in-use prompt and checks
    that the prior copy stays installed, registered and running.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Msi,
    [Parameter(Mandatory)] [string] $Build,
    [string] $Manifest,
    [switch] $Install,
    [switch] $Interactive
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

# The prior version is removed only once this one is installed and registered: a rollback from the
# user's unelevated session cannot rewrite per-user registration, so nothing may fail after the removal.
$schedule = @{}
$sequenceApi = New-Object -ComObject WindowsInstaller.Installer
$sequenceDatabase = Invoke-Com $sequenceApi 'OpenDatabase' -arguments @([string] $Msi, 0)
$sequenceView = Invoke-Com $sequenceDatabase 'OpenView' -arguments @("SELECT ``Action``, ``Sequence`` FROM ``InstallExecuteSequence``")
Invoke-Com $sequenceView 'Execute' | Out-Null
while ($sequenceRecord = Invoke-Com $sequenceView 'Fetch') {
    $schedule[(Invoke-Com $sequenceRecord 'StringData' 'GetProperty' @(1))] = Invoke-Com $sequenceRecord 'IntegerData' 'GetProperty' @(2)
    [Runtime.InteropServices.Marshal]::ReleaseComObject($sequenceRecord) | Out-Null
}
Invoke-Com $sequenceView 'Close' | Out-Null
$customActions = @()
$actionView = Invoke-Com $sequenceDatabase 'OpenView' -arguments @("SELECT ``Action`` FROM ``CustomAction``")
Invoke-Com $actionView 'Execute' | Out-Null
while ($actionRecord = Invoke-Com $actionView 'Fetch') {
    $customActions += Invoke-Com $actionRecord 'StringData' 'GetProperty' @(1)
    [Runtime.InteropServices.Marshal]::ReleaseComObject($actionRecord) | Out-Null
}
Invoke-Com $actionView 'Close' | Out-Null
foreach ($handle in $actionView, $sequenceView, $sequenceDatabase) { [Runtime.InteropServices.Marshal]::ReleaseComObject($handle) | Out-Null }
# Between registering itself and InstallFinalize only Windows Installer's own publishing steps may run:
# a failure there leaves this version's registration behind.
$late = @($schedule.Keys | Where-Object { $customActions -contains $_ -and $schedule[$_] -gt $schedule['RegisterUser'] -and $schedule[$_] -lt $schedule['InstallFinalize'] })
Check ($late.Count -eq 0) "no custom action runs between RegisterUser and InstallFinalize$(if ($late) { ' (found ' + ($late -join ', ') + ')' })"
Check ($schedule['RemoveExistingProducts'] -gt $schedule['InstallFinalize']) "the MSI removes the prior version after InstallFinalize (RemoveExistingProducts $($schedule['RemoveExistingProducts']), InstallFinalize $($schedule['InstallFinalize']))"
[GC]::Collect(); [GC]::WaitForPendingFinalizers()

if ($Install) {
    $folder = Join-Path $env:LOCALAPPDATA 'Programs\SSM Connect'
    Check ((Invoke-Msi @('/i', "`"$Msi`"", '/qn', '/norestart')) -eq 0) 'a silent install succeeds'
    foreach ($file in $required) { Check (Test-Path (Join-Path $folder $file)) "the install holds $file" }
    # The installer has run the helper once, so its first start here fits the 10-second handshake
    # even while Microsoft Defender checks new, unsigned executables.
    $watch = [Diagnostics.Stopwatch]::StartNew()
    & (Join-Path $folder 'SSMConnectHelper.exe') --build | Out-Null
    Check ($watch.Elapsed.TotalSeconds -lt 10) "the helper's first start after the install takes under 10 seconds ($([math]::Round($watch.Elapsed.TotalSeconds, 1)) s)"

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

if ($Install) {
    $folder = Join-Path $env:LOCALAPPDATA 'Programs\SSM Connect'
    $api = New-Object -ComObject WindowsInstaller.Installer
    $upgradeCode = (Select-String -Path (Join-Path $PSScriptRoot 'Package.wxs') -Pattern 'UpgradeCode="([^"]+)"').Matches[0].Groups[1].Value
    function Related { @(try { $api.RelatedProducts("{$upgradeCode}") } catch { @() }) }

    # A copy of this MSI under new package (and, for a prior copy, product) codes. -FailBefore and
    # -FailAfter add a deferred custom action that fails at the free sequence number closest before or
    # after the named action, under the condition -FailWhen.
    function New-MsiCopy([switch] $NewProduct, [string] $FailBefore, [string] $FailAfter, [string] $FailWhen = '') {
        $path = Join-Path ([IO.Path]::GetTempPath()) ('ssm-copy-' + [guid]::NewGuid().ToString('N') + '.msi')
        Copy-Item $Msi $path
        $database = Invoke-Com $api 'OpenDatabase' -arguments @([string] $path, 1)
        $queries = @()
        $productCode = $null
        if ($NewProduct) {
            $productCode = '{' + [guid]::NewGuid().ToString().ToUpper() + '}'
            $queries += "UPDATE ``Property`` SET ``Value`` = '$productCode' WHERE ``Property`` = 'ProductCode'"
        }
        if ($FailBefore -or $FailAfter) {
            $sequences = @{}
            $view = Invoke-Com $database 'OpenView' -arguments @("SELECT ``Action``, ``Sequence`` FROM ``InstallExecuteSequence``")
            Invoke-Com $view 'Execute' | Out-Null
            while ($record = Invoke-Com $view 'Fetch') {
                $sequences[(Invoke-Com $record 'StringData' 'GetProperty' @(1))] = Invoke-Com $record 'IntegerData' 'GetProperty' @(2)
                [Runtime.InteropServices.Marshal]::ReleaseComObject($record) | Out-Null
            }
            Invoke-Com $view 'Close' | Out-Null
            [Runtime.InteropServices.Marshal]::ReleaseComObject($view) | Out-Null
            $step = if ($FailBefore) { -1 } else { 1 }
            $sequence = $sequences[$(if ($FailBefore) { $FailBefore } else { $FailAfter })] + $step
            while ($sequences.Values -contains $sequence) { $sequence += $step }
            $cmd = Join-Path $env:SystemRoot 'System32\cmd.exe'
            $queries += "INSERT INTO ``Property`` (``Property``, ``Value``) VALUES ('TESTFAILCMD', '$cmd')"
            # 50 (an executable named by a property) + 1024 (deferred): runs inside the transaction.
            $queries += "INSERT INTO ``CustomAction`` (``Action``, ``Type``, ``Source``, ``Target``) VALUES ('FailForTest', 1074, 'TESTFAILCMD', '/c exit 1')"
            $queries += "INSERT INTO ``InstallExecuteSequence`` (``Action``, ``Condition``, ``Sequence``) VALUES ('FailForTest', '$FailWhen', $sequence)"
        }
        foreach ($query in $queries) {
            $view = Invoke-Com $database 'OpenView' -arguments @($query)
            Invoke-Com $view 'Execute' | Out-Null
            Invoke-Com $view 'Close' | Out-Null
            [Runtime.InteropServices.Marshal]::ReleaseComObject($view) | Out-Null
        }
        $summary = Invoke-Com $database 'SummaryInformation' 'GetProperty' @(4)
        # Parentheses: the comma binds tighter than +.
        Invoke-Com $summary 'Property' 'SetProperty' @(9, ('{' + [guid]::NewGuid().ToString().ToUpper() + '}')) | Out-Null
        Invoke-Com $summary 'Persist' | Out-Null
        Invoke-Com $database 'Commit' | Out-Null
        foreach ($handle in $summary, $database) { [Runtime.InteropServices.Marshal]::ReleaseComObject($handle) | Out-Null }
        # msiexec cannot open a package this process still holds.
        [GC]::Collect(); [GC]::WaitForPendingFinalizers()
        [pscustomobject]@{ Path = $path; ProductCode = $productCode }
    }

    # An upgrade that fails once its files are laid down, just before it registers itself, leaves the
    # prior version installed and registered, whether the prior version's removal was scheduled before
    # the failure or after InstallFinalize. Rolling back a registration from an unelevated session fails:
    # Windows Installer secures the product key to Administrators, so nothing of this package may fail
    # after RegisterUser.
    $prior = New-MsiCopy -NewProduct
    $code = Invoke-Msi @('/i', "`"$($prior.Path)`"", '/qn', '/norestart')
    Check ($code -eq 0) "a prior copy installs for the failed upgrade (exit $code, $($prior.Path))"
    $failing = New-MsiCopy -FailBefore RegisterUser
    $log = Join-Path ([IO.Path]::GetTempPath()) 'ssm-failed-upgrade.log'
    $code = Invoke-Msi @('/i', "`"$($failing.Path)`"", '/qn', '/norestart', '/l*v', "`"$log`"")
    Check ($code -eq 1603) "an upgrade failing once its files are laid down fails (exit $code)"
    $text = Get-Content $log -Raw
    $laidDown = $text.IndexOf('Doing action: InstallFiles')
    $failed = $text.IndexOf('Doing action: FailForTest')
    Check ($laidDown -ge 0 -and $failed -gt $laidDown) "the log shows the failure after this version's files were laid down"
    Check ($text.Contains('Rollback')) 'the log shows the rollback'
    Check ((Related) -contains $prior.ProductCode) 'the rolled-back prior copy is still registered for the next upgrade'
    Check (Test-Path (Join-Path $folder 'SSMConnectHelper.exe')) "the rolled-back prior copy's files are back"
    Check ((Invoke-Msi @('/i', "`"$Msi`"", '/qn', '/norestart')) -eq 0) 'the next upgrade replaces the prior copy'
    Check (-not ((Related) -contains $prior.ProductCode)) 'the prior copy is no longer registered after that upgrade'
    Check ((Invoke-Msi @('/x', "`"$Msi`"", '/qn', '/norestart')) -eq 0) 'the upgraded install uninstalls after the failed upgrade'
    Check (-not (Test-Path $folder)) 'that uninstall leaves no program folder'
    Check (@(Related).Count -eq 0) 'no product of the upgrade code remains'
    Remove-Item $prior.Path, $failing.Path, $log -Force -ErrorAction SilentlyContinue

    if ($Interactive) {
        # Cancel at Restart Manager's prompt, before anything changes. The installer's controls are plain
        # panes to UI Automation, so they are clicked by position.
        Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
        Add-Type -Namespace Win32 -Name Input -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y); [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, System.UIntPtr e); [DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);'
        $ae = [Windows.Automation.AutomationElement]; $scope = [Windows.Automation.TreeScope]
        $windowType = [Windows.Automation.PropertyCondition]::new($ae::ControlTypeProperty, [Windows.Automation.ControlType]::Window)
        $paneType = [Windows.Automation.PropertyCondition]::new($ae::ControlTypeProperty, [Windows.Automation.ControlType]::Pane)
        # Finds a pane by name in the installer's windows, or only in $within; returns the pane and its window.
        function Find-Pane([string] $pattern, [int] $seconds, $within = $null) {
            $deadline = (Get-Date).AddSeconds($seconds)
            while ((Get-Date) -lt $deadline) {
                $windows = if ($within) { @($within) } else { $ae::RootElement.FindAll($scope::Children, $windowType) }
                foreach ($window in $windows) {
                    if ($window.Current.Name -notmatch 'SSM Connect Setup') { continue }
                    foreach ($pane in $window.FindAll($scope::Descendants, $paneType)) {
                        if ($pane.Current.Name -match $pattern) { return [pscustomobject]@{ Pane = $pane; Window = $window } }
                    }
                }
                Start-Sleep -Milliseconds 500
            }
            return $null
        }
        function Press($found) {
            # The installer's window must be in front for a click to reach it.
            [Win32.Input]::SetForegroundWindow([IntPtr]$found.Window.Current.NativeWindowHandle) | Out-Null
            Start-Sleep -Milliseconds 300
            $r = $found.Pane.Current.BoundingRectangle
            [Win32.Input]::SetCursorPos([int]($r.X + $r.Width / 2), [int]($r.Y + $r.Height / 2)) | Out-Null
            Start-Sleep -Milliseconds 150
            [Win32.Input]::mouse_event(0x2, 0, 0, 0, [UIntPtr]::Zero); [Win32.Input]::mouse_event(0x4, 0, 0, 0, [UIntPtr]::Zero)
            Start-Sleep -Milliseconds 500
        }
        $prior = New-MsiCopy -NewProduct
        Check ((Invoke-Msi @('/i', "`"$($prior.Path)`"", '/qn', '/norestart')) -eq 0) 'a prior copy installs for the cancelled upgrade'
        $app = Start-Process (Join-Path $folder 'SSMConnect.exe') -PassThru
        Start-Sleep -Seconds 8
        $installer = Start-Process msiexec.exe -PassThru -ArgumentList @('/i', "`"$Msi`"")
        $null = $installer.Handle # PowerShell reports no exit code unless the handle is read while it runs
        $accept = Find-Pane 'accept' 120
        if ($accept) { Press $accept; Start-Sleep -Seconds 2 }
        # Install is enabled a moment after the license is accepted, so it is pressed until the installer
        # moves on, and a click on the checkbox that did not land is repeated. Not $install: PowerShell
        # names are case-insensitive, and -Install is this script's switch.
        $close = $null
        for ($try = 0; $try -lt 4 -and -not $close; $try++) {
            $installButton = Find-Pane '^&?Install$|^&?Upgrade$' 10
            if ($installButton -and $accept -and -not $installButton.Pane.Current.IsEnabled) { Press $accept; Start-Sleep -Seconds 1 }
            if ($installButton) { Press $installButton }
            $close = Find-Pane 'Close SSM Connect' 30
        }
        Check ($null -ne $close) "Restart Manager's prompt offers closing SSM Connect"
        # The prompt's own Cancel: the wizard behind it has one too.
        $cancel = if ($close) { Find-Pane '^&?Cancel$' 10 $close.Window } else { $null }
        if ($cancel) { Press $cancel }
        # The installer may ask to confirm the cancel, then shows its interrupted page.
        $deadline = (Get-Date).AddSeconds(60)
        while ($cancel -and -not $installer.HasExited -and (Get-Date) -lt $deadline) {
            foreach ($step in '^&?Yes$', '^&?Finish$') { $button = Find-Pane $step 1; if ($button) { Press $button } }
        }
        # An installer left open would hold the next check's msiexec.
        if (-not $installer.HasExited) { Stop-Process -Id $installer.Id -Force -ErrorAction SilentlyContinue }
        $installer.WaitForExit(60000) | Out-Null
        Check ($installer.ExitCode -eq 1602) "the cancelled upgrade ends with nothing changed (exit $($installer.ExitCode))"
        Check (-not $app.HasExited) 'SSM Connect keeps running after the cancel'
        Check ((Related) -contains $prior.ProductCode) 'the prior copy is still registered after the cancel'
        Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 3
        Check ((Invoke-Msi @('/i', "`"$Msi`"", '/qn', '/norestart')) -eq 0) 'the next upgrade replaces the prior copy after the cancel'
        Check ((Invoke-Msi @('/x', "`"$Msi`"", '/qn', '/norestart')) -eq 0) 'that install uninstalls'
        Check (-not (Test-Path $folder)) 'that uninstall leaves no program folder'
        Remove-Item $prior.Path -Force -ErrorAction SilentlyContinue
    }

    # The prior version is removed after InstallFinalize, in a transaction of its own. When that removal
    # fails, only the removal rolls back and the new version stays installed. Run from the user's session,
    # that rollback cannot restore the prior version's registration, a known limit: what is left is
    # reported, not checked. The prior copy's removal fails only under an upgrade.
    $prior = New-MsiCopy -NewProduct -FailAfter InstallInitialize -FailWhen 'REMOVE~="ALL" AND UPGRADINGPRODUCTCODE'
    $code = Invoke-Msi @('/i', "`"$($prior.Path)`"", '/qn', '/norestart')
    Check ($code -eq 0) "a prior copy whose removal fails under an upgrade installs (exit $code)"
    $code = Invoke-Msi @('/i', "`"$Msi`"", '/qn', '/norestart')
    Write-Host "     the upgrade over it exits $code"
    $own = @(Related | Where-Object { $_ -ne $prior.ProductCode })
    Check ($own.Count -eq 1) 'the new version is installed and registered'
    & (Join-Path $folder 'SSMConnectHelper.exe') --build | Out-Null
    Check ($LASTEXITCODE -eq 0) "the new version's helper starts (exit $LASTEXITCODE)"
    $listed = (Related) -contains $prior.ProductCode
    Write-Host "     the prior copy is $(if ($listed) { 'still' } else { 'no longer' }) listed"
    if ($listed) { Write-Host "     uninstalling the prior copy exits $(Invoke-Msi @('/x', $prior.ProductCode, '/qn', '/norestart'))" }
    Check ((Invoke-Msi @('/x', "`"$Msi`"", '/qn', '/norestart')) -eq 0) 'the new version uninstalls'
    Write-Host "     the program folder $(if (Test-Path $folder) { 'is left behind' } else { 'is gone' }); products of the upgrade code left: $(@(Related).Count)"
    # The known limit can leave files behind: clear them so the next run starts without them.
    if (Test-Path $folder) { Remove-Item $folder -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Item $prior.Path -Force -ErrorAction SilentlyContinue
}

if ($failures.Count -gt 0) { throw "$($failures.Count) package check(s) failed." }
Write-Host 'Every package check passed.'
# An explicit status: the last native command run above (the proxy, which exits 1 without
# arguments) would otherwise become this script's exit code under GitHub's pwsh wrapper.
exit 0
