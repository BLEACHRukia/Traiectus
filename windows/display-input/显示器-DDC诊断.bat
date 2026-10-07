@echo off
rem ===========================================================================
rem  READ ONLY: DDC/CI diagnostic. Writes nothing to the monitor.
rem  Result also goes to Monitor-Diag-Result.txt next to this file.
rem  ASCII-only on purpose (cmd.exe reads .bat with the local OEM code page).
rem ===========================================================================
chcp 65001 >nul
setlocal
pushd "%~dp0" 2>nul
set "OUT=%~dp0Monitor-Diag-Result.txt"

if not exist "%~dp0MonDiag.ps1" (
    echo [error] MonDiag.ps1 not found next to this .bat
    timeout /t 30 /nobreak >nul
    exit /b 1
)

echo ==== DDC/CI diagnostic (read only) ====
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0MonDiag.ps1" -OutFile "%OUT%"
echo.
echo result file: %OUT%
echo This window closes by itself in 60 seconds (or click the X).
timeout /t 60 /nobreak >nul
