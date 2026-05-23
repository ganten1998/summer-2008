<#
.SYNOPSIS
  Build the Windows .exe + Inno Setup installer for Summer 2008.

.DESCRIPTION
  Steps:
    1.  Restore + publish the .NET 8 single-file Win-x64 EXE
    2.  Stage everything into build\stage\ (EXE, Resources\, projector\)
    3.  Run Inno Setup to produce build\Summer-2008-Setup.exe

  Run this from PowerShell on Windows:
      cd app-windows
      .\build.ps1

  Prerequisites (one-time):
    • .NET 8 SDK    — https://dotnet.microsoft.com/download/dotnet/8.0
    • Inno Setup 6  — https://jrsoftware.org/isdl.php
                      (or `winget install JRSoftware.InnoSetup`)
    • Local Flashpoint install (Windows version), then run:
        ..\tools\fetch-projector-windows.ps1

.PARAMETER SkipPublish
  Use existing build\publish output instead of rebuilding.

.PARAMETER SkipInstaller
  Stop after producing the stage directory; don't drive Inno Setup.
#>

[CmdletBinding()]
param(
    [switch]$SkipPublish,
    [switch]$SkipInstaller
)

$ErrorActionPreference = "Stop"
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Root = Split-Path -Parent $Here

$Publish = Join-Path $Here "build\publish"
$Stage   = Join-Path $Here "build\stage"

if (-not $SkipPublish) {
    Write-Host "==> dotnet publish (Win-x64, single-file, self-contained)"
    dotnet publish (Join-Path $Here "Summer2008.csproj") `
        --configuration Release `
        --runtime win-x64 `
        --self-contained true `
        -p:PublishSingleFile=true `
        -p:IncludeAllContentForSelfExtract=true `
        -p:PublishReadyToRun=true `
        --output $Publish
    if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed" }
}

Write-Host "==> Staging files at $Stage"
if (Test-Path $Stage) { Remove-Item $Stage -Recurse -Force }
New-Item -ItemType Directory -Path $Stage | Out-Null

# Copy the publish output (.exe + Resources\ + projector\).
Copy-Item -Path "$Publish\*" -Destination $Stage -Recurse -Force

# Make sure the projector\ tree is present. If not, warn loudly.
$ProjectorStage = Join-Path $Stage "projector"
if (-not (Test-Path "$ProjectorStage\Shockwave") -or -not (Test-Path "$ProjectorStage\Flash")) {
    Write-Warning "Projector binaries missing — run ..\tools\fetch-projector-windows.ps1 first."
    Write-Warning "Without these, .dcr / external .swf playback will fail."
}

if ($SkipInstaller) {
    Write-Host "==> Done (installer skipped). Stage at $Stage"
    exit 0
}

# Locate Inno Setup compiler. winget's default install goes to the
# user-scoped Programs folder, choco/manual installs go under Program Files —
# check both so the build works regardless of how Inno was installed.
$ISCC = $null
foreach ($candidate in @(
    "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
    "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
    "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
)) {
    if (Test-Path $candidate) { $ISCC = $candidate; break }
}
if (-not $ISCC) {
    throw "Inno Setup 6 not found. Install from https://jrsoftware.org/isdl.php"
}

Write-Host "==> Compiling installer with $ISCC"
& $ISCC (Join-Path $Here "installer.iss") /DStageDir=$Stage
if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed" }

$Installer = Get-ChildItem (Join-Path $Here "build") -Filter "Summer-2008-Setup*.exe" `
             | Sort-Object LastWriteTime -Descending | Select-Object -First 1
Write-Host ""
Write-Host "Built: $($Installer.FullName)"
Write-Host "Size : $([Math]::Round($Installer.Length / 1MB, 1)) MB"
