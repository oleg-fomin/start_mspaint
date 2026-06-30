<#
.SYNOPSIS
    Install (or remove) ArcInputFixLifted so the INTERACTIVE SHELL (explorer.exe)
    launches it at every logon - the launch context proven to fix the Intel Arc
    (Core Ultra 268V) non-client mouse bug.

.DESCRIPTION
    Round 16 breakthrough (Dell 268V): ArcInputFixLifted.exe launched by the At-logon
    SCHEDULED TASK (automatically or via Start-ScheduledTask) does NOT re-arm caption
    drag / border resize / min-max-close. But DOUBLE-CLICKING the very same App Execution
    Alias - %LOCALAPPDATA%\Microsoft\WindowsApps\ArcInputFixLifted.exe - in File Explorer
    DOES fix it.

    The differentiator is the LAUNCH CONTEXT, not the binary:
      * Task Scheduler spawns the helper from the Schedule SERVICE host - it is NOT a
        child of the interactive shell.
      * A double-click is launched BY explorer.exe inside the user's interactive logon
        session.
    (This also explains the earlier paradox: broker activation fixed the bug from
    powershell.exe but not from a plain service-spawned Win32 exe.)

    This installer reproduces the WORKING context automatically by making explorer.exe
    launch the helper at logon - the same way Startup items and a double-click are
    launched. Two interchangeable, explorer-launched mechanisms:

      -Mechanism Shortcut (default) : a .lnk to the alias in the Startup folder.
      -Mechanism Run                : a REG_EXPAND_SZ value under ...\CurrentVersion\Run.

    And two scopes:
      -Scope CurrentUser (default)  : this user only; uses the per-user alias directly.
                                      Best for the Dell retest.
      -Scope AllUsers               : every user. Forces HKLM\...\Run with a REG_EXPAND_SZ
                                      value so %LOCALAPPDATA% resolves to EACH user's own
                                      alias at logon, and provisions the package for all
                                      users so that alias exists. (Fleet rollout.)

    Use -Uninstall to remove whatever this script created (both scopes / mechanisms).

    NOTE: this REPLACES the scheduled-task approach for this helper. Use
    Install-ArcInputFixLifted.ps1 (the task version) only as a documented dead-end.

.PARAMETER Package
    Path to ArcInputFixLifted.msix. Default: ..\src\ArcInputFixLifted\ArcInputFixLifted.msix

.PARAMETER DevCert
    Optional path to ArcInputFixLifted.cer to trust (dev/test only).

.EXAMPLE
    # Dell retest (current user, Startup shortcut = closest to the proven double-click):
    .\deploy\Install-ArcInputFixLifted-Shell.ps1 -DevCert .\src\ArcInputFixLifted\ArcInputFixLifted.cer

.EXAMPLE
    # Fleet rollout (all users, HKLM Run, package provisioned for all users):
    .\deploy\Install-ArcInputFixLifted-Shell.ps1 -Scope AllUsers

.EXAMPLE
    .\deploy\Install-ArcInputFixLifted-Shell.ps1 -Uninstall
#>
[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
    [Parameter(ParameterSetName = 'Install')]
    [string] $Package,

    [Parameter(ParameterSetName = 'Install')]
    [string] $DevCert,

    [Parameter(ParameterSetName = 'Install')]
    [ValidateSet('CurrentUser', 'AllUsers')]
    [string] $Scope = 'CurrentUser',

    [Parameter(ParameterSetName = 'Install')]
    [ValidateSet('Shortcut', 'Run')]
    [string] $Mechanism = 'Shortcut',

    [string] $PackageName = 'ArcInputFix.Lifted',

    [string] $Alias = 'ArcInputFixLifted.exe',

    [string] $EntryName = 'ArcInputFixLifted',

    [Parameter(ParameterSetName = 'Uninstall')]
    [switch] $Uninstall
)

$ErrorActionPreference = 'Stop'

# Per-user App Execution Alias path. As a REG_EXPAND_SZ value this %LOCALAPPDATA% token
# resolves to the launching user's own profile at logon.
$AliasPathExpandable = "%LOCALAPPDATA%\Microsoft\WindowsApps\$Alias"
$AliasPathThisUser   = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\$Alias"

$HkcuRun       = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$HklmRun       = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run'
$ShortcutLeaf  = "$EntryName.lnk"

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Assert-Admin {
    if (-not (Test-Admin)) {
        throw 'This step needs an elevated (Administrator) PowerShell.'
    }
}

function Get-StartupDir {
    param([ValidateSet('CurrentUser', 'AllUsers')] [string] $Scope)
    if ($Scope -eq 'AllUsers') { return [Environment]::GetFolderPath('CommonStartup') }
    return [Environment]::GetFolderPath('Startup')
}

function Remove-AliasShortcut {
    param([ValidateSet('CurrentUser', 'AllUsers')] [string] $Scope)
    $lnk = Join-Path (Get-StartupDir -Scope $Scope) $ShortcutLeaf
    if (Test-Path -LiteralPath $lnk) {
        Remove-Item -LiteralPath $lnk -Force
        Write-Host "Removed Startup shortcut '$lnk'." -ForegroundColor Green
    }
}

function Remove-RunValue {
    param([string] $RunKey)
    $item = Get-ItemProperty -Path $RunKey -Name $EntryName -ErrorAction SilentlyContinue
    if ($null -ne $item) {
        Remove-ItemProperty -Path $RunKey -Name $EntryName
        Write-Host "Removed Run value '$RunKey\$EntryName'." -ForegroundColor Green
    }
}

# ---------------------------------------------------------------------------
# Uninstall - remove every mechanism/scope this script could have created.
# ---------------------------------------------------------------------------
if ($Uninstall) {
    Remove-AliasShortcut -Scope CurrentUser
    Remove-RunValue -RunKey $HkcuRun

    if (Test-Admin) {
        Remove-AliasShortcut -Scope AllUsers
        Remove-RunValue -RunKey $HklmRun
    } else {
        Write-Host "Skipping all-users cleanup (HKLM Run / Common Startup) - not elevated." -ForegroundColor DarkYellow
    }

    $pkg = Get-AppxPackage -Name $PackageName -ErrorAction SilentlyContinue
    if ($pkg) {
        Remove-AppxPackage -Package $pkg.PackageFullName
        Write-Host "Removed package '$($pkg.PackageFullName)' for this user." -ForegroundColor Green
    }

    if (Test-Admin) {
        $prov = Get-AppxProvisionedPackage -Online |
            Where-Object { $_.DisplayName -eq $PackageName }
        foreach ($p in $prov) {
            Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName | Out-Null
            Write-Host "Removed provisioned package '$($p.PackageName)'." -ForegroundColor Green
        }
    }
    return
}

# ---------------------------------------------------------------------------
# Resolve / validate the package path.
# ---------------------------------------------------------------------------
if (-not $Package) {
    $Package = Join-Path $PSScriptRoot '..\src\ArcInputFixLifted\ArcInputFixLifted.msix'
}
if (-not (Test-Path -LiteralPath $Package)) {
    throw "ArcInputFixLifted.msix not found at '$Package'. Build it first (src\ArcInputFixLifted\build.cmd)."
}

# All-users work (cert trust, HKLM, provisioning) requires elevation.
if ($Scope -eq 'AllUsers' -or $DevCert) { Assert-Admin }

# AllUsers must use a per-user-resolving Run value; a single .lnk cannot point to every
# user's own %LOCALAPPDATA% alias, so force the Run mechanism in that scope.
if ($Scope -eq 'AllUsers' -and $Mechanism -eq 'Shortcut') {
    Write-Host "Scope AllUsers requires the Run mechanism (per-user alias resolution); using -Mechanism Run." -ForegroundColor DarkYellow
    $Mechanism = 'Run'
}

# ---------------------------------------------------------------------------
# (dev/test only) trust the self-signed cert so the MSIX can register.
# ---------------------------------------------------------------------------
if ($DevCert) {
    if (-not (Test-Path -LiteralPath $DevCert)) { throw "DevCert '$DevCert' not found." }
    Import-Certificate -FilePath $DevCert -CertStoreLocation Cert:\LocalMachine\TrustedPeople | Out-Null
    Write-Host "Trusted dev certificate '$DevCert' (LocalMachine\TrustedPeople)." -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Register the package so the App Execution Alias exists.
#   CurrentUser : Add-AppxPackage (per user).
#   AllUsers    : provision for future users + register for the current user too, so the
#                 alias exists now for an immediate test.
# ---------------------------------------------------------------------------
Add-AppxPackage -Path $Package
Write-Host "Registered package for this user from '$Package'." -ForegroundColor Green

if ($Scope -eq 'AllUsers') {
    Add-AppxProvisionedPackage -Online -PackagePath $Package -SkipLicense | Out-Null
    Write-Host "Provisioned package for all (future) users." -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Install the explorer-launched startup entry.
# These are executed by explorer.exe at logon - the SAME launch path as a double-click,
# which is the context proven to fix the bug.
# ---------------------------------------------------------------------------
switch ($Mechanism) {
    'Shortcut' {
        $startupDir = Get-StartupDir -Scope $Scope
        if (-not (Test-Path -LiteralPath $startupDir)) {
            New-Item -ItemType Directory -Path $startupDir -Force | Out-Null
        }
        $lnkPath = Join-Path $startupDir $ShortcutLeaf

        $wsh = New-Object -ComObject WScript.Shell
        try {
            $sc = $wsh.CreateShortcut($lnkPath)
            $sc.TargetPath  = $AliasPathThisUser      # the resolved alias - exactly what a double-click runs
            $sc.WindowStyle = 7                        # minimized, no-activate (the app is headless anyway)
            $sc.Description  = 'Arc Input Fix (Lifted) - shell-launched logon warm-up'
            $sc.Save()
        } finally {
            [void][Runtime.InteropServices.Marshal]::ReleaseComObject($wsh)
        }
        Write-Host "Created Startup shortcut '$lnkPath' -> '$AliasPathThisUser'." -ForegroundColor Green
    }
    'Run' {
        $runKey = if ($Scope -eq 'AllUsers') { $HklmRun } else { $HkcuRun }
        # REG_EXPAND_SZ so %LOCALAPPDATA% resolves to the launching user's profile at logon.
        New-ItemProperty -Path $runKey -Name $EntryName -Value $AliasPathExpandable `
            -PropertyType ExpandString -Force | Out-Null
        Write-Host "Created Run value '$runKey\$EntryName' = '$AliasPathExpandable'." -ForegroundColor Green
    }
}

Write-Host ''
Write-Host "Done. The interactive shell will launch the helper at the next logon." -ForegroundColor Cyan
Write-Host "TEST: log off and back on, then - BEFORE touching anything - confirm the Clarion" -ForegroundColor Cyan
Write-Host "      MDI child has working caption drag / border resize / min-max-close, with no" -ForegroundColor Cyan
Write-Host "      flash. Also check Event Viewer > Windows Logs > Application, source" -ForegroundColor Cyan
Write-Host "      'ArcInputFixLifted'." -ForegroundColor Cyan
