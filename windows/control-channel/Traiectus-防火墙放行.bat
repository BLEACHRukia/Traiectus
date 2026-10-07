@echo off
rem ===========================================================================
rem  Traiectus - run the firewall setup with administrator rights.
rem
rem  Double-click this file.  A UAC prompt appears - click Yes.
rem  It only runs Traiectus-firewall.ps1 (same folder), which:
rem    1) ensures one inbound allow rule for TCP 45789 (port-scoped)
rem    2) ensures one inbound allow rule for UDP 45791 (discovery, port-scoped)
rem    3) removes PROGRAM-scoped leftover rules (display names ending in .exe:
rem       traiectus-server.exe, traiectus-server-*.exe, minikvm-server.exe) so
rem       that only the two ports above stay open
rem
rem  It does NOT change any port, does NOT touch the proxy, and does NOT add any
rem  autostart item.
rem
rem  ASCII-only on purpose (cmd.exe reads .bat with the local OEM code page).
rem ===========================================================================
setlocal

net session >nul 2>&1
if not "%errorlevel%"=="0" (
    echo.
    echo [elevating] A UAC prompt will appear - click Yes.
    echo.
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

echo Running with administrator rights.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Traiectus-firewall.ps1"

echo.
pause
exit /b 0
