<#
.SYNOPSIS
    Install (or remove) the ArcInputFixWarmup MSIX helper and its hidden logon
    scheduled task.

.DESCRIPTION
    Installs the owned, package-identity ArcInputFixWarmup helper that briefly
    spins up the WinUI 3 composition/input stack with package identity and exits.

    NOTE: this helper was TESTED on the 268V hardware and DID NOT fix the bug
    (package identity + the in-box warm-up is necessary-but-not-sufficient). It is
    retained only for further differential-diagnosis testing, not as a shipping
    deliverable. The proven fix remains the Paint-alias ArcInputFix.exe /
    start_mspaint.ps1. See docs/test-warmup-helper.md.

    Install does:
      1. (dev only) trusts the exported self-signed .cer if -DevCert is given, so
         the package can register on a test box. Skip for a properly CA-signed
         package.
      2. Registers the MSIX for the current user (Add-AppxPackage).
      3. Registers a hidden At-logon scheduled task that launches the helper via
         its App Execution Alias
         (%LOCALAPPDATA%\Microsoft\WindowsApps\ArcInputFixWarmup.exe) - the same
         CreateProcess-with-identity launch the Paint alias uses - running as the
         interactive user at least privilege, no arguments.

    Use -Uninstall to remove the task and the package.

    Note: Add-AppxPackage is per-user, so the install steps run in the user's
    context. The scheduled-task registration needs elevation.

.PARAMETER Package
    Path to ArcInputFixWarmup.msix. Default: ..\src\ArcInputFixWarmup\ArcInputFixWarmup.msix

.PARAMETER DevCert
    Optional path to ArcInputFixWarmup.cer to trust (dev/test only).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\deploy\Install-ArcInputFixWarmup.ps1 `
        -DevCert ..\src\ArcInputFixWarmup\ArcInputFixWarmup.cer

.EXAMPLE
    .\deploy\Install-ArcInputFixWarmup.ps1 -Uninstall
#>
[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
    [Parameter(ParameterSetName = 'Install')]
    [string] $Package,

    [Parameter(ParameterSetName = 'Install')]
    [string] $DevCert,

    [string] $TaskName = 'ArcInputFixWarmup',

    [string] $PackageName = 'ArcInputFix.Warmup',

    [string] $Alias = 'ArcInputFixWarmup.exe',

    [Parameter(ParameterSetName = 'Uninstall')]
    [switch] $Uninstall
)

$ErrorActionPreference = 'Stop'

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot }
             elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath }
             elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path }
             else { (Get-Location).Path }

if ([string]::IsNullOrWhiteSpace($Package)) {
    $Package = Join-Path $scriptDir '..\src\ArcInputFixWarmup\ArcInputFixWarmup.msix'
}

function Assert-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    if (-not $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'This script must be run from an elevated (Administrator) PowerShell.'
    }
}

Assert-Admin

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
if ($Uninstall) {
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Removed scheduled task '$TaskName'." -ForegroundColor Green
    } else {
        Write-Host "Task '$TaskName' not present." -ForegroundColor DarkGray
    }

    $pkg = Get-AppxPackage -Name $PackageName -ErrorAction SilentlyContinue
    if ($pkg) {
        Remove-AppxPackage -Package $pkg.PackageFullName
        Write-Host "Removed package '$($pkg.PackageFullName)'." -ForegroundColor Green
    } else {
        Write-Host "Package '$PackageName' not registered." -ForegroundColor DarkGray
    }
    return
}

# ---------------------------------------------------------------------------
# Validate inputs
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $Package)) {
    throw "ArcInputFixWarmup.msix not found at '$Package'. Build it first (src\ArcInputFixWarmup\build.cmd)."
}

# ---------------------------------------------------------------------------
# (dev/test only) trust the self-signed cert so the MSIX can register.
# ---------------------------------------------------------------------------
if ($DevCert) {
    if (-not (Test-Path -LiteralPath $DevCert)) {
        throw "DevCert '$DevCert' not found."
    }
    Import-Certificate -FilePath $DevCert -CertStoreLocation Cert:\LocalMachine\TrustedPeople | Out-Null
    Write-Host "Trusted dev certificate '$DevCert' (LocalMachine\TrustedPeople)." -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Register the package for the current user.
# ---------------------------------------------------------------------------
Add-AppxPackage -Path $Package
Write-Host "Registered package from '$Package'." -ForegroundColor Green

# ---------------------------------------------------------------------------
# Build the logon task. We launch the App Execution Alias rather than the
# in-package exe path, because the alias is the reparse point that runs the
# packaged app WITH identity in the interactive session - the proven trigger.
# %LOCALAPPDATA% is expanded by the task at runtime via the user's environment.
# ---------------------------------------------------------------------------
$aliasPath = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\$Alias"

$principal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited
$action    = New-ScheduledTaskAction -Execute $aliasPath
$trigger   = New-ScheduledTaskTrigger -AtLogOn
$settings  = New-ScheduledTaskSettingsSet `
    -Hidden `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 1)

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

Register-ScheduledTask `
    -TaskName $TaskName `
    -Description 'Owned package-identity warm-up for the Intel Arc (Core Ultra 268V) non-client mouse bug.' `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal | Out-Null

Write-Host "Registered logon task '$TaskName'." -ForegroundColor Green
Write-Host "Test now with:  Start-ScheduledTask -TaskName $TaskName" -ForegroundColor Cyan
Write-Host "Then verify Clarion caption drag / border resize / min-max-close, and" -ForegroundColor Cyan
Write-Host "check the Application event log (source 'ArcInputFixWarmup')." -ForegroundColor Cyan
