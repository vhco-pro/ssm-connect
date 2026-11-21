# Builds the T4 feasibility helper on Windows from the app's current portable sources.
# Usage: powershell -ExecutionPolicy Bypass -File spikes\helper-feasibility\run.ps1
# Needs a Swift 6.4 toolchain with Visual Studio 2022 Build Tools (PDS Install-SwiftToolchain).
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$root = Resolve-Path (Join-Path $here '..\..')
$reused = Join-Path $here 'Sources\HelperSpike\Reused'
Remove-Item -Recurse -Force $reused -ErrorAction SilentlyContinue
New-Item -ItemType Directory $reused | Out-Null
foreach ($file in 'Models\SSMSessionResponse.swift', 'Models\AWSRegion.swift', 'Auth\IdentityMapper.swift') {
    Copy-Item (Join-Path $root "SSMConnectKit\Sources\SSMConnectKit\$file") $reused
}
Set-Location $here
swift build -c release
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
"built: $(swift build -c release --show-bin-path)\HelperSpike.exe"
