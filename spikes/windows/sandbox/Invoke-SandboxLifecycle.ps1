<#
.SYNOPSIS
    Runs the clean-environment installer lifecycle in Windows Sandbox and waits for its result.

.DESCRIPTION
    On the packaged Windows Sandbox app (MSIX MicrosoftWindows.WindowsSandbox),
    C:\Windows\System32\WindowsSandbox.exe is a fire-and-forget launcher: it returns
    exit code 0 within ~200 ms while the sandbox boots asynchronously in the background.
    Treating that exit code as the test result reports a false negative.

    The sandbox therefore signals completion out of band, by writing a result file into
    the read-write mapped folder. This driver clears that file, launches the
    configuration, and polls the mapped folder until the result appears or the timeout
    elapses.
#>
[CmdletBinding()]
param(
    [string] $RepositoryRoot,
    [int] $TimeoutSeconds = 900
)

$ErrorActionPreference = 'Stop'

if (-not $RepositoryRoot) {
    $scriptDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
    $RepositoryRoot = (Resolve-Path (Join-Path $scriptDirectory '..\..\..')).Path
}

$distDirectory = Join-Path $RepositoryRoot 'dist'
$configuration = Join-Path $distDirectory 'windows-phase0.wsb'
$resultPath = Join-Path $distDirectory 'sandbox-result.txt'

foreach ($required in @($configuration, (Join-Path $distDirectory 'SSMConnect-Windows-Spike-0.0.1.msi'), (Join-Path $distDirectory 'SSMConnect-Windows-Spike-0.0.2.msi'))) {
    if (-not (Test-Path $required)) {
        throw "Missing sandbox input: $required"
    }
}

Remove-Item $resultPath -ErrorAction SilentlyContinue

$launcher = Start-Process 'C:\Windows\System32\WindowsSandbox.exe' -ArgumentList $configuration -Wait -PassThru
Write-Host "Launcher returned $($launcher.ExitCode) (asynchronous; not the test result)."

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
while ((Get-Date) -lt $deadline) {
    if (Test-Path $resultPath) {
        $result = Get-Content $resultPath
        $result | Write-Host
        if ($result -match '^PASS: clean Sandbox') {
            exit 0
        }

        Write-Error 'Sandbox lifecycle reported a failure.'
        exit 1
    }

    Start-Sleep -Seconds 5
}

Write-Error "No sandbox result within $TimeoutSeconds seconds. Inspect running sandboxes with 'wsb list'."
exit 1
