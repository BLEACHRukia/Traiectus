@echo off
setlocal
rem ---------------------------------------------------------------------------
rem  Traiectus Phase 3 - build the server with MSVC.
rem
rem  Open "x64 Native Tools Command Prompt for VS 2022" (or run vcvars64.bat)
rem  and then execute this script. No other tooling is required.
rem ---------------------------------------------------------------------------

where cl.exe >nul 2>nul
if errorlevel 1 (
    echo [ERROR] cl.exe was not found in PATH.
    echo         Open "x64 Native Tools Command Prompt for VS 2022" and run this script again.
    exit /b 1
)

if not exist "%~dp0build" mkdir "%~dp0build"

pushd "%~dp0"
cl /nologo /std:c++17 /W4 /EHsc /utf-8 /DUNICODE /D_UNICODE /DWIN32_LEAN_AND_MEAN /DNOMINMAX /Fo:build\ /Fe:build\Traiectus-Server.exe src\main.cpp /link user32.lib gdi32.lib ws2_32.lib setupapi.lib hid.lib bcrypt.lib iphlpapi.lib
set BUILD_RESULT=%ERRORLEVEL%
popd

if not "%BUILD_RESULT%"=="0" (
    echo.
    echo [ERROR] build failed with code %BUILD_RESULT%
    exit /b %BUILD_RESULT%
)

echo.
echo [OK] Built: %~dp0build\Traiectus-Server.exe
echo.
echo Next steps:
echo   build\Traiectus-Server.exe --list
echo   build\Traiectus-Server.exe --device "VID_xxxx&PID_xxxx&MI_00"
echo   (no token needed - the first Mac that connects gets a confirm box)
