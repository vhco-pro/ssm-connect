# Clean-environment lifecycle for the real release MSI: install, verify the payload and the
# plugin redistribution files, launch, upgrade, uninstall, and check for residue.
$ErrorActionPreference = 'Stop'
$result = 'C:\SSMConnectDist\release-result.txt'
$installDirectory = Join-Path $env:LOCALAPPDATA 'Programs\SSM Connect'
$executable = Join-Path $installDirectory 'SSMConnect.exe'
$pluginDirectory = Join-Path $installDirectory 'session-manager-plugin'
$lines = [System.Collections.Generic.List[string]]::new()

try {
    $msi = (Get-ChildItem 'C:\SSMConnectDist\*.msi' | Sort-Object Name | Select-Object -First 1).FullName
    $lines.Add("Installing $(Split-Path -Leaf $msi)")

    $install = Start-Process msiexec.exe -ArgumentList @(
        '/i', $msi, '/qn', '/norestart', '/l*v', 'C:\SSMConnectDist\release-install.log') -Wait -PassThru
    $lines.Add("InstallExitCode=$($install.ExitCode)")
    $lines.Add("AppInstalled=$(Test-Path $executable)")

    # Apache-2.0 section 4 obligations must actually reach the machine, not just the .wxs.
    foreach ($name in 'LICENSE', 'NOTICE', 'THIRD-PARTY') {
        $lines.Add("Plugin${name}=$(Test-Path (Join-Path $pluginDirectory $name))")
    }
    $pluginBinary = Join-Path $pluginDirectory 'session-manager-plugin.exe'
    $lines.Add("PluginBinary=$(Test-Path $pluginBinary)")
    $lines.Add("AppLicense=$(Test-Path (Join-Path $installDirectory 'LICENSE'))")
    $lines.Add("StartMenuShortcut=$(Test-Path (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\SSM Connect\SSM Connect.lnk'))")

    if ($install.ExitCode -ne 0 -or -not (Test-Path $executable)) { throw 'Silent install failed.' }

    # Redistribution is only satisfied if the binary and all three notices actually arrive.
    if (-not (Test-Path $pluginBinary)) { throw 'The bundled Session Manager plugin was not installed.' }
    foreach ($name in 'LICENSE', 'NOTICE', 'THIRD-PARTY') {
        if (-not (Test-Path (Join-Path $pluginDirectory $name))) {
            throw "The plugin $name was not installed, which Apache-2.0 section 4 requires."
        }
    }

    # The app is a tray application with no window, so "it ran" means it stayed alive.
    $app = Start-Process $executable -PassThru
    Start-Sleep -Seconds 20
    $alive = -not $app.HasExited
    $lines.Add("AppStaysRunning=$alive")
    if ($alive) { Stop-Process -Id $app.Id -Force }
    if (-not $alive) { throw "The app exited immediately (code $($app.ExitCode))." }

    $uninstall = Start-Process msiexec.exe -ArgumentList @(
        '/x', $msi, '/qn', '/norestart', '/l*v', 'C:\SSMConnectDist\release-uninstall.log') -Wait -PassThru
    $lines.Add("UninstallExitCode=$($uninstall.ExitCode)")
    $lines.Add("PayloadResidue=$(Test-Path $executable)")
    $lines.Add("DirectoryResidue=$(Test-Path $installDirectory)")

    if ($uninstall.ExitCode -ne 0 -or (Test-Path $installDirectory)) { throw 'Uninstall or residue check failed.' }

    $lines.Add('PASS: clean-environment install, plugin redistribution, launch, uninstall, and residue checks succeeded.')
}
catch {
    $lines.Add("FAIL: $($_.Exception.Message)")
}
finally {
    $lines | Set-Content -Path $result -Encoding utf8
    shutdown.exe /s /t 0
}
