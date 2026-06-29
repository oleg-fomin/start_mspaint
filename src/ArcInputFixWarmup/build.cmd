@echo off
rem ===========================================================================
rem Build ArcInputFixWarmup: the windowless package-identity composition/input
rem warm-up helper, packed (and optionally signed) as an MSIX.
rem
rem Run from a "x64 Native Tools Command Prompt for VS", or just run this file -
rem it locates and imports the VS build environment (vcvars64) like the sibling
rem src\ArcInputFix\build.cmd does.
rem
rem Outputs (in this folder):
rem   ArcInputFixWarmup.exe            x64, static CRT, windowless
rem   ArcInputFixWarmup.msix           packed app package
rem   ArcInputFixWarmup.cer            (only when self-signed for dev/test)
rem
rem Signing:
rem   * By default, if no cert is supplied, a self-signed DEV certificate is
rem     created/reused so the package can be deployed for testing on the 268V
rem     hardware (you must trust the .cer first - see deploy script).
rem   * For fleet release, pass a real code-signing cert:
rem       set SIGN_PFX=C:\path\to\cert.pfx
rem       set SIGN_PFX_PASSWORD=...            (optional)
rem       build.cmd
rem     and make sure AppxManifest.xml's Identity/Publisher matches the cert
rem     subject exactly.
rem ===========================================================================

setlocal enabledelayedexpansion

rem --- Import the VS build environment if needed ----------------------------
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
rem %~dp0 ends with a backslash, so "%~dp0" is parsed as an escaped quote (\") and
rem swallows the next argument. Capture the script dir WITHOUT a trailing backslash
rem (working dir after pushd) for any argument passed bare-quoted to a sub-process.
set "_here=%CD%"

rem --- 1) Compile the windowless helper -------------------------------------
cl /nologo /W4 /O1 /EHsc /MT /std:c++17 /DUNICODE /D_UNICODE ArcInputFixWarmup.cpp ^
   /link /SUBSYSTEM:WINDOWS /OUT:ArcInputFixWarmup.exe
set "_rc=%errorlevel%"
del /q ArcInputFixWarmup.obj 2>nul
if not "%_rc%"=="0" (
    echo [ERROR] Compile failed with code %_rc%.
    popd & endlocal & exit /b %_rc%
)
echo [OK] Built %~dp0ArcInputFixWarmup.exe

rem --- 2) Locate Windows SDK tools (makeappx / signtool) --------------------
set "_makeappx="
for %%T in (makeappx.exe) do if not defined _makeappx set "_makeappx=%%~$PATH:T"
set "_signtool="
for %%T in (signtool.exe) do if not defined _signtool set "_signtool=%%~$PATH:T"
if not defined _makeappx (
    for /f "usebackq delims=" %%D in (`powershell -NoProfile -Command "$r='HKLM:\SOFTWARE\WOW6432Node\Microsoft\Microsoft SDKs\Windows\v10.0'; $k=(Get-ItemProperty $r).InstallationFolder; $v=(Get-ChildItem (Join-Path $k 'bin') -Directory ^| Where-Object Name -like '10.*' ^| Sort-Object Name -Descending ^| Select-Object -First 1).FullName; Join-Path $v 'x64'"`) do set "_sdkbin=%%D"
    if exist "!_sdkbin!\makeappx.exe" set "_makeappx=!_sdkbin!\makeappx.exe"
    if exist "!_sdkbin!\signtool.exe" set "_signtool=!_sdkbin!\signtool.exe"
)
if not defined _makeappx (
    echo [WARN] makeappx.exe not found; built the exe only ^(no MSIX^).
    echo        Install the Windows 10/11 SDK to pack the package.
    popd & endlocal & exit /b 0
)

rem --- 3) Stage the package layout -----------------------------------------
set "_stage=%~dp0obj\appx"
if exist "!_stage!" rmdir /s /q "!_stage!"
mkdir "!_stage!"
mkdir "!_stage!\Assets"
copy /y ArcInputFixWarmup.exe "!_stage!\" >nul
copy /y AppxManifest.xml "!_stage!\" >nul

rem Generate simple placeholder logo PNGs the manifest references (replace with
rem real branded assets for release; size/shape is all the packer needs).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0New-Assets.ps1" -OutDir "!_stage!\Assets"
if errorlevel 1 (
    echo [ERROR] Failed to generate package assets.
    popd & endlocal & exit /b 1
)

rem --- 4) Pack the MSIX -----------------------------------------------------
"!_makeappx!" pack /o /d "!_stage!" /p "%~dp0ArcInputFixWarmup.msix" /nv
if errorlevel 1 (
    echo [ERROR] makeappx pack failed.
    popd & endlocal & exit /b 1
)
echo [OK] Packed %~dp0ArcInputFixWarmup.msix

rem --- 5) Sign --------------------------------------------------------------
if not defined _signtool (
    echo [WARN] signtool.exe not found; package is UNSIGNED and will not register.
    popd & endlocal & exit /b 0
)

if defined SIGN_PFX (
    rem Release: sign with the supplied code-signing cert.
    if defined SIGN_PFX_PASSWORD (
        "!_signtool!" sign /fd SHA256 /a /f "%SIGN_PFX%" /p "%SIGN_PFX_PASSWORD%" "%~dp0ArcInputFixWarmup.msix"
    ) else (
        "!_signtool!" sign /fd SHA256 /a /f "%SIGN_PFX%" "%~dp0ArcInputFixWarmup.msix"
    )
    if errorlevel 1 ( echo [ERROR] signtool sign failed. & popd & endlocal & exit /b 1 )
    echo [OK] Signed with %SIGN_PFX%
) else (
    rem Dev/test: create (once) and reuse a self-signed cert whose subject equals
    rem the manifest Publisher, then sign with it and export the .cer to trust.
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0New-DevCert.ps1" ^
        -Manifest "%~dp0AppxManifest.xml" -OutDir "!_here!" -SignTool "!_signtool!" -Package "%~dp0ArcInputFixWarmup.msix"
    if errorlevel 1 ( echo [ERROR] dev-sign failed. & popd & endlocal & exit /b 1 )
)

popd
endlocal & exit /b 0
