[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:PROCESSOR_ARCHITECTURE -ne 'ARM64') {
    throw 'Run this setup on a native Windows ARM64 runner.'
}

$projectDir = Split-Path -Parent $PSScriptRoot
$version = (Get-Content (Join-Path $projectDir '.fvmrc') | ConvertFrom-Json).flutter
$flutterDir = Join-Path $env:RUNNER_TEMP "flutter-$version-arm64"
git clone --depth 1 --branch $version https://github.com/flutter/flutter.git $flutterDir
if ($LASTEXITCODE -ne 0) { throw 'Cloning the pinned Flutter SDK failed.' }

$flutter = Join-Path $flutterDir 'bin\flutter.bat'
& $flutter config --enable-windows-desktop --no-analytics
if ($LASTEXITCODE -ne 0) { throw 'Initializing Flutter failed.' }
$dart = Join-Path $flutterDir 'bin\cache\dart-sdk\bin\dart.exe'
$dartVersion = & $dart --version 2>&1 | Out-String
if ($LASTEXITCODE -ne 0 -or $dartVersion -notmatch 'windows_arm64') {
    throw "The pinned SDK did not provide native ARM64 Dart: $dartVersion"
}
& $flutter precache --windows
if ($LASTEXITCODE -ne 0) { throw 'Fetching the Windows engine failed.' }
Add-Content $env:GITHUB_PATH (Join-Path $flutterDir 'bin')
Add-Content $env:GITHUB_ENV "FLUTTER_ROOT=$flutterDir"
