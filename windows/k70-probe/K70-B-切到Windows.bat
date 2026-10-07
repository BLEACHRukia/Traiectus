@echo off
rem ===========================================================================
rem  K70-B : send ONE output report to the receiver   ->  SLIPSTREAM
rem          payload "00 08 01 3A 00 01" padded to 65 bytes
rem
rem  GATED ON PURPOSE: this script refuses to send anything unless the file
rem  K70-GO.txt exists in this same folder. The Mac side drops that file in
rem  when it is ready and watching; the file is deleted after the attempt, so
rem  a second double-click cannot send a second time.
rem
rem  Exactly one HidD_SetOutputReport call: no loop, no retry, no background.
rem  Mouse-only friendly: nothing has to be typed.
rem
rem  ASCII-only on purpose (cmd.exe reads .bat with the local OEM code page).
rem ===========================================================================
chcp 65001 >nul
setlocal
pushd "%~dp0" 2>nul
set "OUT=%~dp0K70-Send-B-Result.txt"

if not exist "%~dp0K70-GO.txt" (
    echo ============================================================
    echo  NOT SENT - K70-GO.txt is missing from this folder.
    echo.
    echo  The Mac side has not cleared this test yet.
    echo  Nothing was sent to the keyboard.
    echo ============================================================
    echo.
    timeout /t 25 /nobreak >nul
    exit /b 2
)

echo ==== K70-B : ONE write, switching the keyboard to SLIPSTREAM ====
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0K70-Send.ps1" -Hex "00 08 01 3A 00 01" -Length 65 -Execute > "%OUT%" 2>&1
type "%OUT%"

rem single-shot: consume the go file so another double-click cannot re-send
del "%~dp0K70-GO.txt" >nul 2>&1

echo.
echo result file: %OUT%
echo.
echo Now check: can you type on Windows? (open Notepad with the mouse)
echo If the keyboard did NOT move, do not re-run - tell the Mac side.
echo.
echo This window closes by itself in 90 seconds (or click the X).
timeout /t 90 /nobreak >nul
