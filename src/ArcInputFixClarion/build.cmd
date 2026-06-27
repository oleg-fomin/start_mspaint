@echo off
rem Build ArcInputFix.exe (Clarion 11 port) from the command line.
rem
rem Uses the .NET Framework MSBuild with the SoftVelocity Clarion targets.
rem
rem Overrides (optional environment variables):
rem   CLARION_BIN      Clarion 11 bin folder        (default C:\Clarion\bin)
rem   CLARION_VERSION  registered version name token e.g. "Clarion 11.0.13505"
rem                    (auto-detected from ClarionProperties.xml if not set)
rem
rem Output: %~dp00release\ArcInputFix.exe (Win32, static runtime, windowless).

setlocal enabledelayedexpansion

if not defined CLARION_BIN set "CLARION_BIN=C:\Clarion\bin"
if not exist "%CLARION_BIN%\ClarionCL.exe" (
    echo [ERROR] Clarion not found at "%CLARION_BIN%".
    echo         Set CLARION_BIN to your Clarion 11 bin folder and re-run.
    exit /b 1
)

set "MSBUILD=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\MSBuild.exe"
if not exist "%MSBUILD%" (
    echo [ERROR] .NET Framework 4.0 MSBuild not found at "%MSBUILD%".
    exit /b 1
)

rem The CW build task requires the exact registered version name (incl. build
rem number), as stored under <Properties name="Clarion.Versions"> in the IDE's
rem ClarionProperties.xml. Auto-detect it unless CLARION_VERSION is supplied.
if not defined CLARION_VERSION (
    for /f "usebackq delims=" %%v in (`powershell -NoProfile -Command ^
        "$p=Join-Path $env:APPDATA 'SoftVelocity\Clarion\11.0\ClarionProperties.xml';" ^
        "if(Test-Path $p){([xml](Get-Content $p)).SelectNodes('//Properties[@name=\"Clarion.Versions\"]/Properties') |" ^
        " Where-Object { $_.name -like 'Clarion 11*' } | Select-Object -First 1 -ExpandProperty name }"`) do set "CLARION_VERSION=%%v"
)
if not defined CLARION_VERSION (
    echo [ERROR] Could not determine the Clarion version name. Set CLARION_VERSION,
    echo         e.g.  set "CLARION_VERSION=Clarion 11.0.13505"
    exit /b 1
)

echo Using Clarion version: "%CLARION_VERSION%"

pushd "%~dp0"

"%MSBUILD%" ArcInputFix.cwproj /nologo /t:Build ^
    /p:Configuration=Release /p:Platform=Win32 ^
    /p:ClarionBinPath="%CLARION_BIN%" ^
    "/p:clarion_version=%CLARION_VERSION%"

set "_rc=%errorlevel%"

popd

if "%_rc%"=="0" (
    rem Model=Dll: the exe needs the Clarion runtime DLL at run time. Copy it
    rem next to the output exe so the build folder is directly runnable and
    rem ready to deploy.
    if exist "%~dp00release\ArcInputFix.exe" copy /y "%CLARION_BIN%\ClaRUN.dll" "%~dp00release\" >nul
    echo [OK] Built ArcInputFix.exe with ClaRUN.dll runtime
) else (
    echo [ERROR] Build failed with code %_rc%.
)

endlocal & exit /b %_rc%
