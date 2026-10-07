@echo off
rem ===========================================================================
rem  K70-B3 : corrected payload  ->  SLIPSTREAM
rem           "00 09 01 3A 00 00" padded to 65 bytes
rem
rem  Two bytes were wrong in K70-B/B2/C:
rem    * endpoint byte: 0x08 -> 0x09   (OpenLinkHub slipstream.go: endpoint = base + 1
rem      when the receiver carries exactly one paired device; base = 0x08)
rem    * SLIPSTREAM mode value on the receiver path: 1 -> 0 (k70pmW.go vs k70pmWU.go)
rem
rem  GATED: needs K70-GO.txt next to this file; consumed afterwards (single shot).
rem  Mouse-only friendly: nothing has to be typed.
rem  ASCII-only on purpose (cmd.exe reads .bat with the local OEM code page).
rem ===========================================================================
chcp 65001 >nul
setlocal
pushd "%~dp0" 2>nul
set "OUT=%~dp0K70-Send-B3-Result.txt"

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

echo ==== K70-B3 : switching the keyboard to SLIPSTREAM (payload 00 09 01 3A 00 00) ====
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0K70-Send.ps1" -Hex "00 09 01 3A 00 00" -Length 65 -Method WriteFile -Execute > "%OUT%" 2>&1
type "%OUT%"

del "%~dp0K70-GO.txt" >nul 2>&1

echo.
echo result file: %OUT%
echo.
echo Now check: can you type on Windows? (open Notepad with the mouse)
echo.
echo This window closes by itself in 90 seconds (or click the X).
timeout /t 90 /nobreak >nul
