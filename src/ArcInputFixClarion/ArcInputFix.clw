  PROGRAM

! ArcInputFix (Clarion 11 port) - hidden logon utility to work around the Intel
! Arc (Core Ultra 7 268V / Lunar Lake) non-client-mouse bug on Windows 11, where
! Clarion MDI child windows stop responding to caption-drag / border-resize until
! some GUI app (e.g. mspaint) is run once per session.
!
! This is a GUI-subsystem exe (Clarion exes have no console). It launches Paint
! exactly the way typing "mspaint" in a prompt does - via its App Execution Alias
! - lets it reach its interactive state (it shows briefly so the WinUI3/CoreWindow
! input+composition stack initializes, then we hide it once its window appears),
! then terminates it. On the affected hardware that single launch re-arms the
! non-client input path for the session. The alias launch is the proven fix.
! IMPORTANT: Paint is NOT launched pre-hidden (no STARTF_USESHOWWINDOW/SW_HIDE) -
! that matches the proven C++ Round 8/9 path; a pre-hidden Paint may never spin up
! the input/composition stack that is the actual trigger.
!
! Faithful port of src/ArcInputFix/ArcInputFix.cpp. Scope per project decision:
! the App Execution Alias launch + classic mspaint.exe CreateProcess paths only.
! The IApplicationActivationManager (COM) packaged-Paint fallback is intentionally
! omitted - the alias path already launches packaged Paint on 25H2.
!
! Build: see build.cmd (Clarion 11, MSBuild via ClarionCL/SoftVelocity targets,
! Win32, Model=Dll - needs ClaRUN.dll beside the exe). 32-bit exe runs under WOW64.

  PRAGMA('link(WIN32.LIB)')                  ! Windows API import library

  MAP
    DoMspaintFallback(),BYTE
    LaunchPaintViaAlias(),BYTE
    SnapshotPaintPids()
    HideWindowsOfPid(ULONG pPid),BYTE
    FindAndHidePaintWnd(LONG hWnd, LONG lParam),LONG,PASCAL  ! EnumWindows callback
    PumpMessages(ULONG pMs)
    InBeforeQ(ULONG pPid),BYTE
    InTargetQ(ULONG pPid),BYTE
    LogEvent(USHORT pType, STRING pMessage)
    MODULE('WINAPI')
      w_GetEnvironmentVariable(*CSTRING lpName, *CSTRING lpBuffer, ULONG nSize),ULONG,RAW,PASCAL,PROC,NAME('GetEnvironmentVariableA')
      w_GetFileAttributes(*CSTRING lpFileName),LONG,RAW,PASCAL,PROC,NAME('GetFileAttributesA')
      w_GetSystemDirectory(*CSTRING lpBuffer, ULONG uSize),ULONG,RAW,PASCAL,PROC,NAME('GetSystemDirectoryA')
      w_GetModuleFileName(LONG hModule, *CSTRING lpFilename, ULONG nSize),ULONG,RAW,PASCAL,PROC,NAME('GetModuleFileNameA')
      w_CreateProcess(LONG lpApplicationName, *CSTRING lpCommandLine, LONG lpProcessAttributes, LONG lpThreadAttributes, SIGNED bInheritHandles, ULONG dwCreationFlags, LONG lpEnvironment, LONG lpCurrentDirectory, *GROUP lpStartupInfo, *GROUP lpProcessInformation),SIGNED,RAW,PASCAL,PROC,NAME('CreateProcessA')
      w_OpenProcess(ULONG dwDesiredAccess, SIGNED bInheritHandle, ULONG dwProcessId),LONG,PASCAL,PROC,NAME('OpenProcess')
      w_TerminateProcess(LONG hProcess, ULONG uExitCode),SIGNED,PASCAL,PROC,NAME('TerminateProcess')
      w_CloseHandle(LONG hObject),SIGNED,PASCAL,PROC,NAME('CloseHandle')
      w_WaitForSingleObject(LONG hHandle, ULONG dwMilliseconds),ULONG,PASCAL,PROC,NAME('WaitForSingleObject')
      w_GetExitCodeProcess(LONG hProcess, *ULONG lpExitCode),SIGNED,RAW,PASCAL,PROC,NAME('GetExitCodeProcess')
      w_GetLastError(),ULONG,PASCAL,PROC,NAME('GetLastError')
      w_GetTickCount(),ULONG,PASCAL,PROC,NAME('GetTickCount')
      w_Sleep(ULONG dwMilliseconds),PASCAL,NAME('Sleep')
      w_ExitProcess(ULONG uExitCode),PASCAL,NAME('ExitProcess')
      w_CreateToolhelp32Snapshot(ULONG dwFlags, ULONG th32ProcessID),LONG,PASCAL,PROC,NAME('CreateToolhelp32Snapshot')
      w_Process32First(LONG hSnapshot, *GROUP lppe),SIGNED,RAW,PASCAL,PROC,NAME('Process32First')
      w_Process32Next(LONG hSnapshot, *GROUP lppe),SIGNED,RAW,PASCAL,PROC,NAME('Process32Next')
      w_EnumWindows(LONG lpEnumFunc, LONG lParam),SIGNED,PASCAL,PROC,NAME('EnumWindows')
      w_GetWindowThreadProcessId(LONG hWnd, *ULONG lpdwProcessId),ULONG,RAW,PASCAL,PROC,NAME('GetWindowThreadProcessId')
      w_IsWindowVisible(LONG hWnd),SIGNED,PASCAL,PROC,NAME('IsWindowVisible')
      w_ShowWindow(LONG hWnd, SIGNED nCmdShow),SIGNED,PASCAL,PROC,NAME('ShowWindow')
      w_PeekMessage(*GROUP lpMsg, LONG hWnd, ULONG wMsgFilterMin, ULONG wMsgFilterMax, ULONG wRemoveMsg),SIGNED,RAW,PASCAL,PROC,NAME('PeekMessageA')
      w_TranslateMessage(*GROUP lpMsg),SIGNED,RAW,PASCAL,PROC,NAME('TranslateMessage')
      w_DispatchMessage(*GROUP lpMsg),LONG,RAW,PASCAL,PROC,NAME('DispatchMessageA')
      w_RegisterEventSource(LONG lpUNCServerName, *CSTRING lpSourceName),LONG,RAW,PASCAL,PROC,NAME('RegisterEventSourceA')
      w_ReportEvent(LONG hEventLog, USHORT wType, USHORT wCategory, ULONG dwEventID, LONG lpUserSid, USHORT wNumStrings, ULONG dwDataSize, LONG lpStrings, LONG lpRawData),SIGNED,PASCAL,PROC,NAME('ReportEventA')
      w_DeregisterEventSource(LONG hEventLog),SIGNED,PASCAL,PROC,NAME('DeregisterEventSource')
      w_OutputDebugString(*CSTRING lpOutputString),RAW,PASCAL,NAME('OutputDebugStringA')
    END
  END

! ---------------------------------------------------------------------------
! Win32 constants / equates
! ---------------------------------------------------------------------------
STARTF_USESHOWWINDOW      EQUATE(1)
SW_HIDE                   EQUATE(0)
PROCESS_TERMINATE         EQUATE(0001H)
TH32CS_SNAPPROCESS        EQUATE(0002H)
INVALID_HANDLE_VALUE      EQUATE(-1)
INVALID_FILE_ATTRIBUTES   EQUATE(-1)
PM_REMOVE                 EQUATE(1)
CREATE_NO_WINDOW          EQUATE(08000000H)
WAIT_TIMEOUT_MS           EQUATE(60000)
EVENTLOG_ERROR_TYPE       EQUATE(1)
EVENTLOG_WARNING_TYPE     EQUATE(2)
EVENTLOG_INFORMATION_TYPE EQUATE(4)

! ---------------------------------------------------------------------------
! Win32 structures (ANSI, 32-bit layout)
! ---------------------------------------------------------------------------
STARTUPINFO          GROUP,TYPE
cb                     ULONG
lpReserved             LONG
lpDesktop              LONG
lpTitle                LONG
dwX                    ULONG
dwY                    ULONG
dwXSize                ULONG
dwYSize                ULONG
dwXCountChars          ULONG
dwYCountChars          ULONG
dwFillAttribute        ULONG
dwFlags                ULONG
wShowWindow            USHORT
cbReserved2            USHORT
lpReserved2            LONG
hStdInput              LONG
hStdOutput             LONG
hStdError              LONG
                     END

PROCESS_INFORMATION  GROUP,TYPE
hProcess               LONG
hThread                LONG
dwProcessId            ULONG
dwThreadId             ULONG
                     END

PROCESSENTRY32       GROUP,TYPE
dwSize                 ULONG
cntUsage               ULONG
th32ProcessID          ULONG
th32DefaultHeapID      LONG
th32ModuleID           ULONG
cntThreads             ULONG
th32ParentProcessID    ULONG
pcPriClassBase         LONG
dwFlags                ULONG
szExeFile              CSTRING(260)
                     END

MSGTYPE              GROUP,TYPE
hwnd                   LONG
message                ULONG
wParam                 LONG
lParam                 LONG
time                   ULONG
pt_x                   LONG
pt_y                   LONG
                     END

! ---------------------------------------------------------------------------
! Module-global state
! ---------------------------------------------------------------------------
GsTargetPid          ULONG               ! PID the EnumWindows callback targets
GsHidden             BYTE                ! set by callback when a window is hidden

BeforeQ              QUEUE,PRE(BQ)        ! Paint PIDs already running before launch
Pid                    ULONG
                     END
TargetQ              QUEUE,PRE(TQ)        ! Paint PIDs we will hide + terminate
Pid                    ULONG
                     END
ScanQ                QUEUE,PRE(SQ)        ! scratch snapshot of current Paint PIDs
Pid                    ULONG
                     END

! ===========================================================================
! Entry point. Single purpose: run the proven alias launch of Paint.
! ===========================================================================
  CODE
  IF DoMspaintFallback()
    LogEvent(EVENTLOG_INFORMATION_TYPE, 'ArcInputFix mspaint succeeded')
    w_ExitProcess(0)
  ELSE
    LogEvent(EVENTLOG_WARNING_TYPE, 'ArcInputFix mspaint did not complete')
    w_ExitProcess(1)
  END

! ===========================================================================
! Logging - one line to the Windows Application event log (source ArcInputFix),
! so fleet machines are diagnosable without a console.
! ===========================================================================
LogEvent             PROCEDURE(USHORT pType, STRING pMessage)
Src                    LONG
SrcName                CSTRING(32)
MsgC                   CSTRING(512)
DbgC                   CSTRING(540)
StrPtrs                LONG,DIM(1)
  CODE
  SrcName = 'ArcInputFix'
  MsgC = CLIP(pMessage)
  Src = w_RegisterEventSource(0, SrcName)
  IF Src
    StrPtrs[1] = ADDRESS(MsgC)
    w_ReportEvent(Src, pType, 0, 0, 0, 1, 0, ADDRESS(StrPtrs), 0)
    w_DeregisterEventSource(Src)
  END
  DbgC = '[ArcInputFix] ' & CLIP(MsgC) & '<13,10>'
  w_OutputDebugString(DbgC)

! ===========================================================================
! Pump the message queue for pMs milliseconds (an STA-style pump while Paint
! initializes and before terminating it).
! ===========================================================================
PumpMessages         PROCEDURE(ULONG pMs)
StartTick              ULONG
MsgBuf                 LIKE(MSGTYPE)
  CODE
  StartTick = w_GetTickCount()
  LOOP WHILE (w_GetTickCount() - StartTick) < pMs
    LOOP WHILE w_PeekMessage(MsgBuf, 0, 0, 0, PM_REMOVE)
      w_TranslateMessage(MsgBuf)
      w_DispatchMessage(MsgBuf)
    END
    w_Sleep(10)
  END

! ===========================================================================
! EnumWindows callback: hide the first visible top-level window of GsTargetPid.
! Uses module-global state (GsTargetPid / GsHidden) instead of an lParam struct.
! ===========================================================================
FindAndHidePaintWnd  PROCEDURE(LONG hWnd, LONG lParam)
WPid                   ULONG
  CODE
  w_GetWindowThreadProcessId(hWnd, WPid)
  IF WPid = GsTargetPid AND w_IsWindowVisible(hWnd)
    w_ShowWindow(hWnd, SW_HIDE)              ! best-effort hide as start_mspaint.ps1
    GsHidden = 1
    RETURN(0)                                ! stop enumerating
  END
  RETURN(1)                                  ! continue

HideWindowsOfPid     PROCEDURE(ULONG pPid)
  CODE
  GsTargetPid = pPid
  GsHidden = 0
  w_EnumWindows(ADDRESS(FindAndHidePaintWnd), 0)
  RETURN(GsHidden)

! ===========================================================================
! Fill ScanQ with PIDs of all processes whose image name is one Paint may run
! under (mspaint.exe / PaintApp.exe / Paint.exe), case-insensitive.
! ===========================================================================
SnapshotPaintPids    PROCEDURE()
Snap                   LONG
PE                     LIKE(PROCESSENTRY32)
NameU                  CSTRING(261)
  CODE
  FREE(ScanQ)
  Snap = w_CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0)
  IF Snap = INVALID_HANDLE_VALUE THEN RETURN.
  PE.dwSize = SIZE(PE)
  IF w_Process32First(Snap, PE)
    LOOP
      NameU = UPPER(PE.szExeFile)
      IF NameU = 'MSPAINT.EXE' OR NameU = 'PAINTAPP.EXE' OR NameU = 'PAINT.EXE'
        SQ:Pid = PE.th32ProcessID
        ADD(ScanQ)
      END
      IF NOT w_Process32Next(Snap, PE) THEN BREAK.
    END
  END
  w_CloseHandle(Snap)

InBeforeQ            PROCEDURE(ULONG pPid)
K                      LONG
  CODE
  LOOP K = 1 TO RECORDS(BeforeQ)
    GET(BeforeQ, K)
    IF BQ:Pid = pPid THEN RETURN(1).
  END
  RETURN(0)

InTargetQ           PROCEDURE(ULONG pPid)
K                      LONG
  CODE
  LOOP K = 1 TO RECORDS(TargetQ)
    GET(TargetQ, K)
    IF TQ:Pid = pPid THEN RETURN(1).
  END
  RETURN(0)

! ===========================================================================
! PRIMARY: launch Paint via its App Execution Alias - exactly what typing
! "mspaint" in a prompt does. Resolve the alias path under
! %LOCALAPPDATA%\Microsoft\WindowsApps, else fall back to a bare PATH search.
! Snapshot existing Paint PIDs, launch hidden, find the real Paint PID(s), hide
! their windows, dwell (pumping), then terminate.
! ===========================================================================
LaunchPaintViaAlias  PROCEDURE()
EnvName                CSTRING(20)
WinDir                 CSTRING(261)
Ps64                   CSTRING(360)
ExeFull                CSTRING(320)
ExeDir                 CSTRING(320)
HelperPath             CSTRING(380)
CmdLine                CSTRING(800)
SysDir                 CSTRING(261)
N                      ULONG
K                      LONG
SI                     LIKE(STARTUPINFO)
PI                     LIKE(PROCESS_INFORMATION)
ExitCode               ULONG
WaitRes                ULONG
  CODE
  ! Clarion classic is 32-bit; a 32-bit (WOW64) CreateProcess of the alias shows
  ! Paint but does NOT re-arm the input path on the Dell, and cmd.exe cannot pass
  ! SW_HIDE to the child (so it flickered). Delegate the launch to 64-bit Windows
  ! PowerShell running launch-paint-hidden.ps1, which does the IDENTICAL Win32
  ! CreateProcess(alias) with STARTF_USESHOWWINDOW + SW_HIDE as the proven C++ exe:
  ! native 64-bit context (the fix) AND genuinely hidden (no flicker). The helper
  ! resolves the alias path itself, so it also runs standalone (e.g. as a logon task).

  ! 64-bit PowerShell as seen from this 32-bit process (Sysnative -> real System32).
  EnvName = 'windir'
  N = w_GetEnvironmentVariable(EnvName, WinDir, SIZE(WinDir))
  IF N = 0 OR N >= SIZE(WinDir)
    LogEvent(EVENTLOG_ERROR_TYPE, 'ArcInputFix: cannot resolve %windir%')
    RETURN(0)
  END
  Ps64 = CLIP(WinDir) & '\Sysnative\WindowsPowerShell\v1.0\powershell.exe'
  IF w_GetFileAttributes(Ps64) = INVALID_FILE_ATTRIBUTES
    Ps64 = CLIP(WinDir) & '\System32\WindowsPowerShell\v1.0\powershell.exe'
    IF w_GetFileAttributes(Ps64) = INVALID_FILE_ATTRIBUTES
      Ps64 = 'powershell.exe'
    END
  END

  ! Locate launch-paint-hidden.ps1 next to this exe.
  ExeFull = ''
  N = w_GetModuleFileName(0, ExeFull, SIZE(ExeFull))
  ExeDir = ''
  LOOP K = LEN(CLIP(ExeFull)) TO 1 BY -1
    IF SUB(ExeFull, K, 1) = '\'
      ExeDir = SUB(ExeFull, 1, K)
      BREAK
    END
  END
  HelperPath = CLIP(ExeDir) & 'launch-paint-hidden.ps1'
  IF w_GetFileAttributes(HelperPath) = INVALID_FILE_ATTRIBUTES
    LogEvent(EVENTLOG_ERROR_TYPE, 'ArcInputFix: helper not found: ' & CLIP(HelperPath))
    RETURN(0)
  END

  ! Guaranteed-valid working dir to avoid ERROR_INVALID_NAME (123).
  IF NOT w_GetSystemDirectory(SysDir, SIZE(SysDir)) THEN SysDir = ''.

  CmdLine = '"' & CLIP(Ps64) & '" -NoProfile -ExecutionPolicy Bypass -NonInteractive' |
          & ' -WindowStyle Hidden -File "' & CLIP(HelperPath) & '"'

  ! Run the helper hidden + windowless; wait for it to finish the launch + dwell.
  CLEAR(SI)
  SI.cb = SIZE(SI)
  SI.dwFlags = STARTF_USESHOWWINDOW
  SI.wShowWindow = SW_HIDE
  CLEAR(PI)
  IF NOT w_CreateProcess(0, CmdLine, 0, 0, 0, CREATE_NO_WINDOW, 0, |
        CHOOSE(SysDir <> '', ADDRESS(SysDir), 0), SI, PI)
    LogEvent(EVENTLOG_ERROR_TYPE, 'CreateProcess(powershell helper) failed: ' & w_GetLastError())
    RETURN(0)
  END

  WaitRes = w_WaitForSingleObject(PI.hProcess, WAIT_TIMEOUT_MS)
  ExitCode = 1
  w_GetExitCodeProcess(PI.hProcess, ExitCode)
  IF PI.hThread  THEN w_CloseHandle(PI.hThread).
  IF PI.hProcess THEN w_CloseHandle(PI.hProcess).

  ! Diagnostic so a single Dell logon test is conclusive.
  LogEvent(EVENTLOG_INFORMATION_TYPE, 'alias launch: via=ps64 helper=' & CLIP(HelperPath) & |
        ' helperExit=' & ExitCode & ' wait=' & WaitRes)

  RETURN(CHOOSE(ExitCode = 0, 1, 0))

! ===========================================================================
! Orchestration: alias launch first (the proven fix); then classic desktop
! Paint if it actually exists in System32. (COM packaged-Paint path omitted.)
! ===========================================================================
DoMspaintFallback    PROCEDURE()
SysDir                 CSTRING(261)
ExePath                CSTRING(320)
CmdLine                CSTRING(340)
SI                     LIKE(STARTUPINFO)
PI                     LIKE(PROCESS_INFORMATION)
  CODE
  ! PRIMARY: the App Execution Alias launch (what typing "mspaint" does).
  IF LaunchPaintViaAlias() THEN RETURN(1).

  ! Next: classic desktop Paint if it actually exists in System32.
  IF w_GetSystemDirectory(SysDir, SIZE(SysDir))
    ExePath = CLIP(SysDir) & '\mspaint.exe'
    IF w_GetFileAttributes(ExePath) <> INVALID_FILE_ATTRIBUTES
      CLEAR(SI)
      SI.cb = SIZE(SI)
      SI.dwFlags = STARTF_USESHOWWINDOW
      SI.wShowWindow = SW_HIDE
      CLEAR(PI)
      CmdLine = '"' & CLIP(ExePath) & '"'
      IF w_CreateProcess(ADDRESS(ExePath), CmdLine, 0, 0, 0, CREATE_NO_WINDOW, 0, |
            ADDRESS(SysDir), SI, PI)
        w_Sleep(5000)
        w_TerminateProcess(PI.hProcess, 0)
        w_CloseHandle(PI.hThread)
        w_CloseHandle(PI.hProcess)
        RETURN(1)
      END
      LogEvent(EVENTLOG_ERROR_TYPE, 'CreateProcess(mspaint) failed: ' & w_GetLastError())
    END
  END

  RETURN(0)
