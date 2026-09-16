#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$vector = Join-Path $repoRoot 'assets\app-icon.svg'
$png = Join-Path $repoRoot 'assets\app-icon.png'
$ico = Join-Path $repoRoot 'assets\app-icon.ico'
magick -background none $vector -resize 1024x1024 $png
if ($LASTEXITCODE -ne 0) { throw 'Icon render failed. Install ImageMagick to regenerate icons.' }
magick $png -define icon:auto-resize=256,128,64,48,40,32,24,20,16 $ico
if ($LASTEXITCODE -ne 0) { throw 'ICO export failed.' }
Write-Host 'Updated PNG and multi-resolution Windows icon from SVG.'
