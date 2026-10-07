@echo off
setlocal
rem ---------------------------------------------------------------------------
rem  Traiectus Server - build with w64devkit's g++ (no install, no admin needed)
rem
rem  Just run this file in cmd (or double-click it); no need to retype the long
rem  command line by hand. If g++ cannot be found you get a clear message, and
rem  you can fall back to the MSVC build via build.bat.
rem
rem  NOTE: this file is intentionally ASCII-only. cmd.exe reads .bat files with
rem  the local OEM code page, so UTF-8 Chinese comments can break parsing.
rem ---------------------------------------------------------------------------

set "GXX=%USERPROFILE%\tools\w64devkit\bin\g++.exe"
if not exist "%GXX%" set "GXX=C:\w64devkit\bin\g++.exe"

if not exist "%GXX%" (
    where g++.exe >nul 2>nul
    if errorlevel 1 (
        echo [ERROR] g++.exe was not found.
        echo         Install w64devkit, or use build.bat for MSVC.
        echo         Tried these locations:
        echo           %USERPROFILE%\tools\w64devkit\bin\g++.exe
        echo           C:\w64devkit\bin\g++.exe
        exit /b 1
    )
    set "GXX=g++.exe"
)

echo Using compiler: %GXX%
"%GXX%" --version | findstr /r "." >nul

if not exist "%~dp0build" mkdir "%~dp0build"

pushd "%~dp0"
"%GXX%" -std=c++17 -O2 -Wall -Wextra -municode -mconsole ^
   -DUNICODE -D_UNICODE -D__USE_MINGW_ANSI_STDIO=1 -static -static-libgcc -static-libstdc++ ^
   -o build\Traiectus-Server.exe src\main.cpp ^
   -luser32 -lgdi32 -lws2_32 -lsetupapi -lhid -lbcrypt -liphlpapi
set BUILD_RESULT=%ERRORLEVEL%
popd

if not "%BUILD_RESULT%"=="0" (
    echo.
    echo [ERROR] build failed, exit code %BUILD_RESULT%.
    echo         Report the full output above back to the Mac side; do not change the design.
    exit /b %BUILD_RESULT%
)

echo.
echo [OK] Built: %~dp0build\Traiectus-Server.exe
echo.
echo Next steps:
echo   build\Traiectus-Server.exe --list
echo   build\Traiectus-Server.exe --device "VID_xxxx&PID_xxxx&MI_00"
echo   (no token needed - the first Mac that connects gets a confirm box)
exit /b 0
