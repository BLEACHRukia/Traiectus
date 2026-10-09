@echo off
rem ===========================================================================
rem  Build Traiectus.exe (the tray launcher) with w64devkit's g++.
rem
rem  Static linking is REQUIRED:
rem    without -static the exe depends on libstdc++-6.dll / libgcc_s_seh-1.dll,
rem    and once it is copied to %LOCALAPPDATA%\Traiectus\ a double-click fails
rem    with a missing-DLL dialog.
rem
rem  Traiectus.rc is passed to g++ on purpose: the gcc driver hands .rc files to
rem  windres (shipped in the same w64devkit\bin), which embeds Traiectus.ico so
rem  the exe shows the app icon in Explorer / the taskbar.
rem
rem  ASCII-only on purpose (cmd.exe reads .bat with the local OEM code page).
rem ===========================================================================
setlocal
cd /d "%~dp0"

set "GXX=%USERPROFILE%\tools\w64devkit\bin\g++.exe"
if not exist "%GXX%" set "GXX=C:\w64devkit\bin\g++.exe"

if not exist "%GXX%" (
    where g++.exe >nul 2>nul
    if errorlevel 1 (
        echo [ERROR] g++.exe was not found.
        echo         Install w64devkit, or build with MSVC:
        echo           cl /std:c++17 /utf-8 /EHsc /DUNICODE /D_UNICODE Traiectus.cpp ^
        echo              Traiectus.rc ^
        echo              /link shell32.lib ws2_32.lib gdi32.lib user32.lib iphlpapi.lib ^
        echo              /SUBSYSTEM:WINDOWS
        pause
        exit /b 1
    )
    set "GXX=g++.exe"
)

echo Using compiler: %GXX%
"%GXX%" --version | findstr /r "." >nul

echo.
echo Building Traiectus.exe ...
"%GXX%" -std=c++17 -O2 -Wall -Wextra -municode -mwindows ^
   -DUNICODE -D_UNICODE ^
   -static -static-libgcc -static-libstdc++ ^
   -o Traiectus.exe Traiectus.cpp Traiectus.rc ^
   -lshell32 -lws2_32 -lgdi32 -luser32 -liphlpapi
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" (
    echo.
    echo [ERROR] build failed, exit code %RC%.
    echo         Send the whole output above back for diagnosis.
    pause
    exit /b %RC%
)

echo.
echo [OK] built:
dir /b Traiectus.exe
echo.
echo Next: double-click the "install" .bat in this folder.
echo.
pause
exit /b 0
