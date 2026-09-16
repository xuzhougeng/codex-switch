#Requires -Version 5.1
param([ValidateSet('x64', 'arm64')][string]$Architecture = 'x64')
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$platform = if ($Architecture -eq 'arm64') { 'ARM64' } else { 'x64' }
dotnet run --project (Join-Path $repoRoot 'tests\Core.Tests\Core.Tests.csproj') -c Release
if ($LASTEXITCODE -ne 0) { throw 'Core validation failed.' }
dotnet publish (Join-Path $repoRoot 'src\Windows\CodexSwitch.Windows.csproj') -c Release -p:Platform=$platform -r "win-$Architecture" --self-contained true -o (Join-Path $repoRoot "dist\windows-$Architecture")
if ($LASTEXITCODE -ne 0) { throw 'WinUI build failed.' }
Write-Host "Built: $repoRoot\dist\windows-$Architecture\CodexSwitch.Windows.exe"
