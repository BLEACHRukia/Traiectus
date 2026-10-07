@echo off
rem ===========================================================================
rem  K70 endpoint scan : one WriteFile per candidate routing byte
rem
rem  Payload per attempt (65 bytes):
rem      00 <candidate> 01 3A 00 02  + 59 zero bytes     -> Bluetooth Host 1 (Mac)
rem
rem  Run this while the keyboard is on Windows (press Fn+Caps first), so the
rem  receiver really has the keyboard on its 2.4G link. If one of the candidates
rem  is right, the keyboard jumps back to the Mac and you can type there again.
rem
rem  GATED: needs K70-GO.txt next to this file; consumed afterwards.
rem  Mouse-only friendly: nothing has to be typed.
rem  ASCII-only on purpose (cmd.exe reads .bat with the local OEM code page).
rem ===========================================================================
chcp 65001 >nul
setlocal
pushd "%~dp0" 2>nul
set "OUT=%~dp0K70-Sweep-Result.txt"

if not exist "%~dp0K70-GO.txt" (
    echo ============================================================
    echo  NOT SENT - K70-GO.txt is missing from this folder.
    echo  The Mac side has not cleared this scan yet.
    echo  Nothing was sent to the keyboard.
    echo ============================================================
    echo.
    timeout /t 25 /nobreak >nul
    exit /b 2
)

echo ==== K70 endpoint scan (16 candidates, one write each) ====
echo.

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0K70-Sweep.ps1" -OutFile "%OUT%" > "%OUT%.console" 2>&1
type "%OUT%.console"
del "%OUT%.console" >nul 2>&1

del "%~dp0K70-GO.txt" >nul 2>&1

echo.
echo result file: %OUT%
echo.
echo Did the keyboard come back to the Mac during the scan?
echo This window closes by itself in 120 seconds (or click the X).
timeout /t 120 /nobreak >nul
