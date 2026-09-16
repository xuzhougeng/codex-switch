@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"
if "%~1"=="" (
  goto native
)
if /i "%~1"=="gui" goto native
where pwsh >nul 2>&1
if %ERRORLEVEL%==0 (
  pwsh -NoProfile -File "%~dp0codex-switch.ps1" %*
) else (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0codex-switch.ps1" %*
)
exit /b %ERRORLEVEL%

:native
if exist "%~dp0native\CodexSwitch.Windows.exe" (
  start "" "%~dp0native\CodexSwitch.Windows.exe"
  exit /b 0
)
if exist "%~dp0dist\windows-x64\CodexSwitch.Windows.exe" (
  start "" "%~dp0dist\windows-x64\CodexSwitch.Windows.exe"
  exit /b 0
)
if exist "%~dp0dist\windows-arm64\CodexSwitch.Windows.exe" (
  start "" "%~dp0dist\windows-arm64\CodexSwitch.Windows.exe"
  exit /b 0
)
echo Native app is not built. Run: powershell -ExecutionPolicy Bypass -File scripts\build-windows.ps1
echo Legacy interface: powershell -ExecutionPolicy Bypass -File codex-switch.ps1 gui
pause
exit /b 1
