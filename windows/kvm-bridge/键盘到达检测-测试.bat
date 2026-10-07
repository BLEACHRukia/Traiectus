@echo off
rem ===========================================================================
rem  READ ONLY: watch the receiver's vendor interfaces (usagePage 0xFF42) for
rem  any incoming report. Goal: does Windows notice the keyboard arriving at
rem  the 2.4G receiver, and how fast compared with the Mac's Bluetooth events?
rem
rem  Nothing is written to any device. Result: KvmWatch-Result.txt
rem  ASCII-only on purpose (cmd.exe reads .bat with the local OEM code page).
rem ===========================================================================
chcp 65001 >nul
setlocal
pushd "%~dp0" 2>nul
set "OUT=%~dp0KvmWatch-Result.txt"

if not exist "%~dp0KvmWatch.ps1" (
    echo [error] KvmWatch.ps1 not found next to this .bat
    timeout /t 30 /nobreak >nul
    exit /b 1
)

echo ============================================================
echo  READ-ONLY test. During the next 90 seconds please do:
echo.
echo    1) press  Fn + Caps Lock   (keyboard goes to Windows)
echo    2) wait about 10 seconds
echo    3) press  Fn + T           (keyboard goes back to the Mac)
echo    4) wait about 10 seconds, then repeat steps 1-3 once more
echo.
echo  Nothing is written to the keyboard or to the receiver.
echo ============================================================
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0KvmWatch.ps1" -Seconds 90 -OutFile "%OUT%"

echo.
echo result file: %OUT%
echo This window closes by itself in 60 seconds (or click the X).
timeout /t 60 /nobreak >nul
