@echo off
rem ===========================================================================
rem  Install / upgrade Traiectus (tray launcher) into %LOCALAPPDATA%\Traiectus
rem
rem  Everything it does stays inside your own user profile:
rem    1) stop a running Traiectus.exe / Traiectus-Server.exe / old background bridge
rem    2) remove the OLD background-bridge autostart, so you can never end up
rem       with two bridges running at once
rem    3) wipe %LOCALAPPDATA%\Traiectus and copy the new files in
rem    4) create a desktop shortcut to Traiectus.exe
rem
rem  It does NOT touch the registry, services, drivers, firewall rules or any
rem  system setting, and it does NOT add any autostart item.
rem  (Step 2 only REMOVES an autostart entry - that is deliberate.)
rem
rem  ASCII-only on purpose (cmd.exe reads .bat with the local OEM code page).
rem ===========================================================================
setlocal
cd /d "%~dp0"

set "SRC=%~dp0"
set "DST=%LOCALAPPDATA%\Traiectus"

echo ============================================================
echo  Traiectus install
echo  target: %DST%
echo ============================================================
echo.

if not exist "%SRC%Traiectus.exe" (
    echo [ERROR] Traiectus.exe not found in this folder.
    echo         Run build-launcher.bat first.
    pause
    exit /b 1
)
if not exist "%SRC%..\phase3-tcp\build\Traiectus-Server.exe" (
    echo [ERROR] ..\phase3-tcp\build\Traiectus-Server.exe not found.
    echo         Build the server first: run phase3-tcp\build-mingw.bat
    pause
    exit /b 1
)
if not exist "%SRC%..\TraiectusBridge.ps1" (
    echo [ERROR] ..\TraiectusBridge.ps1 not found next to the phase3-tcp folder.
    pause
    exit /b 1
)

echo [1/5] stopping anything that is already running ...
taskkill /F /IM Traiectus.exe        >nul 2>&1
taskkill /F /IM Traiectus-Server.exe >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*TraiectusBridge.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }"
ping -n 2 127.0.0.1 >nul 2>&1

echo [2/5] removing the old background-bridge autostart ...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$lnk=[Environment]::GetFolderPath('Startup')+'\TraiectusBridge.lnk'; if (Test-Path $lnk) { Remove-Item $lnk -Force; Write-Host ('   removed ' + $lnk) } else { Write-Host '   no old startup shortcut (fine)' }"

echo [3/5] cleaning the install folder ...
if exist "%DST%" rd /s /q "%DST%"
mkdir "%DST%"

echo [4/5] copying files ...
copy /Y "%SRC%Traiectus.exe"                             "%DST%\" >nul
copy /Y "%SRC%config.ini"                              "%DST%\" >nul
copy /Y "%SRC%..\phase3-tcp\build\Traiectus-Server.exe"  "%DST%\" >nul
copy /Y "%SRC%..\TraiectusBridge.ps1"                        "%DST%\" >nul

echo [5/5] creating the desktop shortcut ...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$d=[Environment]::GetFolderPath('Desktop'); $s=(New-Object -ComObject WScript.Shell).CreateShortcut($d+'\Traiectus.lnk'); $s.TargetPath='%DST%\Traiectus.exe'; $s.WorkingDirectory='%DST%'; $s.Description='Traiectus'; $s.Save(); Write-Host ('   ' + $d + '\Traiectus.lnk')"

echo.
echo Done. Installed files:
dir /b "%DST%"
echo.
echo   start  : double-click "Traiectus" on the Desktop
echo   stop   : right-click the tray dot, then Exit
echo   remove : run the "uninstall" .bat in this folder
echo.
pause
exit /b 0
