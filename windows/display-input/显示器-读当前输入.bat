@echo off
rem ===========================================================================
rem  READ ONLY: show which input the monitor is on right now (VCP 0x60)
rem  Result also goes to Monitor-Get-Result.txt next to this file.
rem  Mouse-only friendly: nothing has to be typed.
rem  ASCII-only on purpose (cmd.exe reads .bat with the local OEM code page).
rem ===========================================================================
chcp 65001 >nul
setlocal
pushd "%~dp0" 2>nul
set "OUT=%~dp0Monitor-Get-Result.txt"

echo ==== monitor input source (read only) ====
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0MonInput.ps1" -Action get -OutFile "%OUT%"
echo.
echo result file: %OUT%
echo This window closes by itself in 45 seconds (or click the X).
timeout /t 45 /nobreak >nul
