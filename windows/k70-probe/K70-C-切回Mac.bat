@echo off
rem ===========================================================================
rem  K70-C : send ONE output report to the receiver   ->  Bluetooth Host 1
rem          payload "00 08 01 3A 00 02" padded to 65 bytes
rem
rem  Same gate as K70-B: needs K70-GO.txt next to this file, and deletes it
rem  afterwards, so this can only fire once per approval.
rem
rem  Use it when the keyboard has gone to Windows and you want it back on the
rem  Mac (Bluetooth Host 1) - with the mouse only, no typing needed.
rem
rem  Exactly one HidD_SetOutputReport call: no loop, no retry, no background.
rem  ASCII-only on purpose (cmd.exe reads .bat with the local OEM code page).
rem ===========================================================================
chcp 65001 >nul
setlocal
pushd "%~dp0" 2>nul
set "OUT=%~dp0K70-Send-C-Result.txt"

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

echo ==== K70-C : ONE write, switching the keyboard to Bluetooth Host 1 ====
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0K70-Send.ps1" -Hex "00 08 01 3A 00 02" -Length 65 -Method WriteFile -Execute > "%OUT%" 2>&1
type "%OUT%"

del "%~dp0K70-GO.txt" >nul 2>&1

echo.
echo result file: %OUT%
echo.
echo Check on the Mac whether the keyboard came back.
echo.
echo This window closes by itself in 90 seconds (or click the X).
timeout /t 90 /nobreak >nul
