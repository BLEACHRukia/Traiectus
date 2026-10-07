@echo off
rem ===========================================================================
rem  Traiectus cleanup helper (Windows side)
rem
rem   Double-click            -> report only (nothing is deleted)
rem   Run with "clean"        -> also remove obsolete AUTOSTART items
rem   Run with "clean all"    -> additionally delete the OLD install folder
rem                              %LOCALAPPDATA%\MiniKVM  (only after the new
rem                              tray is installed and verified!)
rem
rem  ASCII-only on purpose (PowerShell 5.1 + no BOM = ANSI code page).
rem ===========================================================================
setlocal
set PS=powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0清理旧版本残留.ps1"

if /I "%~1"=="clean" (
    if /I "%~2"=="all" ( %PS% -Clean -RemoveInstallDir ) else ( %PS% -Clean )
) else (
    %PS%
)

echo.
pause
