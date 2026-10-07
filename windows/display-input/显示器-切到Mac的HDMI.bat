@echo off
rem ===========================================================================
rem  Set the monitor input to HDMI-1 (value 17) = the Mac.
rem
rem  This is the direction the Mac CANNOT do itself: once the monitor shows this
rem  Windows PC's DP input, macOS no longer sees the display and loses DDC/CI,
rem  so "back to the Mac" must be done from Windows.
rem
rem  Requirements: the monitor is currently showing THIS PC (DP), i.e. this PC
rem  owns the screen right now. Nothing else is touched (only VCP 0x60).
rem
rem  ASCII-only on purpose (cmd.exe reads .bat with the local OEM code page).
rem ===========================================================================
chcp 65001 >nul
setlocal
pushd "%~dp0" 2>nul
set "OUT=%~dp0Monitor-SetMac-Result.txt"

echo ==== switch monitor input to HDMI-1 (17) = the Mac ====
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0MonInput.ps1" -Action set -Value 17 -OutFile "%OUT%"
echo.
echo result file: %OUT%
echo If the screen switched to the Mac, this PC can hand the screen over.
echo This window closes by itself in 60 seconds (or click the X).
timeout /t 60 /nobreak >nul
