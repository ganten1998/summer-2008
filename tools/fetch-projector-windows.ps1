<#
.SYNOPSIS
  Hydrate projector-windows\ with the Flash + Shockwave Projector
  binaries needed to build the Windows installer.

.DESCRIPTION
  Default path: downloads a 80 MB tarball from this repo's
    build-deps-v1 GitHub Release
  and unpacks it into projector-windows\. Zero dependencies — no
  Flashpoint install required.

  If you ALREADY have a Flashpoint Infinity / Ultimate install locally,
  set FLASHPOINT_PATH and we'll copy from there instead (saves the
  download).

.PARAMETER FlashpointPath
  Optional explicit path to a Flashpoint install root containing
  FPSoftware\Shockwave and FPSoftware\Flash. Default: auto-detect, then
  fall back to GitHub release download.

.PARAMETER Force
  Re-hydrate even if projector-windows\ already looks populated.

.NOTES
  This script is only needed for BUILDING the installer from source.
  END USERS download the prebuilt .exe installer from the v1.0.0 release;
  it has all projectors baked in.
#>

[CmdletBinding()]
param(
    [string]$FlashpointPath = $env:FLASHPOINT_PATH,
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$Dest = Join-Path $Root "projector-windows"
$ReleaseURL = "https://github.com/ganten7/summer-2008/releases/download/build-deps-v1/projector-windows.tar.gz"

function Test-Populated([string]$path) {
    (Test-Path (Join-Path $path "Flash\flashplayer_32_sa.exe")) -and `
    (Test-Path (Join-Path $path "Shockwave\PJ12\Projector.exe"))
}

if ((Test-Populated $Dest) -and -not $Force) {
    Write-Host "✓ projector-windows\ already populated — skip. Use -Force to re-hydrate."
    exit 0
}

# ── Path 1: explicit FLASHPOINT_PATH ────────────────────────────────────
if ($FlashpointPath -and (Test-Path (Join-Path $FlashpointPath "FPSoftware\Shockwave"))) {
    Write-Host "✓ Copying from explicit Flashpoint: $FlashpointPath"
    if (Test-Path $Dest) { Remove-Item $Dest -Recurse -Force }
    robocopy (Join-Path $FlashpointPath "FPSoftware\Flash")     (Join-Path $Dest "Flash")     /MIR /NFL /NDL /NJH /NJS /NC /NS | Out-Null
    robocopy (Join-Path $FlashpointPath "FPSoftware\Shockwave") (Join-Path $Dest "Shockwave") /MIR /NFL /NDL /NJH /NJS /NC /NS | Out-Null
    Write-Host "Done."
    exit 0
}

# ── Path 2: auto-detect a local Flashpoint install ───────────────────────
$autoFP = $null
foreach ($parent in @("$HOME\Documents", "$HOME\Downloads", "$env:APPDATA",
                       "$env:LOCALAPPDATA", "C:\", "D:\", "$HOME")) {
    if (-not (Test-Path $parent)) { continue }
    Get-ChildItem -Path $parent -Directory -Filter "Flashpoint*" -ErrorAction SilentlyContinue |
    ForEach-Object {
        if ((Test-Path (Join-Path $_.FullName "FPSoftware\Shockwave")) -and `
            (Test-Path (Join-Path $_.FullName "FPSoftware\Flash"))) {
            $autoFP = $_.FullName
        }
    }
    if ($autoFP) { break }
}
if ($autoFP) {
    Write-Host "✓ Found local Flashpoint at: $autoFP — copying"
    if (Test-Path $Dest) { Remove-Item $Dest -Recurse -Force }
    robocopy (Join-Path $autoFP "FPSoftware\Flash")     (Join-Path $Dest "Flash")     /MIR /NFL /NDL /NJH /NJS /NC /NS | Out-Null
    robocopy (Join-Path $autoFP "FPSoftware\Shockwave") (Join-Path $Dest "Shockwave") /MIR /NFL /NDL /NJH /NJS /NC /NS | Out-Null
    Write-Host "Done."
    exit 0
}

# ── Path 3: download the build-deps tarball from this repo ───────────────
Write-Host "==> No local Flashpoint found — downloading from build-deps release"
Write-Host "    Source: $ReleaseURL"
$Tmp = New-TemporaryFile
$Tar = "$($Tmp.FullName).tar.gz"
Move-Item $Tmp.FullName $Tar -Force

try {
    # PowerShell 5.1 doesn't have tar built in on every system, but
    # Windows 10 1803+ does ship a native tar.exe at System32\tar.exe.
    # Also: Invoke-WebRequest is much slower than .NET HttpClient for
    # ~80 MB files, so use HttpClient when available.
    $client = New-Object System.Net.Http.HttpClient
    $resp   = $client.GetAsync($ReleaseURL).Result
    if (-not $resp.IsSuccessStatusCode) {
        throw "HTTP $($resp.StatusCode) downloading $ReleaseURL"
    }
    $bytes = $resp.Content.ReadAsByteArrayAsync().Result
    [System.IO.File]::WriteAllBytes($Tar, $bytes)
    Write-Host "    Downloaded $([Math]::Round($bytes.Length / 1MB, 1)) MB"

    if (Test-Path $Dest) { Remove-Item $Dest -Recurse -Force }
    New-Item -ItemType Directory -Path $Dest | Out-Null

    Write-Host "==> Unpacking"
    # The tarball top-level dir is projector-windows/, so unpack to parent.
    & tar -xzf $Tar -C (Split-Path -Parent $Dest)
    if ($LASTEXITCODE -ne 0) { throw "tar -xzf failed" }
    Write-Host "Done."
} finally {
    Remove-Item $Tar -ErrorAction SilentlyContinue
}

if (-not (Test-Populated $Dest)) {
    throw "projector-windows\ doesn't look populated after hydration — investigate."
}
Get-ChildItem $Dest -Directory | ForEach-Object {
    $size = (Get-ChildItem $_.FullName -Recurse -ErrorAction SilentlyContinue |
             Measure-Object -Property Length -Sum).Sum
    "{0,-30} {1,8:N1} MB" -f $_.Name, ($size / 1MB)
}
