<#
.SYNOPSIS
    Install (or remove) the ArcInputFix logon scheduled task on a machine.

.DESCRIPTION
    Copies ArcInputFix.exe to an install directory and registers a scheduled
    task that runs it hidden at every logon. Two trigger modes:

      -Action PointerDm  (default)  in-process input warm-up. Runs in the
                                     interactive user's session, least privilege.
                                     No elevation of the action itself required.

      -Action Service -ServiceName <name>   starts a demand-start service.
                                     Registers an ELEVATED task running as SYSTEM
                                     at logon (service start needs privilege).

      -Action Mspaint    fallback: launch mspaint hidden, wait, kill.

    Use -Uninstall to remove the task (and optionally the files).

    Must be run elevated (it writes to Program Files and registers a system task).

.PARAMETER SourceExe
    Path to the built ArcInputFix.exe. Default: ..\src\ArcInputFix\ArcInputFix.exe

.PARAMETER InstallDir
    Where to copy the exe. Default: %ProgramFiles%\ArcInputFix

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\deploy\Install-ArcInputFix.ps1

.EXAMPLE
    .\deploy\Install-ArcInputFix.ps1 -Action Service -ServiceName TabletInputService

.EXAMPLE
    .\deploy\Install-ArcInputFix.ps1 -Uninstall
#>
[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
    [Parameter(ParameterSetName = 'Install')]
    [ValidateSet('PointerDm', 'Service', 'Mspaint')]
    [string] $Action = 'PointerDm',

    [Parameter(ParameterSetName = 'Install')]
    [string] $ServiceName,

    [Parameter(ParameterSetName = 'Install')]
    [string] $SourceExe,

    [string] $InstallDir = (Join-Path $env:ProgramFiles 'ArcInputFix'),

    [string] $TaskName = 'ArcInputFix',

    [Parameter(ParameterSetName = 'Uninstall')]
    [switch] $Uninstall,

    [Parameter(ParameterSetName = 'Uninstall')]
    [switch] $RemoveFiles
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot can be empty depending on how the script is invoked; resolve the
# script directory robustly and use it for the default source-exe location.
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot }
             elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath }
             elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path }
             else { (Get-Location).Path }

if ([string]::IsNullOrWhiteSpace($SourceExe)) {
    $SourceExe = Join-Path $scriptDir '..\src\ArcInputFix\ArcInputFix.exe'
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
    if ($RemoveFiles -and (Test-Path -LiteralPath $InstallDir)) {
        Remove-Item -LiteralPath $InstallDir -Recurse -Force
        Write-Host "Removed $InstallDir." -ForegroundColor Green
    }
    return
}

# ---------------------------------------------------------------------------
# Validate inputs
# ---------------------------------------------------------------------------
if ($Action -eq 'Service' -and [string]::IsNullOrWhiteSpace($ServiceName)) {
    throw 'Action Service requires -ServiceName <name>.'
}
if (-not (Test-Path -LiteralPath $SourceExe)) {
    throw "ArcInputFix.exe not found at '$SourceExe'. Build it first (src\ArcInputFix\build.cmd)."
}

# ---------------------------------------------------------------------------
# Deploy the exe
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir | Out-Null
}
$destExe = Join-Path $InstallDir 'ArcInputFix.exe'
Copy-Item -LiteralPath $SourceExe -Destination $destExe -Force
Write-Host "Deployed exe -> $destExe" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Build the task (arguments + principal depend on the action)
# ---------------------------------------------------------------------------
switch ($Action) {
    'Service' {
        $arguments = "--service `"$ServiceName`""
        # Service start needs privilege -> run as SYSTEM, highest.
        $principal = New-ScheduledTaskPrincipal -UserId 'S-1-5-18' -RunLevel Highest
    }
    'Mspaint' {
        $arguments = '--mspaint'
        # Runs per interactive user, least privilege.
        $principal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited
    }
    default {
        $arguments = '--pointer-dm'
        $principal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited
    }
}

$action  = New-ScheduledTaskAction -Execute $destExe -Argument $arguments
$trigger = New-ScheduledTaskTrigger -AtLogOn
$settings = New-ScheduledTaskSettingsSet `
    -Hidden `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 1)

# Replace any existing registration.
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

Register-ScheduledTask `
    -TaskName $TaskName `
    -Description 'Workaround for Intel Arc (Core Ultra 268V) non-client mouse bug.' `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal | Out-Null

Write-Host "Registered logon task '$TaskName' (action: $Action, args: $arguments)." -ForegroundColor Green
Write-Host "Test now with:  Start-ScheduledTask -TaskName $TaskName" -ForegroundColor Cyan
Write-Host "Then verify Clarion caption drag / border resize, and check the" -ForegroundColor Cyan
Write-Host "Application event log (source 'ArcInputFix') for the result." -ForegroundColor Cyan
