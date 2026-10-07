@echo off
rem ===========================================================================
rem  K70 HID interface probe - READ ONLY (double-click to run)
rem
rem  Output is written to K70-Probe-Result.txt in this same folder.
rem  This script only enumerates HID interfaces and reads their descriptors.
rem  It never writes to any device.
rem
rem  ASCII-only on purpose: cmd.exe reads .bat with the local OEM code page.
rem ===========================================================================
chcp 65001 >nul
setlocal
pushd "%~dp0" 2>nul
set "OUT=%~dp0K70-Probe-Result.txt"

if not exist "%~dp0K70-Probe.ps1" (
    echo [error] K70-Probe.ps1 not found next to this .bat
    pause
    exit /b 1
)
if not exist "%~dp0K70-HidLib.ps1" (
    echo [error] K70-HidLib.ps1 not found next to this .bat
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0K70-Probe.ps1" -OutFile "%OUT%"
echo.
echo result file: %OUT%
echo.
pause
