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

      -Mechanism Run (default)      : a REG_EXPAND_SZ value under ...\CurrentVersion\Run.
      -Mechanism Shortcut           : a .lnk to the alias in the Startup folder.

    TIMING (268V observation): both run in the explorer context that fixes the bug, but a
    Startup-FOLDER shortcut fires ~12-15s after logon because Windows THROTTLES Startup
    items, leaving Clarion broken for that ~15s if opened immediately. A Run KEY fires
    EARLIER (Run values are processed earlier in shell init and are not subject to the
    Startup-folder deferral), so -Mechanism Run is now the DEFAULT (and what the fleet
    should use). Use -Mechanism Shortcut only if a Run key is blocked or you specifically
    want the Startup-folder path.

    And two scopes:
      -Scope AllUsers (default)     : every user. Provisions the package for all users AND
                                      copies the alias into THIS SCRIPT'S FOLDER, then points
                                      HKLM\...\Run at that fixed copy - one absolute path
                                      that resolves for EVERY user, including pre-existing
                                      accounts that never registered the package themselves
                                      (provisioning only covers FUTURE profiles). This is the
                                      fleet-rollout default: with a CA-trusted .msix sitting
                                      next to this script (in a PERSISTENT folder), a plain
                                      elevated `.\Install-ArcInputFixLifted-Shell.ps1` (no
                                      parameters) installs the fix fleet-wide.
      -Scope CurrentUser            : this user only; also targets the fixed alias copy.
                                      Handy for a single-box dev/test.

    NOTE: because the Run value points at the alias copy in this script's folder, that
    folder must be a PERSISTENT location for the fleet (e.g. under %ProgramFiles% or a
    managed share synced locally) - do not run the installer from a temp/removable path.

    Use -Uninstall to remove whatever this script created (both scopes / mechanisms).

    HARDWARE GATE: install is a no-op unless the affected Intel Arc display adapter is
    detected (an Intel PCI adapter - MatchingDeviceId PCI\VEN_8086&DEV_ - driven by the
    Arc/Lunar-Lake 'IAG_wNext_Dynamic' INF section). This keeps a fleet-wide rollout safe
    on machines that don't have the buggy GPU. Pass -Force to install regardless.

    NOTE: this REPLACES the scheduled-task approach for this helper. Use
    Install-ArcInputFixLifted.ps1 (the task version) only as a documented dead-end.

.PARAMETER Package
    Path to the ArcInputFixLifted MSIX. If omitted, the script looks for
    ArcInputFixLifted.msix IN THE SCRIPT'S OWN FOLDER first (so a signed package can ship
    right next to this script for fleet deployment), then falls back to the dev build
    output ..\src\ArcInputFixLifted\ArcInputFixLifted.msix.

.PARAMETER DevCert
    Optional path to ArcInputFixLifted.cer to trust (dev/test only).

.PARAMETER Force
    Install even when no affected Intel Arc adapter is detected (bypass the hardware gate).

.EXAMPLE
    # Fleet rollout (DEFAULT): a CA-signed ArcInputFixLifted.msix sits beside this script;
    # no parameters needed. Installs for all users (HKLM Run + provisioned package). Run
    # from an elevated PowerShell.
    powershell -ExecutionPolicy Bypass -File .\Install-ArcInputFixLifted-Shell.ps1

.EXAMPLE
    # Single-box dev/test for the current user only, trusting the self-signed dev cert:
    powershell -ExecutionPolicy Bypass -File .\deploy\Install-ArcInputFixLifted-Shell.ps1 -Scope CurrentUser -DevCert .\src\ArcInputFixLifted\ArcInputFixLifted.cer

.EXAMPLE
    # Current user via the Startup-folder shortcut instead (closest to the manual
    # double-click, but throttled ~12-15s after logon):
    powershell -ExecutionPolicy Bypass -File .\deploy\Install-ArcInputFixLifted-Shell.ps1 -Scope CurrentUser -Mechanism Shortcut -DevCert .\src\ArcInputFixLifted\ArcInputFixLifted.cer

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\deploy\Install-ArcInputFixLifted-Shell.ps1 -Uninstall
#>
[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
    [Parameter(ParameterSetName = 'Install')]
    [string] $Package,

    [Parameter(ParameterSetName = 'Install')]
    [string] $DevCert,

    [Parameter(ParameterSetName = 'Install')]
    [ValidateSet('CurrentUser', 'AllUsers')]
    [string] $Scope = 'AllUsers',

    [Parameter(ParameterSetName = 'Install')]
    [ValidateSet('Shortcut', 'Run')]
    [string] $Mechanism = 'Run',

    # Install even when no affected Intel Arc adapter is detected (skip the hardware gate).
    [Parameter(ParameterSetName = 'Install')]
    [switch] $Force,

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

# Fixed-location COPY of the alias, kept next to this script. Provisioning stages the
# package machine-wide but the per-user %LOCALAPPDATA% alias only exists AFTER the package
# is registered for that specific user - so pre-existing users have no alias yet. Copying
# the alias into this persistent deploy folder gives ONE absolute path that is identical
# for every user, which the HKLM Run value then targets (no per-user registration needed).
$AliasCopyPath = Join-Path $PSScriptRoot $Alias

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

# An App Execution Alias is NOT a normal file - it is a reparse point tagged
# IO_REPARSE_TAG_APPEXECLINK (0x8000001B). Copy-Item / Explorer open it with
# follow-reparse semantics and fail ("The file cannot be accessed by the system.").
# The fix is to copy the RAW reparse buffer the way Far Manager does: read it with
# FSCTL_GET_REPARSE_POINT and stamp it onto a freshly created placeholder file with
# FSCTL_SET_REPARSE_POINT. This preserves the alias so it launches from the new path.
function Copy-ReparsePoint {
    param(
        [Parameter(Mandatory)] [string] $Source,
        [Parameter(Mandatory)] [string] $Destination
    )

    if (-not ('ArcAlias.Native' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;

namespace ArcAlias
{
    public static class Native
    {
        const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;
        const uint FILE_FLAG_BACKUP_SEMANTICS    = 0x02000000;
        const uint FSCTL_GET_REPARSE_POINT       = 0x000900A8;
        const uint FSCTL_SET_REPARSE_POINT       = 0x000900A4;
        const int  MAXIMUM_REPARSE_DATA_BUFFER_SIZE = 16 * 1024;
        const uint GENERIC_READ  = 0x80000000;
        const uint GENERIC_WRITE = 0x40000000;
        const uint FILE_SHARE_READ = 0x1;
        const uint OPEN_EXISTING = 3;
        const uint CREATE_ALWAYS = 2;
        static readonly IntPtr INVALID_HANDLE_VALUE = new IntPtr(-1);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr CreateFileW(string lpFileName, uint dwDesiredAccess, uint dwShareMode,
            IntPtr lpSecurityAttributes, uint dwCreationDisposition, uint dwFlagsAndAttributes, IntPtr hTemplateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        static extern bool CloseHandle(IntPtr hObject);

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        static extern bool DeviceIoControl(IntPtr hDevice, uint dwIoControlCode,
            byte[] lpInBuffer, int nInBufferSize, byte[] lpOutBuffer, int nOutBufferSize,
            out int lpBytesReturned, IntPtr lpOverlapped);

        public static void Copy(string source, string destination)
        {
            // Read the raw reparse buffer from the alias without dereferencing it.
            byte[] buffer = new byte[MAXIMUM_REPARSE_DATA_BUFFER_SIZE];
            int bytesReturned;
            IntPtr src = CreateFileW(source, GENERIC_READ, FILE_SHARE_READ, IntPtr.Zero, OPEN_EXISTING,
                FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS, IntPtr.Zero);
            if (src == INVALID_HANDLE_VALUE) throw new Win32Exception(Marshal.GetLastWin32Error(), "open source alias");
            try
            {
                if (!DeviceIoControl(src, FSCTL_GET_REPARSE_POINT, null, 0, buffer, buffer.Length, out bytesReturned, IntPtr.Zero))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "FSCTL_GET_REPARSE_POINT");
            }
            finally { CloseHandle(src); }

            // Create an empty placeholder, then stamp the reparse buffer onto it.
            if (File.Exists(destination)) File.Delete(destination);
            IntPtr dst = CreateFileW(destination, GENERIC_WRITE, 0, IntPtr.Zero, CREATE_ALWAYS,
                FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS, IntPtr.Zero);
            if (dst == INVALID_HANDLE_VALUE) throw new Win32Exception(Marshal.GetLastWin32Error(), "create destination file");
            try
            {
                int dummy;
                if (!DeviceIoControl(dst, FSCTL_SET_REPARSE_POINT, buffer, bytesReturned, null, 0, out dummy, IntPtr.Zero))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "FSCTL_SET_REPARSE_POINT");
            }
            finally { CloseHandle(dst); }
        }
    }
}
'@
    }

    [ArcAlias.Native]::Copy($Source, $Destination)
}

function Get-StartupDir {
    param([ValidateSet('CurrentUser', 'AllUsers')] [string] $Scope)
    if ($Scope -eq 'AllUsers') { return [Environment]::GetFolderPath('CommonStartup') }
    return [Environment]::GetFolderPath('Startup')
}

# Returns $true if the affected Intel Arc display adapter (the one that needs this fix) is
# present. Display adapters are enumerated as 0000, 0001, ... under the Display class key.
# An adapter needs the fix when its MatchingDeviceId is an Intel PCI device
# (PCI\VEN_8086&DEV_) AND its InfSection driver is the Dynamic Intel Arc Graphics
# 'IAG_wNext_Dynamic' section (e.g. Lunar Lake LNL_IAG_wNext_Dynamic on the Dell Pro Plus 268V).
function Test-ArcInputFixNeeded {
    $classKey = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
    if (-not (Test-Path -LiteralPath $classKey)) { return $false }

    foreach ($sub in Get-ChildItem -LiteralPath $classKey -ErrorAction SilentlyContinue) {
        # Only the numeric per-adapter subkeys (0000, 0001, ...).
        if ($sub.PSChildName -notmatch '^[0-9]{4}$') { continue }

        $props = Get-ItemProperty -LiteralPath $sub.PSPath -ErrorAction SilentlyContinue
        if ($null -eq $props) { continue }

        $matchingId = [string] $props.MatchingDeviceId
        $infSection = [string] $props.InfSection

        if ($matchingId -like 'PCI\VEN_8086&DEV_*' -and $infSection -like '*IAG_wNext_Dynamic') {
            $desc = [string] $props.DriverDesc
            Write-Host "Detected affected Intel Arc adapter: '$desc' (InfSection '$infSection')." -ForegroundColor Green
            return $true
        }
    }
    return $false
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

function Remove-AliasCopy {
    if (Test-Path -LiteralPath $AliasCopyPath) {
        Remove-Item -LiteralPath $AliasCopyPath -Force
        Write-Host "Removed alias copy '$AliasCopyPath'." -ForegroundColor Green
    }
}

# ---------------------------------------------------------------------------
# Uninstall - remove every mechanism/scope this script could have created.
# ---------------------------------------------------------------------------
if ($Uninstall) {
    Remove-AliasShortcut -Scope CurrentUser
    Remove-RunValue -RunKey $HkcuRun

    Remove-AliasCopy

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
# Hardware gate - only install where the affected Intel Arc adapter is present.
# The bug is specific to that GPU/driver; on any other machine the fix is unneeded,
# so skip it (unless -Force is given) to keep the fleet install a safe no-op.
# ---------------------------------------------------------------------------
if (-not $Force) {
    if (-not (Test-ArcInputFixNeeded)) {
        Write-Host "No affected Intel Arc display adapter detected - the fix is not needed on this machine." -ForegroundColor Yellow
        Write-Host "Nothing installed. Use -Force to install anyway." -ForegroundColor Yellow
        return
    }
} else {
    Write-Host "-Force specified - skipping the Intel Arc hardware check." -ForegroundColor DarkYellow
}

# ---------------------------------------------------------------------------
# Resolve / validate the package path.
# ---------------------------------------------------------------------------
if (-not $Package) {
    $Package = Join-Path $PSScriptRoot 'ArcInputFixLifted.msix'
}
if (-not (Test-Path -LiteralPath $Package)) {
    Write-Host "ArcInputFixLifted.msix not found at '$PSScriptRoot'" -ForegroundColor DarkYellow
    $Package = Join-Path $PSScriptRoot '..\src\ArcInputFixLifted\ArcInputFixLifted.msix'
    Write-Host "Trying find package at '$Package'." -ForegroundColor DarkYellow

    if (-not (Test-Path -LiteralPath $Package)) {
        throw "ArcInputFixLifted.msix not found at '$Package'. Build it first (src\ArcInputFixLifted\build.cmd)."
    }
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

# Copy the resolved alias into this script's folder. Provisioning only stages the package
# machine-wide; the per-user %LOCALAPPDATA% alias does not exist for pre-existing accounts
# until the package is registered for them. A single fixed copy next to this script gives
# ONE absolute path that every user's Run value can target, closing that gap. The alias is
# a reparse point, so it must be copied via Copy-ReparsePoint (raw reparse buffer) - a plain
# Copy-Item fails on it with "The file cannot be accessed by the system."
if (-not (Test-Path -LiteralPath $AliasPathThisUser)) {
    throw "Alias '$AliasPathThisUser' not found after registration - cannot create the fixed copy."
}
# The alias is a reparse point (IO_REPARSE_TAG_APPEXECLINK); Copy-Item / Explorer fail on
# it with "The file cannot be accessed by the system." Copy the raw reparse buffer instead
# (same approach that lets Far Manager copy it), which preserves a working, launchable alias.
Copy-ReparsePoint -Source $AliasPathThisUser -Destination $AliasCopyPath
if (-not (Test-Path -LiteralPath $AliasCopyPath)) {
    throw "Alias copy '$AliasCopyPath' was not created."
}
Write-Host "Copied alias reparse point to fixed path '$AliasCopyPath'." -ForegroundColor Green

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
        # Target the fixed copy next to this script - one absolute path shared by every user,
        # so the alias resolves even for accounts that never registered the package.
        New-ItemProperty -Path $runKey -Name $EntryName -Value $AliasCopyPath `
            -PropertyType String -Force | Out-Null
        Write-Host "Created Run value '$runKey\$EntryName' = '$AliasCopyPath'." -ForegroundColor Green
    }
}

Write-Host ''
Write-Host "Done. The interactive shell will launch the helper at the next logon." -ForegroundColor Cyan
Write-Host "TEST: log off and back on, then - BEFORE touching anything - confirm the Clarion" -ForegroundColor Cyan
Write-Host "      MDI child window has working caption drag / border resize / min-max-close" -ForegroundColor Cyan
Write-Host "      buttons working, and Clarion non-MDI window MENUBAR is clickable by mouse." -ForegroundColor Cyan
Write-Host "      Also check Event Viewer > Windows Logs > Application, source 'ArcInputFixLifted'." -ForegroundColor Cyan
