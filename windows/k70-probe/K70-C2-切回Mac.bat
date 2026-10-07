@echo off
rem ===========================================================================
rem  K70-C2 : corrected payload  ->  Bluetooth Host 1
rem           "00 09 01 3A 00 02" padded to 65 bytes
rem
rem  Same correction as K70-B3: endpoint 0x08 -> 0x09. (Mode 2 = BT Host 1 is the
rem  same value on both the receiver and the USB-direct path.)
rem
rem  GATED: needs K70-GO.txt next to this file; consumed afterwards (single shot).
rem  Mouse-only friendly: nothing has to be typed.
rem  ASCII-only on purpose (cmd.exe reads .bat with the local OEM code page).
rem ===========================================================================
chcp 65001 >nul
setlocal
pushd "%~dp0" 2>nul
set "OUT=%~dp0K70-Send-C2-Result.txt"

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

echo ==== K70-C2 : switching the keyboard to Bluetooth Host 1 (payload 00 09 01 3A 00 02) ====
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0K70-Send.ps1" -Hex "00 09 01 3A 00 02" -Length 65 -Method WriteFile -Execute > "%OUT%" 2>&1
type "%OUT%"

del "%~dp0K70-GO.txt" >nul 2>&1

echo.
echo result file: %OUT%
echo.
echo Check on the Mac whether the keyboard came back (or press Fn+T on the keyboard).
echo.
echo This window closes by itself in 90 seconds (or click the X).
timeout /t 90 /nobreak >nul
