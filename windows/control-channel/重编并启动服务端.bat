@echo off
rem ===========================================================================
rem  Rebuild Traiectus-Server (with w64devkit) and start it.
rem
rem  Why: the running server must be the NEW build - the one that listens on the
rem  UDP control channel (45791). Without it the Mac cannot ask Windows to hand
rem  the mouse over, and the Mac mouse keeps needing its own cable.
rem
rem  What it does:
rem    1) finds the phase3-tcp folder (next to this .bat, or one level up)
rem    2) runs build-mingw.bat  ->  build\Traiectus-Server.exe
rem    3) stops any running Traiectus-Server.exe (graceful close, so it also
rem       releases the cursor lock on the way out)
rem    4) starts the new server in its own window (via start-server.bat)
rem
rem  It changes nothing else - no registry, no services, no system settings.
rem  ASCII-only on purpose (cmd.exe reads .bat with the local OEM code page).
rem ===========================================================================
chcp 65001 >nul
setlocal

set "HERE=%~dp0"
set "P3="
if exist "%HERE%phase3-tcp\build-mingw.bat" set "P3=%HERE%phase3-tcp"
if not defined P3 if exist "%HERE%build-mingw.bat" set "P3=%HERE%"
if not defined P3 (
    echo [ERROR] phase3-tcp folder not found next to this .bat
    echo         Put this .bat in the same folder as the phase3-tcp directory.
    pause
    exit /b 1
)

echo ============================================================
echo  Step 1/3  build  (%P3%^)
echo ============================================================
call "%P3%\build-mingw.bat"
if errorlevel 1 (
    echo.
    echo [ERROR] build failed - send the output to the Mac side.
    pause
    exit /b 1
)

if not exist "%P3%\build\Traiectus-Server.exe" (
    echo [ERROR] build\Traiectus-Server.exe was not produced.
    pause
    exit /b 1
)

echo.
echo ============================================================
echo  Step 2/3  stop the old server (if it is running)
echo ============================================================
taskkill /IM Traiectus-Server.exe >nul 2>&1
if errorlevel 1 (
    echo  (no running Traiectus-Server.exe found - fine)
) else (
    echo  old server closed. Waiting 2 seconds...
    timeout /t 2 /nobreak >nul
)

echo.
echo ============================================================
echo  Step 3/3  start the new server
echo ============================================================
start "" "%P3%\start-server.bat"

echo.
echo The new server window must show a line containing: UDP 45791
echo (it is the "control channel" line)
echo.
echo Next: close and re-open the bridge window (TraiectusBridge / the bridge .bat),
echo then press Fn+Caps / Fn+T and tell the Mac side.
echo.
pause
