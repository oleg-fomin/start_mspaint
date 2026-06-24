<#
.SYNOPSIS
    Phase 1 deep capture for when Invoke-FixDiff.ps1 finds NO service/process/
    driver change - i.e. the fix is a one-shot in-process API call.

.DESCRIPTION
    Run on an AFFECTED 268V laptop from a fresh broken logon. This captures the
    DLLs mspaint loads while it runs, which narrows the trigger to a specific
    input/graphics subsystem. The DLLs that matter for the non-client mouse /
    pointer path include:

        ninput.dll                 - Direct Manipulation / pointer input
        directmanipulation.dll     - DirectManipulationManager (COM)
        InputHost.dll / CoreMessaging.dll - modern input stack
        twinapi*.dll               - WinRT/touch interop
        d2d1.dll / dwrite.dll / dcomp.dll - Direct2D + composition warm-up
        textinputframework.dll     - text/pointer input framework

    It also (optionally) drives Process Monitor if Procmon64.exe is on PATH or in
    .\tools, capturing a focused log around the mspaint launch for offline review
    of registry/file/handle activity (the authoritative source for one-shot
    triggers).

.PARAMETER RunSeconds
    Seconds to let mspaint run before sampling its modules. Default 5.

.PARAMETER OutputDir
    Where to write results. Default: .\fixdiff-out

.PARAMETER ProcmonPath
    Optional explicit path to Procmon(64).exe. Only used with -WithProcmon.

.PARAMETER WithProcmon
    Off by default. When set, runs a SHORT, time-boxed Process Monitor capture
    (non-blocking) around the mspaint launch. Without it, the script only grabs
    the module + child-process lists (fast, tiny output).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tools\Capture-Modules.ps1
#>
[CmdletBinding()]
param(
    [int]    $RunSeconds  = 5,
    [string] $OutputDir,
    [string] $ProcmonPath,
    [switch] $WithProcmon
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot can be empty depending on how the script is invoked; resolve the
# script directory robustly and use it for defaults / local Procmon lookup.
$scriptDir = if ($PSScriptRoot) { $PSScriptRoot }
             elseif ($PSCommandPath) { Split-Path -Parent $PSCommandPath }
             elseif ($MyInvocation.MyCommand.Path) { Split-Path -Parent $MyInvocation.MyCommand.Path }
             else { (Get-Location).Path }

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $OutputDir = Join-Path $scriptDir 'fixdiff-out'
}

if (-not (Test-Path -LiteralPath $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir | Out-Null
}

# DLLs whose presence points at a specific replicable trigger.
$ofInterest = @(
    'ninput.dll', 'directmanipulation.dll', 'inputhost.dll', 'coremessaging.dll',
    'textinputframework.dll', 'twinapi.dll', 'twinapi.appcore.dll',
    'd2d1.dll', 'dwrite.dll', 'dcomp.dll', 'windows.ui.dll', 'uiautomationcore.dll'
)

function Resolve-Procmon {
    param([string]$Explicit)
    if ($Explicit -and (Test-Path -LiteralPath $Explicit)) { return $Explicit }
    foreach ($name in 'Procmon64.exe', 'Procmon.exe') {
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
        $local = Join-Path $scriptDir $name
        if (Test-Path -LiteralPath $local) { return $local }
    }
    return $null
}

# ---------------------------------------------------------------------------
# Optional: start Process Monitor capturing to a PML (opt-in, non-blocking).
# IMPORTANT: launch Procmon WITHOUT waiting on it - while capturing it never
# exits, so piping/`Wait` would hang the script and let the backing file grow
# without bound. We start it detached and stop it later with /Terminate.
# ---------------------------------------------------------------------------
$pmlPath = Join-Path $OutputDir 'mspaint-capture.pml'
$procmon = $null

if ($WithProcmon) {
    $procmon = Resolve-Procmon -Explicit $ProcmonPath
    if ($procmon) {
        Write-Host "[procmon] starting time-boxed capture (non-blocking) -> $pmlPath" -ForegroundColor DarkGray
        Start-Process -FilePath $procmon `
            -ArgumentList '/AcceptEula', '/Quiet', '/Minimized', '/BackingFile', $pmlPath |
            Out-Null
        Start-Sleep -Seconds 1
    } else {
        Write-Host "[procmon] -WithProcmon set but Procmon not found; skipping." -ForegroundColor DarkYellow
        Write-Host "          Put Procmon64.exe on PATH or in .\tools." -ForegroundColor DarkYellow
    }
} else {
    Write-Host "[procmon] disabled (default). Add -WithProcmon for a registry/handle trace." -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# Launch mspaint, sample its modules while running.
# ---------------------------------------------------------------------------
$classic = Join-Path $env:WINDIR 'System32\mspaint.exe'
$proc = $null

if (Test-Path -LiteralPath $classic) {
    $proc = Start-Process -FilePath $classic -WindowStyle Hidden -PassThru
} else {
    Write-Host "[launch] classic mspaint not present; launching packaged Paint." -ForegroundColor DarkGray
    Start-Process 'ms-paint:' -ErrorAction Stop
    Start-Sleep -Seconds 2
    $proc = Get-Process -Name 'mspaint', 'PaintStudio.View' -ErrorAction SilentlyContinue |
            Select-Object -First 1
}

if (-not $proc) { throw 'Could not obtain the Paint process.' }

Start-Sleep -Seconds $RunSeconds

$modules = @()
try {
    $modules = ($proc | Get-Process -ErrorAction Stop).Modules |
        Select-Object ModuleName, FileName
} catch {
    Write-Warning "Could not enumerate modules via Get-Process: $($_.Exception.Message)"
}

# Packaged apps frequently deny cross-identity module enumeration. Fall back to
# 'tasklist /m' (works elevated) so we still see the loaded DLLs.
if (-not $modules -or $modules.Count -eq 0) {
    Write-Host "[modules] falling back to tasklist /m ..." -ForegroundColor DarkYellow
    try {
        $raw = & tasklist /m /fi "PID eq $($proc.Id)" 2>$null
        $modNames = $raw |
            Where-Object { $_ -match '\.dll' } |
            ForEach-Object { ($_ -split '\s{2,}')[-1] } |
            ForEach-Object { $_ -split ',\s*' } |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -match '\.dll$' }
        $modules = $modNames | Sort-Object -Unique |
            ForEach-Object { [pscustomobject]@{ ModuleName = $_; FileName = '' } }
    } catch {
        Write-Warning "tasklist fallback failed: $($_.Exception.Message)"
    }
}

# Also record child processes (e.g. ApplicationFrameHost, TextInputHost) that a
# packaged app spins up - any of these could host the real trigger.
$children = Get-CimInstance Win32_Process -Filter "ParentProcessId = $($proc.Id)" -ErrorAction SilentlyContinue |
    Select-Object ProcessId, Name, CommandLine
$children | Export-Csv (Join-Path $OutputDir 'mspaint-children.csv') -NoTypeInformation

$modules | Sort-Object ModuleName |
    Export-Csv (Join-Path $OutputDir 'mspaint-modules.csv') -NoTypeInformation

$hits = $modules | Where-Object { $ofInterest -contains $_.ModuleName.ToLower() }

# ---------------------------------------------------------------------------
# Stop everything.
# ---------------------------------------------------------------------------
$proc | Stop-Process -Force -ErrorAction SilentlyContinue

if ($procmon) {
    Write-Host "[procmon] terminating capture..." -ForegroundColor DarkGray
    Start-Process -FilePath $procmon -ArgumentList '/Terminate' -Wait | Out-Null
}

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
Write-Host "`n=== Input/graphics DLLs loaded by mspaint ===" -ForegroundColor Yellow
if ($hits.Count -gt 0) {
    $hits | Sort-Object ModuleName | Format-Table -AutoSize | Out-String | Write-Host
    Write-Host "Interpretation:" -ForegroundColor Green
    Write-Host "  ninput.dll / directmanipulation.dll => try DirectManipulationManager"  -ForegroundColor Green
    Write-Host "      CoCreateInstance warm-up in the utility." -ForegroundColor Green
    Write-Host "  inputhost/coremessaging/textinputframework => try EnableMouseInPointer" -ForegroundColor Green
    Write-Host "      + a message-only window pump in the utility." -ForegroundColor Green
} else {
    Write-Host "  (none of the watched DLLs were loaded)" -ForegroundColor DarkGray
}

Write-Host "`nArtifacts in $OutputDir :" -ForegroundColor Cyan
Write-Host "  mspaint-modules.csv   - full module list" -ForegroundColor DarkGray
if ($procmon) {
    Write-Host "  mspaint-capture.pml   - open in Process Monitor; filter Process Name" -ForegroundColor DarkGray
    Write-Host "                          is mspaint.exe, then review RegSetValue, " -ForegroundColor DarkGray
    Write-Host "                          CreateFile on \Device\ / \\.\, and Load Image." -ForegroundColor DarkGray
}
