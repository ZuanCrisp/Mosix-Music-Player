# Package the Windows release folder as a portable zip and a per-user
# Inno Setup installer (windows\installer\mornye.iss).
#
# Usage, from the repository root:
#   pwsh scripts\package_windows.ps1 -Version v5.3.0
#   pwsh scripts\package_windows.ps1 -Version v5.3.0 -Arch arm64 -Only installer
#
# Outputs, in -OutputDir (default build\desktop):
#   Mornye-<version>-windows-<arch>-setup.exe
#   Mornye-<version>-windows-<arch>-portable.zip
#
# Inno Setup 6 is used from PATH, its default install folder, or installed
# with Chocolatey when neither has it.

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Version,
    [ValidateSet('x64', 'arm64')]
    [string]$Arch = 'x64',
    [string]$BundleDir = '',
    [string]$OutputDir = 'build\desktop',
    [ValidateSet('all', 'portable', 'installer')]
    [string]$Only = 'all'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$projectDir = Split-Path -Parent $PSScriptRoot
if (-not $BundleDir) {
    $BundleDir = Join-Path $projectDir "build\windows\$Arch\runner\Release"
}
$BundleDir = (Resolve-Path $BundleDir).Path
New-Item -ItemType Directory -Force $OutputDir | Out-Null
$OutputDir = (Resolve-Path $OutputDir).Path

$upstream = $Version -replace '^v', ''
if ($upstream -notmatch '^(\d+)\.(\d+)\.(\d+)([.-][0-9A-Za-z.-]+)?$') {
    throw "Invalid version: $Version"
}
$numericVersion = "$($Matches[1]).$($Matches[2]).$($Matches[3]).0"

foreach ($required in 'mornye.exe', 'flutter_windows.dll', 'data\app.so') {
    if (-not (Test-Path (Join-Path $BundleDir $required))) {
        throw "Missing $required in $BundleDir"
    }
}

$baseName = "Mornye-$Version-windows-$Arch"

if ($Only -in 'all', 'portable') {
    $zip = Join-Path $OutputDir "$baseName-portable.zip"
    if (Test-Path $zip) { Remove-Item $zip -Force }
    Compress-Archive -Path (Join-Path $BundleDir '*') -DestinationPath $zip
    Write-Host "Created $zip"
}

if ($Only -in 'all', 'installer') {
    $iscc = $null
    $isccCommand = Get-Command 'ISCC.exe' -ErrorAction SilentlyContinue
    if ($isccCommand) {
        $iscc = $isccCommand.Source
    } else {
        $default = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'
        if (-not (Test-Path $default)) {
            choco install innosetup --no-progress -y
            if ($LASTEXITCODE -ne 0) { throw 'Could not install Inno Setup' }
        }
        $iscc = $default
    }

    $script = Join-Path $projectDir 'windows\installer\mornye.iss'
    & $iscc `
        "/DAppVersion=$upstream" `
        "/DNumericVersion=$numericVersion" `
        "/DBundleDir=$BundleDir" `
        "/DArch=$Arch" `
        "/DOutputDir=$OutputDir" `
        "/DOutputBaseName=$baseName-setup" `
        $script
    if ($LASTEXITCODE -ne 0) { throw "ISCC failed with exit code $LASTEXITCODE" }
    Write-Host "Created $(Join-Path $OutputDir "$baseName-setup.exe")"
}
