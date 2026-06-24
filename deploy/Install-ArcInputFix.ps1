<#
.SYNOPSIS
    Install (or remove) the ArcInputFix logon scheduled task on a machine.

.DESCRIPTION
    Copies ArcInputFix.exe to an install directory and registers a scheduled
    task that runs it hidden at every logon. The exe has a single behaviour
    (launch Paint via its App Execution Alias to re-arm the non-client input
    path), so the task is registered with no arguments, running in the
    interactive user's session at least privilege.

    Use -Uninstall to remove the task (and optionally the files).

    Must be run elevated (it writes to Program Files and registers a system task).

.PARAMETER SourceExe
    Path to the built ArcInputFix.exe. Default: ..\src\ArcInputFix\ArcInputFix.exe

.PARAMETER InstallDir
    Where to copy the exe. Default: %ProgramFiles%\ArcInputFix

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\deploy\Install-ArcInputFix.ps1

.EXAMPLE
    .\deploy\Install-ArcInputFix.ps1 -Uninstall
#>
[CmdletBinding(DefaultParameterSetName = 'Install')]
param(
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
# Build the task. The exe has a single behaviour and takes no arguments; it
# runs per interactive user at least privilege.
# ---------------------------------------------------------------------------
$principal = New-ScheduledTaskPrincipal -GroupId 'S-1-5-32-545' -RunLevel Limited

$action  = New-ScheduledTaskAction -Execute $destExe
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

Write-Host "Registered logon task '$TaskName'." -ForegroundColor Green
Write-Host "Test now with:  Start-ScheduledTask -TaskName $TaskName" -ForegroundColor Cyan
Write-Host "Then verify Clarion caption drag / border resize, and check the" -ForegroundColor Cyan
Write-Host "Application event log (source 'ArcInputFix') for the result." -ForegroundColor Cyan
