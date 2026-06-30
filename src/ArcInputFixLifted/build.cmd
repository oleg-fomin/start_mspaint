@echo off
rem ===========================================================================
rem Build ArcInputFixLifted: the WinUI 3 helper that loads the LIFTED Microsoft.UI.*
rem input/composition stack (the differentiator from tools/fixdiff-out), packed and
rem signed as an MSIX so it runs with package identity.
rem
rem Pipeline:
rem   1. dotnet publish -c Release -r win-x64 (self-contained -> carries the lifted
rem      Microsoft.UI.* runtime next to the exe).
rem   2. overlay AppxManifest.xml + generated Assets into the publish folder.
rem   3. makeappx pack -> ArcInputFixLifted.msix.
rem   4. signtool sign (self-signed dev cert by default; SIGN_PFX for release).
rem
rem Outputs (in this folder):
rem   ArcInputFixLifted.msix           packed app package
rem   ArcInputFixLifted.cer            (only when self-signed for dev/test)
rem
rem Release signing:
rem   set SIGN_PFX=C:\path\to\cert.pfx
rem   set SIGN_PFX_PASSWORD=...            (optional)
rem   build.cmd
rem and make AppxManifest.xml's Identity/Publisher match the cert subject exactly.
rem ===========================================================================

setlocal enabledelayedexpansion

pushd "%~dp0"
set "_here=%CD%"

where dotnet >nul 2>nul
if errorlevel 1 (
    echo [ERROR] dotnet SDK not found on PATH. Install the .NET 8/9 SDK.
    popd & endlocal & exit /b 1
)

rem --- 1) Publish self-contained (carries the lifted Microsoft.UI.* runtime) -----
set "_pub=%_here%\bin\x64\Release\net8.0-windows10.0.19041.0\win-x64\publish"
dotnet publish "%_here%\ArcInputFixLifted.csproj" -c Release -r win-x64 --nologo
if errorlevel 1 (
    echo [ERROR] dotnet publish failed.
    popd & endlocal & exit /b 1
)
if not exist "%_pub%\ArcInputFixLifted.exe" (
    echo [ERROR] published exe not found at "%_pub%".
    popd & endlocal & exit /b 1
)
echo [OK] Published self-contained WinUI 3 app -> %_pub%

rem --- 2) Locate Windows SDK tools (makeappx / signtool) ------------------------
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
    echo [WARN] makeappx.exe not found; published the app only ^(no MSIX^).
    echo        Install the Windows 10/11 SDK to pack the package.
    popd & endlocal & exit /b 0
)

rem --- 3) Overlay the package manifest + assets into the publish folder ----------
copy /y "%_here%\AppxManifest.xml" "%_pub%\" >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%_here%\New-Assets.ps1" -OutDir "%_pub%\Assets"
if errorlevel 1 (
    echo [ERROR] Failed to generate package assets.
    popd & endlocal & exit /b 1
)

rem makeappx fails if a resources.pri describes a different layout; remove the
rem app-built one (the package does not need a PRI for our headless helper).
if exist "%_pub%\resources.pri" del /q "%_pub%\resources.pri"

rem --- 4) Pack the MSIX ---------------------------------------------------------
"!_makeappx!" pack /o /d "%_pub%" /p "%_here%\ArcInputFixLifted.msix" /nv
if errorlevel 1 (
    echo [ERROR] makeappx pack failed.
    popd & endlocal & exit /b 1
)
echo [OK] Packed %_here%\ArcInputFixLifted.msix

rem --- 5) Sign ------------------------------------------------------------------
if not defined _signtool (
    echo [WARN] signtool.exe not found; package is UNSIGNED and will not register.
    popd & endlocal & exit /b 0
)

if defined SIGN_PFX (
    if defined SIGN_PFX_PASSWORD (
        "!_signtool!" sign /fd SHA256 /a /f "%SIGN_PFX%" /p "%SIGN_PFX_PASSWORD%" "%_here%\ArcInputFixLifted.msix"
    ) else (
        "!_signtool!" sign /fd SHA256 /a /f "%SIGN_PFX%" "%_here%\ArcInputFixLifted.msix"
    )
    if errorlevel 1 ( echo [ERROR] signtool sign failed. & popd & endlocal & exit /b 1 )
    echo [OK] Signed with %SIGN_PFX%
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%_here%\New-DevCert.ps1" ^
        -Manifest "%_here%\AppxManifest.xml" -OutDir "!_here!" -SignTool "!_signtool!" -Package "%_here%\ArcInputFixLifted.msix"
    if errorlevel 1 ( echo [ERROR] dev-sign failed. & popd & endlocal & exit /b 1 )
)

popd
endlocal & exit /b 0
