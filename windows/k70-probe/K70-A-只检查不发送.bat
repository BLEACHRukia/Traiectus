@echo off
rem ===========================================================================
rem  K70-A : DRY RUN  (double-click, nothing is ever sent)
rem
rem  It only looks at the receiver's vendor interface and prints what *would*
rem  be sent. No data goes to the device: the script opens the interface and
rem  closes it again, which is a read-only capability check.
rem
rem  Mouse-only friendly: nothing has to be typed. The result is also written
rem  to K70-Send-A-Result.txt next to this file.
rem
rem  ASCII-only on purpose: cmd.exe reads .bat with the local OEM code page.
rem ===========================================================================
chcp 65001 >nul
setlocal
rem  pushd (not "cd /d") because a UNC share cannot be a cmd current directory;
rem  every path below is absolute via %~dp0 anyway.
pushd "%~dp0" 2>nul
set "OUT=%~dp0K70-Send-A-Result.txt"

if not exist "%~dp0K70-Send.ps1" (
    echo [error] K70-Send.ps1 not found next to this .bat
    timeout /t 30 /nobreak >nul
    exit /b 1
)

echo ==== K70-A dry run (nothing will be sent) ====
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0K70-Send.ps1" -Hex "00 08 01 3A 00 01" -Length 65 > "%OUT%" 2>&1
type "%OUT%"

echo.
echo result file: %OUT%
echo.
echo This window closes by itself in 60 seconds (or click the X).
timeout /t 60 /nobreak >nul
