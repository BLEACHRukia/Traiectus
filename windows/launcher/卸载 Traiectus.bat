@echo off
rem ===========================================================================
rem  Uninstall Traiectus (the tray launcher).
rem
rem  It only removes what the "install" .bat created:
rem    - Traiectus.exe / Traiectus-Server.exe / the bridge process
rem    - the desktop shortcut
rem    - %LOCALAPPDATA%\Traiectus
rem
rem  It does NOT touch the registry, services, drivers, or the firewall rules.
rem
rem  ASCII-only on purpose (cmd.exe reads .bat with the local OEM code page).
rem ===========================================================================
setlocal

set "DST=%LOCALAPPDATA%\Traiectus"

echo ============================================================
echo  Traiectus uninstall
echo ============================================================
echo.

echo [1/4] stopping processes ...
taskkill /F /IM Traiectus.exe        >nul 2>&1
taskkill /F /IM Traiectus-Server.exe >nul 2>&1
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -like '*TraiectusBridge.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }"
ping -n 2 127.0.0.1 >nul 2>&1

echo [2/4] removing the desktop shortcut ...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$l=[Environment]::GetFolderPath('Desktop')+'\Traiectus.lnk'; if (Test-Path $l) { Remove-Item $l -Force; Write-Host ('   removed ' + $l) } else { Write-Host '   no desktop shortcut (fine)' }"

echo [3/4] removing the startup shortcut, if any ...
powershell -NoProfile -ExecutionPolicy Bypass -Command "$l=[Environment]::GetFolderPath('Startup')+'\TraiectusBridge.lnk'; if (Test-Path $l) { Remove-Item $l -Force; Write-Host ('   removed ' + $l) } else { Write-Host '   no startup shortcut (fine)' }"

echo [4/4] removing the install folder ...
if exist "%DST%" rd /s /q "%DST%"

echo.
echo Done.
echo Note: the Windows Firewall rules for Traiectus were NOT touched.
echo       They are inert while no Traiectus process is running.
echo.
pause
exit /b 0
