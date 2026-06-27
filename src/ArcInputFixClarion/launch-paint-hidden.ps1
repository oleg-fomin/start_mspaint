<#
.SYNOPSIS
    64-bit helper for the (32-bit) Clarion ArcInputFix.exe. Launches Paint via its
    App Execution Alias using the Win32 CreateProcess API with STARTF_USESHOWWINDOW
    + SW_HIDE - i.e. genuinely hidden - exactly like the proven C++ ArcInputFix.exe.

.DESCRIPTION
    Clarion classic compiles 32-bit only. A 32-bit (WOW64) CreateProcess of the
    alias shows Paint but does NOT re-arm the Intel Arc non-client input path on
    the Dell; a NATIVE 64-bit CreateProcess does (confirmed: the 64-bit C++ exe
    fixes it, the 32-bit Clarion exe did not). cmd.exe cannot pass SW_HIDE to the
    child, so the launch flickered.

    This script is run by 64-bit Windows PowerShell (%WINDIR%\System32\
    WindowsPowerShell\v1.0\powershell.exe, reached from the 32-bit exe via
    %WINDIR%\Sysnative\...). It therefore provides the native 64-bit launch
    context AND can pass SW_HIDE through CreateProcess - giving the fix with no
    visible Paint window. The interop mirrors the proven start_mspaint.ps1.

    Sequence (faithful port of C++ LaunchPaintViaAlias):
      1. Snapshot existing Paint PIDs.
      2. CreateProcess(alias) hidden (STARTF_USESHOWWINDOW + SW_HIDE).
      3. Poll for new Paint PID(s); best-effort hide any window that does appear
         (a packaged app may ignore the hide hint).
      4. Dwell ~8s so Paint completes the session-wide init that re-arms the
         non-client input path.
      5. TerminateProcess every target.

    Exit code 0 = launched + handled; non-zero = failure (logged by the caller).
#>
param(
    [Parameter(Mandatory = $true)][string]$AliasPath
)

$ErrorActionPreference = 'Stop'

Add-Type -Namespace ArcFix -Name Native -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)]
public struct PROCESS_INFORMATION
{
    public IntPtr hProcess;
    public IntPtr hThread;
    public uint dwProcessId;
    public uint dwThreadId;
}

[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct STARTUPINFO
{
    public uint cb;
    public string lpReserved;
    public string lpDesktop;
    public string lpTitle;
    public uint dwX;
    public uint dwY;
    public uint dwXSize;
    public uint dwYSize;
    public uint dwXCountChars;
    public uint dwYCountChars;
    public uint dwFillAttribute;
    public uint dwFlags;
    public ushort wShowWindow;
    public ushort cbReserved2;
    public IntPtr lpReserved2;
    public IntPtr hStdInput;
    public IntPtr hStdOutput;
    public IntPtr hStdError;
}

[DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
public static extern bool CreateProcess(
    string lpApplicationName,
    string lpCommandLine,
    IntPtr lpProcessAttributes,
    IntPtr lpThreadAttributes,
    bool bInheritHandles,
    uint dwCreationFlags,
    IntPtr lpEnvironment,
    string lpCurrentDirectory,
    ref STARTUPINFO lpStartupInfo,
    out PROCESS_INFORMATION lpProcessInformation);

[DllImport("kernel32.dll", SetLastError = true)]
public static extern IntPtr OpenProcess(uint dwDesiredAccess, bool bInheritHandle, uint dwProcessId);

[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool TerminateProcess(IntPtr hProcess, uint uExitCode);

[DllImport("kernel32.dll", SetLastError = true)]
public static extern bool CloseHandle(IntPtr hObject);

public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

[DllImport("user32.dll")]
public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

[DllImport("user32.dll", SetLastError = true)]
public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

[DllImport("user32.dll")]
public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

[DllImport("user32.dll")]
public static extern bool IsWindowVisible(IntPtr hWnd);
'@

$STARTF_USESHOWWINDOW = 0x00000001
$SW_HIDE              = 0
$PROCESS_TERMINATE    = 0x0001
$paintNames          = @('mspaint', 'PaintApp', 'Paint')

function Get-PaintPids {
    Get-Process -ErrorAction SilentlyContinue |
        Where-Object { $paintNames -contains $_.Name } |
        Select-Object -ExpandProperty Id
}

# 1) Snapshot existing Paint PIDs so we can tell which are newly spawned.
$before = @(Get-PaintPids)

# 2) Launch the alias genuinely hidden (STARTF_USESHOWWINDOW + SW_HIDE), exactly
#    like the proven C++ exe. Guaranteed-valid working dir avoids ERROR_INVALID_NAME.
$si = New-Object ArcFix.Native+STARTUPINFO
$si.cb          = [System.Runtime.InteropServices.Marshal]::SizeOf($si)
$si.dwFlags     = $STARTF_USESHOWWINDOW
$si.wShowWindow = $SW_HIDE

$pi = New-Object ArcFix.Native+PROCESS_INFORMATION
$commandLine = '"' + $AliasPath + '"'

# Pass the resolved alias as lpApplicationName: relying on lpCommandLine alone for
# module resolution fails with ERROR_PATH_NOT_FOUND (3) for the reparse alias,
# whereas an explicit application name is used directly without a path search
# (same fix documented in start_mspaint.ps1). Fall back to $null for a bare name.
$appName = $null
if ($AliasPath -like '*\*') { $appName = $AliasPath }

$created = [ArcFix.Native]::CreateProcess(
    $appName, $commandLine, [IntPtr]::Zero, [IntPtr]::Zero, $false,
    0, [IntPtr]::Zero, $env:WINDIR, [ref]$si, [ref]$pi)

if (-not $created) {
    exit 2
}

$targets = New-Object System.Collections.Generic.List[uint32]
if ($pi.dwProcessId -ne 0) { [void]$targets.Add([uint32]$pi.dwProcessId) }

# 3) Poll for new Paint PID(s); best-effort hide any window that appears (a
#    packaged app may ignore the start-hidden hint).
$script:hidTargets = $targets
$callback = [ArcFix.Native+EnumWindowsProc] {
    param([IntPtr]$hWnd, [IntPtr]$lParam)
    [uint32]$winPid = 0
    [void][ArcFix.Native]::GetWindowThreadProcessId($hWnd, [ref]$winPid)
    if ($script:hidTargets.Contains($winPid) -and [ArcFix.Native]::IsWindowVisible($hWnd)) {
        [void][ArcFix.Native]::ShowWindow($hWnd, 0)   # SW_HIDE
        return $false
    }
    return $true
}

for ($i = 0; $i -lt 50; $i++) {                       # up to ~10s
    foreach ($p in @(Get-PaintPids)) {
        if ($before -notcontains $p -and -not $targets.Contains([uint32]$p)) {
            [void]$targets.Add([uint32]$p)
        }
    }
    [void][ArcFix.Native]::EnumWindows($callback, [IntPtr]::Zero)
    Start-Sleep -Milliseconds 200
}

# 4) Dwell so Paint completes the session-wide init that re-arms the input path.
Start-Sleep -Seconds 8

# 5) Terminate every target.
foreach ($t in $targets) {
    $h = [ArcFix.Native]::OpenProcess($PROCESS_TERMINATE, $false, [uint32]$t)
    if ($h -ne [IntPtr]::Zero) {
        [void][ArcFix.Native]::TerminateProcess($h, 0)
        [void][ArcFix.Native]::CloseHandle($h)
    }
}
if ($pi.hThread  -ne [IntPtr]::Zero) { [void][ArcFix.Native]::CloseHandle($pi.hThread) }
if ($pi.hProcess -ne [IntPtr]::Zero) { [void][ArcFix.Native]::CloseHandle($pi.hProcess) }

exit 0
