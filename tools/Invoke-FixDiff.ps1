<#
.SYNOPSIS
    Phase 1 trigger-isolation diagnostic for the Intel Arc non-client-mouse bug.

.DESCRIPTION
    Run this on an AFFECTED Dell Pro Plus (Core Ultra 7 268V) laptop, from a
    FRESH logon while the bug is reproducing (Clarion MDI caption drag / border
    resize dead). It snapshots system state, launches mspaint exactly the way the
    proven workaround does, then snapshots again to reveal WHAT mspaint changed
    that fixes the bug.

    It reports three diffs that map directly to the root-cause hypotheses:
      A) Services that transitioned Stopped -> Running  (top candidate; a
         demand-start service the logon never triggered).
      B) New persistent processes (helper hosts: TextInputHost, ctfmon, etc.).
      C) New kernel/system drivers loaded.

    IMPORTANT: If ALL diffs come back empty, the trigger is a one-shot in-process
    API call (e.g. EnableMouseInPointer / DirectManipulation) that leaves no
    observable service/process/driver state. In that case proceed to
    Capture-Modules.ps1 + Process Monitor / API Monitor (see guidance printed at
    the end).

.PARAMETER RunSeconds
    How long to let mspaint run before closing it. Default 6s (the workaround
    uses 5s; a little longer makes transient services easier to catch).

.PARAMETER OutputDir
    Where to write the snapshot CSVs and the summary. Default: .\fixdiff-out

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tools\Invoke-FixDiff.ps1
#>
[CmdletBinding()]
param(
    [int]    $RunSeconds = 6,
    [string] $OutputDir
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot can be empty depending on how the script is invoked; resolve the
# script directory robustly and use it for the default output location.
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot }
             elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath }
             elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path }
             else { (Get-Location).Path }

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $scriptDir 'fixdiff-out'
}

function New-Snapshot {
    <# Capture services, processes and drivers as a single state object. #>
    param([string]$Label)

    Write-Host "  [snapshot] $Label ..." -ForegroundColor DarkGray

    $services = Get-CimInstance Win32_Service |
        Select-Object Name, DisplayName, State, StartMode, ProcessId

    $processes = Get-Process |
        Select-Object Id, ProcessName, @{ N = 'Path'; E = { $_.Path } }

    # Win32_SystemDriver covers kernel-mode drivers; State Running == loaded.
    $drivers = Get-CimInstance Win32_SystemDriver |
        Select-Object Name, DisplayName, State, StartMode

    [pscustomobject]@{
        Label     = $Label
        TakenAt   = Get-Date
        Services  = $services
        Processes = $processes
        Drivers   = $drivers
    }
}

function Start-PaintHidden {
    <#
        Launch Paint the same way the workaround does:
          - classic %WINDIR%\System32\mspaint.exe if present (hidden window), else
          - packaged Microsoft.Paint via shell activation.
        Returns a hashtable describing how to stop it later.
    #>
    $classic = Join-Path $env:WINDIR 'System32\mspaint.exe'

    if (Test-Path -LiteralPath $classic) {
        $p = Start-Process -FilePath $classic -WindowStyle Hidden -PassThru
        return @{ Kind = 'Classic'; Process = $p; Before = $null }
    }

    # Packaged Paint: record paint PIDs before/after so we can stop the new one.
    $before = (Get-Process -Name 'mspaint', 'PaintStudio.View' -ErrorAction SilentlyContinue).Id
    Start-Process 'ms-paint:' -ErrorAction Stop
    Start-Sleep -Seconds 2
    return @{ Kind = 'Packaged'; Process = $null; Before = $before }
}

function Stop-Paint {
    param($Launch)

    if ($Launch.Kind -eq 'Classic' -and $Launch.Process) {
        $Launch.Process | Stop-Process -Force -ErrorAction SilentlyContinue
        return
    }

    $after = Get-Process -Name 'mspaint', 'PaintStudio.View' -ErrorAction SilentlyContinue
    foreach ($proc in $after) {
        if ($Launch.Before -notcontains $proc.Id) {
            $proc | Stop-Process -Force -ErrorAction SilentlyContinue
        }
    }
}

function Compare-Snapshots {
    param($Before, $After, [string]$AfterLabel)

    # A) Services Stopped -> Running.
    $beforeSvc = @{}
    foreach ($s in $Before.Services) { $beforeSvc[$s.Name] = $s.State }

    $svcStarted = foreach ($s in $After.Services) {
        $was = $beforeSvc[$s.Name]
        if ($s.State -eq 'Running' -and $was -ne 'Running') {
            [pscustomobject]@{
                Name      = $s.Name
                DisplayName = $s.DisplayName
                Was       = $was
                Now       = $s.State
                StartMode = $s.StartMode
                Phase     = $AfterLabel
            }
        }
    }

    # B) New processes.
    $beforePids = @{}
    foreach ($p in $Before.Processes) { $beforePids[$p.Id] = $true }

    $procNew = foreach ($p in $After.Processes) {
        if (-not $beforePids.ContainsKey($p.Id)) {
            [pscustomobject]@{
                Id          = $p.Id
                ProcessName = $p.ProcessName
                Path        = $p.Path
                Phase       = $AfterLabel
            }
        }
    }

    # C) Drivers Stopped -> Running.
    $beforeDrv = @{}
    foreach ($d in $Before.Drivers) { $beforeDrv[$d.Name] = $d.State }

    $drvStarted = foreach ($d in $After.Drivers) {
        $was = $beforeDrv[$d.Name]
        if ($d.State -eq 'Running' -and $was -ne 'Running') {
            [pscustomobject]@{
                Name      = $d.Name
                DisplayName = $d.DisplayName
                Was       = $was
                Now       = $d.State
                Phase     = $AfterLabel
            }
        }
    }

    [pscustomobject]@{
        ServicesStarted = @($svcStarted)
        ProcessesNew    = @($procNew)
        DriversStarted  = @($drvStarted)
    }
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
if (-not (Test-Path -LiteralPath $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir | Out-Null
}

Write-Host "Intel Arc NC-mouse fix - trigger isolation" -ForegroundColor Cyan
Write-Host "Output: $OutputDir`n"

$before  = New-Snapshot -Label 'before'

Write-Host "  [action] launching mspaint (hidden)..." -ForegroundColor DarkGray
$launch  = Start-PaintHidden

Start-Sleep -Seconds $RunSeconds
$during  = New-Snapshot -Label 'during'

Write-Host "  [action] closing mspaint..." -ForegroundColor DarkGray
Stop-Paint -Launch $launch
Start-Sleep -Seconds 2
$after   = New-Snapshot -Label 'after'

# Persist raw snapshots for offline analysis.
foreach ($snap in @($before, $during, $after)) {
    $snap.Services  | Export-Csv (Join-Path $OutputDir "services-$($snap.Label).csv")  -NoTypeInformation
    $snap.Processes | Export-Csv (Join-Path $OutputDir "processes-$($snap.Label).csv") -NoTypeInformation
    $snap.Drivers   | Export-Csv (Join-Path $OutputDir "drivers-$($snap.Label).csv")   -NoTypeInformation
}

$diffDuring = Compare-Snapshots -Before $before -After $during -AfterLabel 'during'
$diffAfter  = Compare-Snapshots -Before $before -After $after  -AfterLabel 'after'

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
function Write-Section {
    param([string]$Title, $Rows)
    Write-Host "`n=== $Title ===" -ForegroundColor Yellow
    if ($Rows -and $Rows.Count -gt 0) {
        $Rows | Format-Table -AutoSize | Out-String | Write-Host
    } else {
        Write-Host "  (none)" -ForegroundColor DarkGray
    }
}

# Persistent service changes (still Running after mspaint closed) are the
# strongest candidates because the bug fix also persists after mspaint closes.
$persistentSvc = $diffAfter.ServicesStarted
$transientSvc  = $diffDuring.ServicesStarted |
    Where-Object { $persistentSvc.Name -notcontains $_.Name }

Write-Section 'A. Services started and STILL running after mspaint closed (TOP CANDIDATE)' $persistentSvc
Write-Section 'A2. Services started only WHILE mspaint ran (transient)' $transientSvc
Write-Section 'B. New persistent processes' $diffAfter.ProcessesNew
Write-Section 'C. Drivers that became Running' $diffAfter.DriversStarted

$anyFinding = ($persistentSvc.Count + $transientSvc.Count +
               $diffAfter.ProcessesNew.Count + $diffAfter.DriversStarted.Count) -gt 0

Write-Host "`n--------------------------------------------------------------" -ForegroundColor Cyan
if ($persistentSvc.Count -gt 0) {
    Write-Host "NEXT: test hypothesis A. From a fresh broken logon, run ONLY:" -ForegroundColor Green
    foreach ($s in $persistentSvc) {
        Write-Host "      Start-Service '$($s.Name)'   # $($s.DisplayName)" -ForegroundColor Green
    }
    Write-Host "      then check if Clarion caption drag / border resize work." -ForegroundColor Green
}
elseif (-not $anyFinding) {
    Write-Host "No service/process/driver changed. The trigger is most likely a" -ForegroundColor Magenta
    Write-Host "one-shot in-process API call (EnableMouseInPointer / DirectManipulation)." -ForegroundColor Magenta
    Write-Host "NEXT: run Process Monitor + API Monitor while launching mspaint" -ForegroundColor Magenta
    Write-Host "      (see tools\Capture-Modules.ps1 and the plan Phase 1)." -ForegroundColor Magenta
}
else {
    Write-Host "Review the candidates above; validate each in isolation (plan Phase 2)." -ForegroundColor Green
}
Write-Host "Raw snapshots saved under: $OutputDir" -ForegroundColor DarkGray
