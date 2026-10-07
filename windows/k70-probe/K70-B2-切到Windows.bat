@echo off
rem ===========================================================================
rem  K70-B2 : same payload as K70-B ("00 08 01 3A 00 01", 65 bytes) but it now
rem           also reports the real Win32 error and, if HidD_SetOutputReport
rem           fails, pushes the very same report through WriteFile (the call
rem           hidapi itself uses on Windows).
rem
rem  GATED: needs K70-GO.txt next to this file; the file is consumed afterwards.
rem  Mouse-only friendly: nothing has to be typed.
rem  ASCII-only on purpose (cmd.exe reads .bat with the local OEM code page).
rem ===========================================================================
chcp 65001 >nul
setlocal
pushd "%~dp0" 2>nul
set "OUT=%~dp0K70-Send-B2-Result.txt"

if not exist "%~dp0K70-GO.txt" (
    echo ============================================================
    echo  NOT SENT - K70-GO.txt is missing from this folder.
    echo  The Mac side has not cleared this test yet.
    echo  Nothing was sent to the keyboard.
    echo ============================================================
    echo.
    timeout /t 25 /nobreak >nul
    exit /b 2
)

echo ==== K70-B2 : switching the keyboard to SLIPSTREAM (up to 2 calls, same payload) ====
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0K70-Send.ps1" -Hex "00 08 01 3A 00 01" -Length 65 -Method Both -Execute > "%OUT%" 2>&1
type "%OUT%"

del "%~dp0K70-GO.txt" >nul 2>&1

echo.
echo result file: %OUT%
echo.
echo Now check: can you type on Windows? (open Notepad with the mouse)
echo.
echo This window closes by itself in 90 seconds (or click the X).
timeout /t 90 /nobreak >nul
