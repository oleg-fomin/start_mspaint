@echo off
rem Build ArcInputFix.exe with MSVC.
rem Run from a "x64 Native Tools Command Prompt for VS" (cl.exe on PATH), or just
rem run this file - it will try to locate and import the VS build environment.
rem
rem Output: %~dp0ArcInputFix.exe  (x64, statically linked CRT, windowless)

setlocal enabledelayedexpansion

if not defined VSCMD_VER (
    set "_vswhere=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
    if exist "!_vswhere!" (
        for /f "usebackq tokens=*" %%i in (`"!_vswhere!" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "_vsroot=%%i"
    )
    if defined _vsroot (
        call "!_vsroot!\VC\Auxiliary\Build\vcvars64.bat" >nul
    )
)

where cl >nul 2>nul
if errorlevel 1 (
    echo [ERROR] cl.exe not found. Open a "x64 Native Tools Command Prompt for VS"
    echo         and re-run, or install the VC++ build tools.
    exit /b 1
)

pushd "%~dp0"

cl /nologo /W4 /O1 /EHsc /MT /std:c++17 /DUNICODE /D_UNICODE ArcInputFix.cpp ^
   /link /SUBSYSTEM:WINDOWS /OUT:ArcInputFix.exe

set "_rc=%errorlevel%"

del /q ArcInputFix.obj 2>nul

popd

if "%_rc%"=="0" (
    echo [OK] Built %~dp0ArcInputFix.exe
) else (
    echo [ERROR] Build failed with code %_rc%.
)

endlocal & exit /b %_rc%
