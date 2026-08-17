$ErrorActionPreference = 'Stop'
$resultPath = 'C:\SSMConnectDist\sandbox-result.txt'
$installDirectory = Join-Path $env:LOCALAPPDATA 'Programs\SSM Connect Windows Spike'
$executable = Join-Path $installDirectory 'SSMConnect.WindowsSpikes.exe'
$lines = [System.Collections.Generic.List[string]]::new()

try {
    $install = Start-Process msiexec.exe -ArgumentList @(
        '/i', 'C:\SSMConnectDist\SSMConnect-Windows-Spike-0.0.1.msi',
        '/qn', '/norestart', '/l*v', 'C:\SSMConnectDist\sandbox-install.log'
    ) -Wait -PassThru
    $lines.Add("InstallExitCode=$($install.ExitCode)")
    $lines.Add("Installed=$(Test-Path $executable)")
    if ($install.ExitCode -ne 0 -or -not (Test-Path $executable)) {
        throw 'Silent install failed.'
    }

    $hostOutput = & $executable host 2>&1
    $lines.AddRange([string[]]$hostOutput)
    if ($LASTEXITCODE -ne 0) {
        throw 'Installed payload failed.'
    }

    $crashOutput = & $executable crash 2>&1
    $lines.AddRange([string[]]$crashOutput)
    if ($LASTEXITCODE -ne 0) {
        throw 'Job Object crash containment failed.'
    }

    $upgrade = Start-Process msiexec.exe -ArgumentList @(
        '/i', 'C:\SSMConnectDist\SSMConnect-Windows-Spike-0.0.2.msi',
        '/qn', '/norestart', '/l*v', 'C:\SSMConnectDist\sandbox-upgrade.log'
    ) -Wait -PassThru
    $lines.Add("UpgradeExitCode=$($upgrade.ExitCode)")
    if ($upgrade.ExitCode -ne 0) {
        throw 'Silent upgrade failed.'
    }

    $uninstall = Start-Process msiexec.exe -ArgumentList @(
        '/x', 'C:\SSMConnectDist\SSMConnect-Windows-Spike-0.0.2.msi',
        '/qn', '/norestart', '/l*v', 'C:\SSMConnectDist\sandbox-uninstall.log'
    ) -Wait -PassThru
    $lines.Add("UninstallExitCode=$($uninstall.ExitCode)")
    $lines.Add("PayloadResidue=$(Test-Path $executable)")
    $lines.Add("DirectoryResidue=$(Test-Path $installDirectory)")
    if ($uninstall.ExitCode -ne 0 -or (Test-Path $executable) -or (Test-Path $installDirectory)) {
        throw 'Silent uninstall or residue check failed.'
    }

    $lines.Add('PASS: clean Sandbox install, launch, upgrade, uninstall, and residue checks succeeded.')
}
catch {
    $lines.Add("FAIL: $($_.Exception.Message)")
}
finally {
    $lines | Set-Content -Path $resultPath -Encoding utf8
    shutdown.exe /s /t 0
}