<#
.SYNOPSIS
    Downloads, verifies, and extracts the official AWS Session Manager plugin for Windows.

.DESCRIPTION
    The Windows counterpart of scripts/fetch-plugin.sh, and it follows the same supply-chain rule:
    the download is verified against a pinned SHA-256 and the check is never skipped. Specification
    section 12 requires it, and it is what makes bundling the plugin defensible — the release ships
    a binary whose provenance is asserted at build time rather than whatever happened to be on the
    build machine.

    The extracted layout matches the official installer's, so callers can point at this directory
    exactly as they would at C:\Program Files\Amazon\SessionManagerPlugin.

.PARAMETER Destination
    Where to place the verified plugin. Defaults to a cache directory under the repository.

.PARAMETER Force
    Re-download even if the cache already holds a verified copy.
#>
[CmdletBinding()]
param(
    [string] $Destination,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'

# Pinned deliberately. Bumping the version means re-recording both hashes; a mismatch is a hard
# failure, not a warning, because an unverified plugin is exactly the supply-chain risk this exists
# to close.
$PluginVersion = '1.2.835.0'
$ExpectedZipSha256 = 'C9133A86C0BEB2A4DD2258501B180F958973177662E7095325E5C9367B1707C2'
$ExpectedExeSha256 = '540F4F58C76142657F00A10510E1C87D9EF358FFFD3D402CE1C07B1B9B182704'
$DownloadUrl = "https://session-manager-downloads.s3.amazonaws.com/plugin/$PluginVersion/windows/SessionManagerPlugin.zip"

if (-not $Destination) {
    $repository = Split-Path -Parent $PSScriptRoot
    $Destination = Join-Path $repository '.build\plugin\windows'
}

$pluginExe = Join-Path $Destination 'bin\session-manager-plugin.exe'

function Get-Sha256([string] $Path) {
    (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToUpperInvariant()
}

if (-not $Force -and (Test-Path $pluginExe)) {
    if ((Get-Sha256 $pluginExe) -eq $ExpectedExeSha256) {
        Write-Host "session-manager-plugin $PluginVersion already cached and verified."
        return $Destination
    }

    Write-Warning 'Cached plugin failed verification; re-downloading.'
}

$staging = Join-Path ([System.IO.Path]::GetTempPath()) ("smp-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force -Path $staging | Out-Null

try {
    $zip = Join-Path $staging 'SessionManagerPlugin.zip'
    Write-Host "Downloading session-manager-plugin $PluginVersion..."
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $zip -UseBasicParsing

    $actualZip = Get-Sha256 $zip
    if ($actualZip -ne $ExpectedZipSha256) {
        throw "Download verification failed.`n  expected $ExpectedZipSha256`n  actual   $actualZip"
    }

    # The archive nests the payload: SessionManagerPlugin.zip contains package.zip alongside the
    # installer batch files, and package.zip holds the binary and the redistribution notices.
    Expand-Archive -Path $zip -DestinationPath (Join-Path $staging 'outer') -Force
    $package = Join-Path $staging 'outer\package.zip'
    if (-not (Test-Path $package)) {
        throw 'The archive did not contain package.zip; the upstream layout may have changed.'
    }

    $extracted = Join-Path $staging 'package'
    Expand-Archive -Path $package -DestinationPath $extracted -Force

    $extractedExe = Join-Path $extracted 'bin\session-manager-plugin.exe'
    if (-not (Test-Path $extractedExe)) {
        throw 'The package did not contain bin\session-manager-plugin.exe.'
    }

    $actualExe = Get-Sha256 $extractedExe
    if ($actualExe -ne $ExpectedExeSha256) {
        throw "Extracted binary verification failed.`n  expected $ExpectedExeSha256`n  actual   $actualExe"
    }

    # Apache-2.0 section 4 requires these to travel with the binary, so their absence is fatal
    # rather than cosmetic.
    foreach ($notice in 'LICENSE', 'NOTICE', 'THIRD-PARTY') {
        if (-not (Test-Path (Join-Path $extracted $notice))) {
            throw "The package is missing $notice, which redistribution requires."
        }
    }

    if (Test-Path $Destination) {
        Remove-Item $Destination -Recurse -Force
    }

    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
    Move-Item -Path $extracted -Destination $Destination

    Write-Host "Verified session-manager-plugin $PluginVersion into $Destination"
    return $Destination
}
finally {
    Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
}
