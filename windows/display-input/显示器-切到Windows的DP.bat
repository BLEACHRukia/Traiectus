@echo off
rem ===========================================================================
rem  Set the monitor input to DP-1 (value 15) = this Windows PC.
rem  (The Mac can do this one itself with the ASUS "dwc" CLI; this bat exists so
rem  the Windows side can also do it, e.g. for tests or as a fallback.)
rem  ASCII-only on purpose (cmd.exe reads .bat with the local OEM code page).
rem ===========================================================================
chcp 65001 >nul
setlocal
pushd "%~dp0" 2>nul
set "OUT=%~dp0Monitor-SetWindows-Result.txt"

echo ==== switch monitor input to DP-1 (15) = this Windows PC ====
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0MonInput.ps1" -Action set -Value 15 -OutFile "%OUT%"
echo.
echo result file: %OUT%
echo This window closes by itself in 60 seconds (or click the X).
timeout /t 60 /nobreak >nul
