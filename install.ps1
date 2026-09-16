#Requires -Version 5.1
param([ValidateSet('x64', 'arm64')][string]$Architecture = 'x64')
$ErrorActionPreference = 'Stop'
$build = Join-Path $PSScriptRoot "dist\windows-$Architecture"
if (-not (Test-Path -LiteralPath (Join-Path $build 'CodexSwitch.Windows.exe'))) {
    & (Join-Path $PSScriptRoot 'scripts\build-windows.ps1') -Architecture $Architecture
}
$dest = Join-Path $env:LOCALAPPDATA 'CodexSwitch'
New-Item -ItemType Directory -Force -Path $dest | Out-Null
$native = Join-Path $dest 'native'
New-Item -ItemType Directory -Force -Path $native | Out-Null
Copy-Item -Path (Join-Path $build '*') -Destination $native -Recurse -Force
Copy-Item -Force -Path (Join-Path $PSScriptRoot 'codex-switch.ps1'), (Join-Path $PSScriptRoot 'codex-switch.gui.ps1'), (Join-Path $PSScriptRoot 'codex-switch.cmd') -Destination $dest

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (-not $userPath) { $userPath = '' }
if ($userPath -notlike "*$dest*") {
    $joined = if ($userPath.TrimEnd(';')) { $userPath.TrimEnd(';') + ';' + $dest } else { $dest }
    [Environment]::SetEnvironmentVariable('Path', $joined, 'User')
    $env:Path += ";$dest"
}

Write-Host "Installed to $dest"
Write-Host 'Open a new terminal and run: codex-switch'
