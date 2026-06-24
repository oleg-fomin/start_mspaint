<#
.SYNOPSIS
    Starts Microsoft Paint with a hidden window, waits 60 seconds, then closes
    it using the process handle returned by the launch call.

.DESCRIPTION
    Two launch paths are supported:

    1. Classic desktop Paint (%WINDIR%\System32\mspaint.exe), if present.
       It is launched with the Win32 CreateProcess API using STARTUPINFO with
       STARTF_USESHOWWINDOW + SW_HIDE so the window is genuinely created hidden.
       The returned PROCESS_INFORMATION.hProcess handle is later used to
       terminate the process.

    2. Modern packaged Paint (MSIX app, e.g. on Windows 11). Packaged-app
       executables CANNOT be launched with raw CreateProcess - doing so fails
       with ERROR_INVALID_NAME (123) because they must run inside their package
       activation context. The documented "CreateProcess equivalent" for a
       packaged app is the IApplicationActivationManager::ActivateApplication
       COM API, which returns the new process id. We then OpenProcess to obtain
       a real process handle, hide the app window on a best-effort basis (a
       packaged app cannot be told to start hidden), wait, and TerminateProcess
       via the handle.
#>

# ---------------------------------------------------------------------------
# Win32 interop (CreateProcess / OpenProcess / TerminateProcess / CloseHandle /
# window hiding helpers).
# ---------------------------------------------------------------------------
Add-Type -Namespace Win32 -Name NativeMethods -MemberDefinition @"
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
"@

# ---------------------------------------------------------------------------
# COM interop for launching packaged (MSIX/UWP) apps.
# ---------------------------------------------------------------------------
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public enum ActivateOptions
{
    None          = 0x00000000,
    DesignMode    = 0x00000001,
    NoErrorUI     = 0x00000002,
    NoSplashScreen= 0x00000004
}

[ComImport, Guid("2e941141-7f97-4756-ba1d-9decde894a3d"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
public interface IApplicationActivationManager
{
    [PreserveSig]
    int ActivateApplication(
        [In, MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
        [In, MarshalAs(UnmanagedType.LPWStr)] string arguments,
        [In] ActivateOptions options,
        [Out] out uint processId);

    [PreserveSig]
    int ActivateForFile(
        [In, MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
        [In] IntPtr itemArray,
        [In, MarshalAs(UnmanagedType.LPWStr)] string verb,
        [Out] out uint processId);

    [PreserveSig]
    int ActivateForProtocol(
        [In, MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
        [In] IntPtr itemArray,
        [Out] out uint processId);
}

public static class PackagedAppLauncher
{
    // Activate a packaged app by its AppUserModelId and return the new process
    // id. The whole COM call is done in C# because PowerShell cannot bind
    // methods on an IUnknown-only __ComObject.
    public static uint Activate(string appUserModelId, string arguments)
    {
        Type t = Type.GetTypeFromCLSID(new Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C"));
        IApplicationActivationManager mgr = (IApplicationActivationManager)Activator.CreateInstance(t);
        uint processId;
        int hr = mgr.ActivateApplication(appUserModelId, arguments, ActivateOptions.NoErrorUI, out processId);
        if (hr < 0)
        {
            throw new System.ComponentModel.Win32Exception(
                hr, "ActivateApplication failed (HRESULT 0x" + hr.ToString("X8") + ").");
        }
        return processId;
    }
}
"@

# Win32 / API constants.
$STARTF_USESHOWWINDOW                = 0x00000001
$SW_HIDE                             = 0
$CREATE_NO_WINDOW                    = 0x08000000
$PROCESS_TERMINATE                   = 0x0001
$PROCESS_QUERY_LIMITED_INFORMATION   = 0x1000
$SYNCHRONIZE                         = 0x00100000
$processAccess = $PROCESS_TERMINATE -bor $PROCESS_QUERY_LIMITED_INFORMATION -bor $SYNCHRONIZE

# These two are populated by whichever launch path runs; cleanup uses them.
$hProcess  = [IntPtr]::Zero   # process handle we will terminate / close
$hThread   = [IntPtr]::Zero   # only set by the CreateProcess path
$targetPid = 0

$mspaintClassic = Join-Path $env:WINDIR 'System32\mspaint.exe'

if (Test-Path -LiteralPath $mspaintClassic) {
    # -------------------------------------------------------------------
    # Path 1: classic desktop Paint via CreateProcess (truly hidden).
    # -------------------------------------------------------------------
    # Write-Host "Starting classic mspaint.exe (hidden) via CreateProcess..."

    $startupInfo = New-Object Win32.NativeMethods+STARTUPINFO
    $startupInfo.cb = [System.Runtime.InteropServices.Marshal]::SizeOf($startupInfo)
    $startupInfo.dwFlags = $STARTF_USESHOWWINDOW
    $startupInfo.wShowWindow = $SW_HIDE

    $processInfo = New-Object Win32.NativeMethods+PROCESS_INFORMATION
    $commandLine = '"' + $mspaintClassic + '"'

    # CreateProcess inherits the caller's current directory when
    # lpCurrentDirectory is NULL. If that directory is invalid for the Win32
    # API (which can happen for the host process), CreateProcess fails with
    # ERROR_INVALID_NAME (123) even though the executable path is correct.
    # Pass an explicit, guaranteed-valid working directory to avoid this.
    # Also pass the executable explicitly as lpApplicationName: relying on
    # lpCommandLine alone for module resolution fails with ERROR_PATH_NOT_FOUND
    # (3) in some environments, whereas an explicit application name is used
    # directly without a search.
    $mspaintDir = Split-Path -Parent $mspaintClassic

    $created = [Win32.NativeMethods]::CreateProcess(
        $mspaintClassic,       # lpApplicationName
        $commandLine,          # lpCommandLine
        [IntPtr]::Zero,        # lpProcessAttributes
        [IntPtr]::Zero,        # lpThreadAttributes
        $false,                # bInheritHandles
        $CREATE_NO_WINDOW,     # dwCreationFlags
        [IntPtr]::Zero,        # lpEnvironment
        $mspaintDir,           # lpCurrentDirectory
        [ref]$startupInfo,     # lpStartupInfo
        [ref]$processInfo)     # lpProcessInformation

    if (-not $created) {
        $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "CreateProcess failed with Win32 error code $err."
    }

    $hProcess  = $processInfo.hProcess
    $hThread   = $processInfo.hThread
    $targetPid = $processInfo.dwProcessId
}
else {
    # -------------------------------------------------------------------
    # Path 2: modern packaged Paint via IApplicationActivationManager.
    # Raw CreateProcess cannot launch packaged apps (ERROR_INVALID_NAME / 123).
    # -------------------------------------------------------------------
    $appUserModelId = 'Microsoft.Paint_8wekyb3d8bbwe!App'
    # Write-Host "Classic mspaint.exe not found; activating packaged Paint ($appUserModelId)..."

    [uint32]$activatedPid = [PackagedAppLauncher]::Activate($appUserModelId, $null)
    $targetPid = [int]$activatedPid

    # Obtain a real process handle from the returned PID (the "CreateProcess
    # equivalent" gives us a PID; OpenProcess turns it into a usable handle).
    $hProcess = [Win32.NativeMethods]::OpenProcess($processAccess, $false, $activatedPid)
    if ($hProcess -eq [IntPtr]::Zero) {
        $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "OpenProcess failed for PID $targetPid with Win32 error code $err."
    }

    # Best-effort hide: a packaged app cannot be told to start hidden, so poll
    # briefly for its top-level window and hide it.
    $script:hidePid = $activatedPid
    $script:windowHidden = $false
    $callback = [Win32.NativeMethods+EnumWindowsProc]{
        param([IntPtr]$hWnd, [IntPtr]$lParam)
        [uint32]$winPid = 0
        [void][Win32.NativeMethods]::GetWindowThreadProcessId($hWnd, [ref]$winPid)
        if ($winPid -eq $script:hidePid -and [Win32.NativeMethods]::IsWindowVisible($hWnd)) {
            [void][Win32.NativeMethods]::ShowWindow($hWnd, $SW_HIDE)
            $script:windowHidden = $true
            return $false  # stop enumerating windows
        } else {
            return $true   # continue enumerating windows
        }
    }

    # We loop a few times because the app may not have created its window yet.
    for ($i = 0; $i -lt 25; $i++) {
        # Enumerate all top-level windows and call the callback for each. The callback will hide the window if it belongs to the target PID.
        [void][Win32.NativeMethods]::EnumWindows($callback, [IntPtr]::Zero)
        if ($script:windowHidden) {
            break
        }
        Start-Sleep -Milliseconds 200
    }
}

# Write-Host "Paint started. PID = $targetPid. Waiting 60 seconds..."

# Wait 5 seconds while the Paint process runs.
Start-Sleep -Seconds 5

# Write-Host "Closing Paint using the process handle..."

# Terminate the process via its handle.
$terminated = [Win32.NativeMethods]::TerminateProcess($hProcess, 0)
if (-not $terminated) {
    $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    Write-Warning "TerminateProcess failed with Win32 error code $err."
}
else {
    # Write-Host "Paint terminated successfully."
}

# Always release the handles we hold to avoid leaks.
if ($hThread -ne [IntPtr]::Zero) {
    [void][Win32.NativeMethods]::CloseHandle($hThread)
}
if ($hProcess -ne [IntPtr]::Zero) {
    [void][Win32.NativeMethods]::CloseHandle($hProcess)
}
