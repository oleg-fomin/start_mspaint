# Plan: Logon utility to fix Intel Arc NC-mouse bug

> **Status:** shipped alias fix — see [docs/handoff-visual-studio.md](docs/handoff-visual-studio.md).

## Context
- Hardware: Dell Pro Plus, Core Ultra 7 268V (Lunar Lake), Intel Arc 140V iGPU, Windows 11.
- Symptom: Clarion MDI child windows only respond to mouse in the CLIENT area.
  Caption drag + border resize (NON-CLIENT area) dead until mspaint.exe is run once.
  Fix persists for the whole logon session.
- Existing workaround: start_mspaint.ps1 launches mspaint hidden (CreateProcess
  SW_HIDE or packaged-app activation), waits 5s, TerminateProcess. Works but
  depends on mspaint and a 5s PowerShell run.
- User decisions:
  - Approach = investigate EXACT root-cause trigger, replicate only that (no mspaint dep).
  - Deployment = Task Scheduler 'At log on' (hidden).
  - Language = recommend best -> native C++ Win32 GUI-subsystem exe, /MT static CRT.
  - Target = fleet of Dell Pro Plus 268V laptops.

## Root-cause hypotheses (broken NC hit-test / system move-size input path)
A) Demand-start service not started at logon (e.g. TabletInputService,
   TextInputManagementService) -> utility just StartService.
B) Specific input API not called: EnableMouseInPointer / RegisterPointerDeviceNotifications /
   DirectManipulation CoCreateInstance(CLSID_DirectManipulationManager) -> utility calls it.
C) Device/DWM handle must be opened (CreateFile \\.\... or DwmFlush/DwmEnableComposition warm-up).
Most likely (A) or (B); both are trivially replicable.

## Two realistic paths forward
* PATH 1 (identify exact trigger): run Capture-Modules.ps1 (default, NO procmon) on Dell ->
  send mspaint-modules.csv + mspaint-children.csv. Look for InputHost/CoreMessaging/
  textinputframework/twinapi/Windows.UI. Then replicate via a CoreWindow/UWP-style helper.
* PATH 2 (pragmatic ship): exact minimal replication may need a packaged/CoreWindow app, which
  is heavy. The PROVEN fix = launch a packaged app briefly. Ship --mspaint (or a tiny owned
  packaged helper) as the logon utility. Robustness risk: depends on Paint being installed;
  consider our own minimal packaged CoreWindow helper instead.

## Phases

### Phase 0 - Baseline & deterministic repro (on affected hardware)
- Confirm repro: fresh logon, open Clarion app, verify caption/border dead.
- Confirm mspaint fixes it; confirm it stays fixed until logoff.
- Record exact mspaint variant present: %WINDIR%\System32\mspaint.exe (classic)
  vs packaged Microsoft.Paint. (start_mspaint.ps1 already branches on this.)

### Phase 1 - Instrument mspaint to isolate the trigger (parallel captures)
Run all three while launching mspaint from broken state:
1. Sysinternals Process Monitor (Procmon): capture Process/Thread/Registry/File.
   Look for: services started, child procs (TextInputHost, ctfmon, RuntimeBroker),
   device opens (\Device\, \\.\), registry writes.
2. Service-state diff: Get-Service before vs after mspaint -> any Stopped->Running.
   (If found, this is hypothesis A; the fix may be StartService only.)
3. API trace: API Monitor or WinDbg/ETW on mspaint. Watch for EnableMouseInPointer,
   RegisterPointerDeviceNotifications, RegisterPointerInputTarget,
   CoCreateInstance(DirectManipulationManager), Dwm* warm-up calls, LoadLibrary of
   ninput.dll/InputHost.dll/directmanipulation.dll/twinapi.
4. Module diff: Process Explorer/listdlls snapshot for confirmation.

Deliverable: ONE concrete trigger (service name OR API call OR handle/device).

### Phase 2 - Validate minimal repro of the fix
- From broken state, perform ONLY the suspected trigger via a throwaway test
  (PowerShell StartService, or a 10-line C++ test calling the suspected API).
- Confirm caption drag + border resize start working WITHOUT launching mspaint.
- Confirm persistence to logoff. If it fails, return to Phase 1 next hypothesis.

### Phase 3 - Build the native utility (ArcInputFix)
- New folder: src/ArcInputFix/ (separate from the PS workaround, which stays as fallback).
- C++ Win32 GUI-subsystem exe (/SUBSYSTEM:WINDOWS, /MT static CRT, x64).
- WinMain only: no window, no message loop unless the API requires an STA +
  message pump (DirectManipulation does -> create hidden message-only window
  HWND_MESSAGE + CoInitialize(STA) if hypothesis B/DM).
- Body = the single validated trigger from Phase 2:
  - Hyp A: OpenSCManager/OpenService/StartService(+wait running)/Close.
  - Hyp B: CoInitializeEx STA -> CoCreateInstance(DM) / EnableMouseInPointer(TRUE)
           / RegisterPointerDeviceNotifications, hold briefly, release.
  - Hyp C: CreateFile the device / Dwm warm-up, hold briefly, CloseHandle.
- Exit 0 on success, non-zero on failure; write a single line to Windows Event Log
  (RegisterEventSource) for fleet diagnosability. Keep it idempotent + fast (<1s).
- Build via MSVC (cl.exe / Developer cmd) or a minimal MSBuild .vcxproj; produce
  signed x64 exe.

### Phase 4 - Logon deployment via Task Scheduler
- Scheduled task XML: trigger = At log on (all users), RunLevel depends on trigger:
  - Service start (Hyp A) often needs elevation -> Highest privileges (SYSTEM or admin).
  - Per-user input API (Hyp B) -> run as the logged-on user, interactive token.
- Hidden=true, ExecutionTimeLimit short, no console (exe is windowless anyway).
- Provide schtasks /create /xml import OR Register-ScheduledTask PowerShell.

### Phase 5 - Fleet rollout & verification
- Code-sign exe (fleet trust). Package: exe + task XML + install script.
- Distribute via Intune / SCCM / GPO startup or logon script.
- Pilot on a few 268V units, then broaden.

## Relevant files
- start_mspaint.ps1 - existing proven workaround; KEEP as documented fallback if
  root cause cannot be isolated. Reuse its packaged-vs-classic detection + hidden
  launch interop as reference.
- start_mspaint.cmd - launcher reference for the hidden-PowerShell pattern.
- (new) src/ArcInputFix/ArcInputFix.cpp - the utility.
- (new) src/ArcInputFix/ArcInputFix.vcxproj (or build.cmd) - MSVC build.
- (new) deploy/ArcInputFix-Logon.xml - scheduled task definition.
- (new) deploy/Install-ArcInputFix.ps1 - registers task / installs exe.

## Verification
1. Phase 2: minimal trigger alone restores NC drag/resize (no mspaint) + persists to logoff.
2. Utility run manually from broken state restores NC drag/resize within ~1s.
3. After reboot+logon with task enabled, Clarion caption drag + border resize work
   immediately with no visible window/console flash.
4. Event Log shows one success entry per logon; exit code 0.
5. Pilot units stable across multiple logon/logoff cycles.

## Contingency / excluded scope
- If no single trigger isolates cleanly, fall back to packaging the existing
  mspaint-launch workaround (start_mspaint.ps1 logic) as the utility body.
- Excluded: fixing Intel's driver, Clarion runtime changes, Microsoft escalation
  (worth filing in parallel but not part of this deliverable).

## Implementation status (done)
- tools/Invoke-FixDiff.ps1  - Phase 1 service/process/driver diff around mspaint launch.
- tools/Capture-Modules.ps1 - Phase 1 deep capture (DLL diff + optional Procmon) for one-shot triggers.
- src/ArcInputFix/ArcInputFix.cpp - candidate-driven utility: default --pointer-dm
  (EnableMouseInPointer + DirectManipulationManager CoCreateInstance + DwmFlush),
  --service <name>, --mspaint fallback. GUI subsystem, Event Log logging.
- src/ArcInputFix/build.cmd - MSVC build (/MT /SUBSYSTEM:WINDOWS), auto-imports vcvars64.
- deploy/ArcInputFix-Logon.xml - reference logon task (interactive user, hidden).
- deploy/Install-ArcInputFix.ps1 - registers logon task; -Action PointerDm/Service/Mspaint,
  -Uninstall. PS syntax + XML validated.
- BUILT OK on VS2022 Community: ArcInputFix.exe, GUI subsystem (windowless), ~120KB,
  --pointer-dm exit 0. Fixed build.cmd delayed-expansion bug (now imports vcvars via vswhere).

## Findings (Dell laptop)
- Invoke-FixDiff on Dell: persistent svc Stopped->Running = ClipSVC, StiSvc(WIA);
  new procs RuntimeBroker + svchost; Paint that ran = PACKAGED (WindowsApps), classic
  mspaint.exe NOT present on Dell. => all diff hits are Store-activation NOISE, not the
  input trigger. Hypothesis A (service start) RULED OUT.
- ArcInputFix.exe --pointer-dm did NOT fix the bug. => lightweight EnableMouseInPointer +
  DirectManipulation COM init is NOT the trigger.
- Next theory: trigger needs a real composed top-level window and/or a GPU device on the
  Intel Arc (DWM/compositor/D3D warm-up).

## User decisions (round 2)
- Code signing NOT available yet (sign before fleet rollout; unsigned may trip SmartScreen/WDAC).
- Task runs as logged-on user -> already default (Users group, Limited run level). OK.
- VS2022 + MSVC present on dev box.

## Next actions (require affected 268V hardware)
1. Run tools/Invoke-FixDiff.ps1 from fresh broken logon -> identify trigger (svc/proc/driver).
2. If empty, run tools/Capture-Modules.ps1 (+Procmon/API Monitor) -> identify DLL/API.
3. Build exe (src/ArcInputFix/build.cmd on a VS box), test each candidate via
   ArcInputFix.exe --pointer-dm / --service NAME from broken state (Phase 2 validation).
4. Set the confirmed winner as default action; install via Install-ArcInputFix.ps1.

## Bisection actions added to ArcInputFix (built+smoke-tested exit 0)
- --window  : real off-screen WS_OVERLAPPEDWINDOW + DwmExtendFrameIntoClientArea + pump.
- --d3d     : D3D11CreateDeviceAndSwapChain (flip model) on Arc + Present x2.
- --dcomp   : DirectComposition device+target+visual+Commit.
- --gdiplus : GdiplusStartup + trivial draw.
- --all     : runs all of the above + pointer-dm; success if any.
- --mspaint : known-good fallback (launch hidden, wait, kill).
NEXT: on Dell from fresh broken logon, test --all first; if it fixes, bisect single
flags (--d3d, --dcomp, --window, --gdiplus) to find the minimal trigger; set as default.
If --all fails but --mspaint works -> go Procmon/API Monitor (Capture-Modules.ps1).


## Round 3 results
- --all (gdiplus+window+dcomp+d3d+pointer-dm) did NOT fix it. Caption BUTTONS
  (min/max/close) ALSO dead => entire non-client input path down, not just move/size loop.
  Consistent with DWM/win32k modern-input (InputHost/CoreMessaging) uninitialized for the
  session until a real CoreWindow/foreground app registers.
- Added --foreground: real ON-SCREEN, layered alpha=0, 1x1, SetForegroundWindow+active,
  pump 1.5s, close. Mimics mspaint's foreground window (the one thing --window/off-screen
  did NOT do). Added to --all too. Built + smoke-tested exit 0.
- Made Capture-Modules.ps1 robust: tasklist /m fallback for packaged apps + dumps
  mspaint-children.csv (ApplicationFrameHost/TextInputHost etc.).
NEXT (decisive, no reboot): run Capture-Modules.ps1 on Dell -> send mspaint-modules.csv +
  mspaint-children.csv to see which input/graphics DLLs Paint loads that our exe doesn't.
ALSO quick test (1 logon): ArcInputFix.exe --foreground.

## Round 4 results
- --foreground also did NOT fix it. Now ruled out: pointer-dm, gdiplus, off-screen window,
  FOREGROUND on-screen activated window, d3d11 swapchain, dcomp. Packaged Paint still works.
  => trigger is in the modern app / CoreWindow input-host stack (InputHost.dll /
     CoreMessaging.dll / textinputframework.dll) that a UWP/packaged process registers with;
     a plain Win32 exe does not spin this up.
- Procmon runaway bug FIXED in Capture-Modules.ps1: the `& procmon ... | Out-Null` BLOCKED
  (Procmon never exits while capturing) so /Terminate never ran and backing files grew
  unbounded (3.5GB rolling). Now Procmon is OPT-IN (-WithProcmon), launched non-blocking via
  Start-Process, stopped with /Terminate -Wait. Default run = modules + children only (tiny).
  User must stop stuck Procmon (procmon /Terminate or Stop-Process) + delete *.pml.

## Round 5 - MODULE CAPTURE analyzed (Dell)
- Dell Paint = WinUI 3 / Windows App SDK (Microsoft.WindowsAppRuntime.1.8); children CSV EMPTY
  (in-process, no ApplicationFrameHost).
- DLLs Paint loads that our warm-ups did NOT init: CoreMessaging.dll, InputHost.dll,
  textinputframework.dll, Windows.UI.dll, twinapi.appcore.dll, Microsoft.UI.Input/Windowing/
  Composition.OSSupport, Microsoft.DirectManipulation (WinAppSDK).
- KEY INSIGHT: --pointer-dm used LEGACY DM (ninput.dll); --dcomp used RAW dcomp. Paint uses the
  MODERN "lifted" input/composition via CoreMessaging + Windows.UI.Composition - never exercised.
- Added --coremsg: CreateDispatcherQueueController (CoreMessaging.dll, dynamic) + RoActivateInstance
  Windows.UI.Composition.Compositor + pump 1s. Links runtimeobject.lib. Built + smoke exit 0.
NEXT (1 logon on Dell): ArcInputFix.exe --coremsg -> does NC drag/resize/caption work?
  If yes -> lock as default. If no -> minimal packaged WinUI3 helper, or ship --mspaint fallback.

## Round 6 - --coremsg FAILED on Dell; two fixes shipped
- --coremsg did NOT fix it (object creation alone insufficient). --mspaint also failed because
  it only did classic mspaint.exe via CreateProcess and 25H2 Dell has NO classic mspaint.exe.
- FIX 1 (--mspaint): now falls back to packaged Paint via IApplicationActivationManager
  (CLSID 45BA127D-..., AUMID Microsoft.Paint_8wekyb3d8bbwe!App, AO_NOERRORUI) + OpenProcess +
  Sleep 5s + TerminateProcess. Classic path kept first. New helper LaunchPackagedPaint().
- FIX 2 (NEW --render): REAL lifted-composition render init beyond object creation. Uses
  C++/WinRT: CreateDispatcherQueueController (CoreMessaging) -> winrt Compositor{} -> bind to a
  real off-screen HWND via ABI::Windows::UI::Composition::Desktop::ICompositorDesktopInterop
  ::CreateDesktopWindowTarget -> SpriteVisual + CreateColorBrush + target.Root -> PumpMessages
  1.5s (dispatcher commits/presents) + DwmFlush. DoRenderWarmup(). Added to --all (a8).
- BUILD CHANGES: build.cmd added /std:c++17. Swapped runtimeobject.lib -> windowsapp.lib
  (umbrella, provides RoActivate/WindowsCreateString + C++/WinRT). Added includes:
  shobjidl_core.h, windows.ui.composition.interop.h, winrt/base.h, winrt/Windows.UI.h,
  winrt/Windows.UI.Composition.h, winrt/Windows.UI.Composition.Desktop.h.
  GOTCHA: ICompositorDesktopInterop & IDesktopWindowTarget are in namespace
  ABI::Windows::UI::Composition::Desktop (NOT global). Built + smoke exit 0 for both.
NEXT (Dell, fresh broken logon): test BOTH
  .\src\ArcInputFix\ArcInputFix.exe --render    (preferred; lighter than packaged helper)
  .\src\ArcInputFix\ArcInputFix.exe --mspaint   (proven workaround, now packaged-Paint capable)
  If --render works -> lock as default, no MSIX helper needed. If only --mspaint works -> ship
  that OR build owned MSIX WinUI3/CoreWindow helper. If neither -> trigger needs package identity.

## Round 7 - KEY PARADOX: same Paint activation fixes from PS but NOT from ArcInputFix
- Dell test: --mspaint opened+closed UWP Paint (~5s, VISIBLE) but did NOT fix. --render did NOT fix.
- BUT start_mspaint.ps1 (same IApplicationActivationManager activation) DOES fix. Manual Paint DOES fix.
- => Paint IS sufficient (manual proves it). A VISIBLE rendered Paint via --mspaint still failed =>
  rendering Paint's window is NOT the trigger by itself. Differentiator = lifecycle/host around it.
- Two things PS host did that blind activate+Sleep(5s)+kill missed:
  (1) WAIT for Paint's top-level window to appear (poll EnumWindows up to 5s) before timing starts.
  (2) Runs in an STA that PUMPS messages during waits (Start-Sleep doesn't pump but CLR STA can);
      also total Paint runtime ~window+5s (~7-8s) vs our 5s-from-activation (~3s real).
- FIX (Round 7): rewrote LaunchPackagedPaint to replicate+exceed PS: OpenProcess -> poll EnumWindows
  (FindAndHidePaintWnd, SW_HIDE like ps1) up to ~10s pumping via PumpMessages(200) -> dwell
  PumpMessages(8000) -> TerminateProcess. Covers both timing AND message-pump hypotheses. Built, exit 0.
NEXT (Dell, broken logon): .\src\ArcInputFix\ArcInputFix.exe --mspaint  -> does it fix now?
- If YES -> timing/pump was it; lock --mspaint as default deliverable.
- If NO (but ps1 still fixes) -> differentiator is the HOST PROCESS itself (powershell.exe/.NET),
  not Paint lifecycle. PRAGMATIC SHIP: just run the proven start_mspaint.ps1 hidden at logon via
  Task Scheduler (start_mspaint.cmd already does this). Drop native-exe approach for the fix.

## Round 8 - APP EXECUTION ALIAS hypothesis (user's key insight)
- Round 7 (--mspaint with wait-for-window + pump + 8s dwell) STILL did NOT fix on Dell.
- USER KEY CLUE: typing `mspaint` or `mspaint.exe` (NO full path) in a prompt DOES fix it. The exe
  is NOT in %PATH% literally - it's the App Execution Alias at
  %LOCALAPPDATA%\Microsoft\WindowsApps\mspaint.exe (a reparse point, that dir IS on user PATH).
- INSIGHT: alias launch via CreateProcess gives packaged Paint package identity DIRECTLY in the
  user's interactive context, vs IApplicationActivationManager which routes through the DCOM
  activation broker (different context). That context difference is likely why broker activation
  (ArcInputFix Round 6/7 AND ps1 path2) behaved differently. Alias = proven-working manual path.
- FIX (Round 8): new LaunchPaintViaAlias() - CreateProcess on the alias (resolve
  %LOCALAPPDATA%\Microsoft\WindowsApps\mspaint.exe, else bare "mspaint.exe" PATH search), NO forced
  SW_HIDE (match manual), snapshot Paint PIDs before via Toolhelp (names mspaint.exe/PaintApp.exe/
  Paint.exe), find NEW Paint PIDs after, HideWindowsOfPid, PumpMessages(8000) dwell, terminate all
  targets. DoMspaintFallback now tries alias FIRST, then classic System32, then broker activation.
  Added <tlhelp32.h> + <vector>. Built, exit 0, no errors.
NEXT (Dell, broken logon): .\src\ArcInputFix\ArcInputFix.exe --mspaint  -> fix now?
  If YES -> lock as default deliverable (alias launch). If NO -> compare: does manual `mspaint`
  still fix in SAME session right after? If manual works but our CreateProcess-alias doesn't, the
  differentiator is parent/console/token context -> consider ShellExecute("mspaint") or launching
  via explorer, or just ship start_mspaint.ps1 at logon.

## Round 9 - SOLVED. Alias launch WORKS on Dell. ArcInputFix.exe --mspaint fixes the session.
- CONFIRMED working deliverables: (1) ArcInputFix.exe --mspaint (App Execution Alias launch),
  (2) powershell start_mspaint.ps1.
- ROOT-CAUSE SIGNATURE (what the trigger requires, deduced from all rounds):
  * A process WITH PACKAGE IDENTITY that spins up the modern WinUI3/CoreWindow input+composition
    stack, launched as a NORMAL CHILD via CreateProcess (alias reparse) in the interactive session.
  * NOT sufficient: identity-less Win32 exe doing real composition render (--render failed),
    object-only coremsg, pointer-dm, d3d, dcomp, gdiplus, foreground.
  * NOT sufficient: SAME packaged Paint launched via DCOM broker (IApplicationActivationManager) -
    broker child runs in different context. Alias=CreateProcess child = works.
- => to DROP Paint dependency need package identity. Options ranked:
  (a) SHIP alias launch / PS script now (recommended; needs no signing).
  (b) custom minimal MSIX WinUI3/CoreWindow helper (Paint-independent; needs WindowsAppSDK + signing).
  (c) sparse-package ArcInputFix to grant identity, then --render (lightest custom; needs signing to register).
  (d) target another guaranteed-present packaged app's alias instead of Paint (no new code).
- Signing NOT available yet -> (b)/(c) blocked for fleet. Recommend ship (a), lock --mspaint default,
  update Install-ArcInputFix.ps1 default action to Mspaint. Risk: depends on packaged Paint present.

---

# Next Plan: Convert ArcInputFix.cpp to Clarion

## Goal
Port the trimmed ArcInputFix.cpp (the "single purpose" mspaint-launch utility in
src/ArcInputFix/ArcInputFix.cpp) into a Clarion 11/11.1 Win32 hand-coded project in
a NEW folder, faithfully replicating the alias + classic mspaint CreateProcess paths.
Windowless, logs one line to Windows Event Log.

## Decisions (from user)
- Clarion 11/11.1 Win32, hand-coded .cwproj (NOT Clarion#, NOT legacy .prj).
- Scope = alias launch + classic mspaint.exe CreateProcess ONLY. DROP the
  IApplicationActivationManager COM packaged-Paint fallback.
  NOTE: dropping COM is OK because the App Execution Alias (mspaint.exe in
  %LOCALAPPDATA%\Microsoft\WindowsApps) already launches PACKAGED Paint on the
  25H2 Dell — that alias path IS the proven primary fix.
- Windowless; a minimal hidden window allowed but not needed (no Clarion window opened).

## Key technical constraints
- Clarion classic = 32-bit only (no x64 through 11.1). Exe runs under WOW64. All
  APIs used (CreateProcess, Toolhelp, EnumWindows, event log) work fine in 32-bit.
  Alias launch of packaged Paint works from 32-bit.
- Use ANSI (A) Win32 APIs (CreateProcessA, GetEnvironmentVariableA, RegisterEventSourceA,
  Process32First/Process32FirstW? use ANSI Process32First w/ PROCESSENTRY32) — Clarion
  CSTRING maps directly to ANSI. All strings here are ASCII.
  Caveat: non-ASCII LOCALAPPDATA path would break (rare); acceptable.
- WOW64 nuance: GetSystemDirectoryA returns SysWOW64 in 32-bit. Only used for working
  dir + classic mspaint.exe existence check (which Dell lacks anyway). To check real
  System32 classic mspaint from 32-bit, would need %WINDIR%\Sysnative. Minor; alias is primary.
- Clarion exes are GUI subsystem (no console) by default -> matches /SUBSYSTEM:WINDOWS.

## New folder + files: src/ArcInputFixClarion/
- ArcInputFix.cwproj  — Clarion 11 MSBuild project; OutputType=exe; Runtime=Local
  (statically linked, self-contained like the C++ /MT build).
- ArcInputFix.clw     — single-file PROGRAM: global MAP (local procs + MODULE win32
  prototypes), equates, data, CODE, procedure implementations.
- build.cmd           — command-line build via ClarionCL.exe / MSBuild (analog of
  src/ArcInputFix/build.cmd). Locates Clarion bin, builds Release Win32.
- (optional) ArcInputFix.red — local redirection if needed for libsrc/libs.

## Function mapping (C++ -> Clarion)
- LogEvent            -> LogEvent(USHORT pType,*CSTRING pMsg) — RegisterEventSourceA/
                         ReportEventA/DeregisterEventSource + OutputDebugStringA.
- PumpMessages        -> PumpMessages(ULONG pMs) — GetTickCount loop + PeekMessageA(PM_REMOVE)
                         + TranslateMessage + DispatchMessageA + Sleep(10). MSG group.
- FindAndHidePaintWnd -> callback PROCEDURE(LONG hwnd,LONG lparam),BOOL,RAW,PASCAL.
                         Use MODULE-GLOBAL state (GsTargetPid, GsHidden) instead of
                         threading a struct via lParam — cleaner in Clarion. Passed to
                         EnumWindows via ADDRESS(FindAndHidePaintWnd).
- HideWindowsOfPid    -> HideWindowsOfPid(ULONG pid),BYTE — sets globals, calls EnumWindows.
- CollectPidsByName   -> CollectPidsByName(*CSTRING exeName,*QUEUE pidQ) — Toolhelp
                         snapshot + Process32First/Next; QUEUE(ULONG) replaces std::vector.
- LaunchPaintViaAlias -> LaunchPaintViaAlias(),BYTE — resolve alias path via
                         GetEnvironmentVariableA(LOCALAPPDATA)+GetFileAttributesA, else
                         "mspaint.exe" on PATH. Snapshot before-PIDs, CreateProcessA with
                         STARTF_USESHOWWINDOW+SW_HIDE and a valid working dir, poll/hide
                         new Paint PIDs (up to ~10s pumping), dwell 8s pumping, TerminateProcess all.
- DoMspaintFallback   -> DoMspaintFallback(),BYTE — alias first; then classic
                         <sysdir>\mspaint.exe if present (CreateProcessA + Sleep(5000) + kill).
                         (COM LaunchPackagedPaint path OMITTED per scope.)
- wWinMain            -> PROGRAM CODE: ok#=DoMspaintFallback(); LogEvent(...); RETURN(CHOOSE(ok#,0,1)).

## Win32 prototypes (MODULE('Win32'), PASCAL,RAW,DLL): ANSI variants
kernel32: GetEnvironmentVariableA, GetFileAttributesA, GetSystemDirectoryA,
  CreateProcessA, OpenProcess, TerminateProcess, CloseHandle, GetTickCount, Sleep,
  CreateToolhelp32Snapshot, Process32First, Process32Next.
user32:   EnumWindows, GetWindowThreadProcessId, IsWindowVisible, ShowWindow,
  PeekMessageA, TranslateMessage, DispatchMessageA, OutputDebugStringA(kernel32).
advapi32: RegisterEventSourceA, ReportEventA, DeregisterEventSource.
GROUPs (32-bit layout): STARTUPINFO, PROCESS_INFORMATION, PROCESSENTRY32, MSG.
Equates: STARTF_USESHOWWINDOW=1, SW_HIDE=0, PROCESS_TERMINATE=1,
  TH32CS_SNAPPROCESS=2, INVALID_HANDLE_VALUE=-1, INVALID_FILE_ATTRIBUTES=-1,
  PM_REMOVE=1, EVENTLOG_ERROR_TYPE=1, EVENTLOG_WARNING_TYPE=2, EVENTLOG_INFORMATION_TYPE=4.

## Verification
1. Build: run src/ArcInputFixClarion/build.cmd -> ArcInputFix.exe produced, no errors.
   (Or open .cwproj in Clarion IDE, Make, Release/Win32.)
2. Windowless: launch exe -> no window/console flash; process exits ~ after dwell.
3. Functional (affected Dell, fresh broken logon): run exe from broken state ->
   Clarion MDI caption drag + border resize + caption buttons start working; persists to logoff.
4. Event Log: one ArcInputFix entry per run (Information on success).
5. Compare behavior to C++ ArcInputFix.exe alias path (should match).

## Out of scope
- COM IApplicationActivationManager packaged-Paint fallback (dropped per decision).
- C++/WinRT --render/--coremsg bisection flags (already removed from the trimmed cpp).
- Changing deploy/ task XML + Install-ArcInputFix.ps1 (optional follow-up: point the
  logon task at the Clarion exe). Not included unless requested.
- 64-bit build (Clarion classic can't; not needed).

## Build env (CONFIRMED)
- Clarion 11.0, command-line compiler: C:\Clarion\bin\ClarionCL.exe
- build.cmd uses CLARION_BIN env override, default C:\Clarion\bin; invokes
  ClarionCL.exe on ArcInputFix.cwproj (Release/Win32).

## IMPLEMENTATION RESULT (DONE - all files build + run OK)
Files: src/ArcInputFixClarion/{ArcInputFix.clw, ArcInputFix.cwproj, build.cmd}
Verified: build exit 0; exe runs exit 0 (~19s = 10s wait + 8s dwell); writes
Event Log "ArcInputFix mspaint succeeded"; x86 GUI-subsystem (windowless).

### Clarion build gotchas discovered (IMPORTANT for future Clarion work here)
- ClarionCL.exe has NO build switch. Build hand-coded .cwproj via .NET Framework
  MSBuild: %WINDIR%\Microsoft.NET\Framework\v4.0.30319\MSBuild.exe with
  /p:ClarionBinPath="C:\Clarion\bin" and /p:clarion_version="<exact name>".
- clarion_version MUST be the EXACT registered name incl. build no., e.g.
  "Clarion 11.0.13505" (NOT "11.0", NOT "Clarion11"). Found under
  <Properties name="Clarion.Versions"> in
  %APPDATA%\SoftVelocity\Clarion\11.0\ClarionProperties.xml. build.cmd
  auto-detects it (powershell xml parse); override via CLARION_VERSION.
- Project imports $(ClarionBinPath)\SoftVelocity.Build.Clarion.targets.
- Model=Lib (STATIC runtime) produced a CRASHING exe: even a trivial
  PROGRAM/MAP END/CODE/RETURN died with STACK_OVERFLOW (0xC00000FD) at startup.
  Model=Dll (Clarion runtime DLLs) WORKS. => use Model=Dll.
- Model=Dll means the exe needs CLARUN.DLL at runtime (imports: KERNEL32,
  USER32, ADVAPI32, CLARUN.DLL). build.cmd copies ClaRUN.dll into 0release\ so
  the folder is self-runnable. DEPLOYMENT: ship ClaRUN.dll beside ArcInputFix.exe.
- Output path (Release) via redirection = .\0release\ (not bin\).
- echo text inside cmd if() blocks must NOT contain literal ) -> breaks the
  block (caused a spurious "[ERROR] ... code 0"). Avoid parens in echo.

### Clarion porting notes (worked)
- ANSI (A) Win32 APIs via MODULE('WINAPI') prototypes, distinct w_ names +
  NAME('FnA'); link via PRAGMA('link(WIN32.LIB)'). All needed symbols
  (Toolhelp, EnumWindows, event log, CreateProcess) resolved from WIN32.LIB.
- Windows callback (EnumWindows) = ,PASCAL (=stdcall on Clarion32), NOT RAW,
  scalar LONG params, called via ADDRESS(proc). Module-global state for the
  callback (GsTargetPid/GsHidden) instead of lParam struct. Works (no overflow
  once Model=Dll).
- 32-bit groups: STARTUPINFO(68B)/PROCESS_INFORMATION(16B)/PROCESSENTRY32(296B,
  szExeFile CSTRING(260))/MSG(28B). PROC attr on all API fns so returns can be
  ignored. ExitProcess sets exit code 0/1.
- Scope kept per decision: alias + classic mspaint CreateProcess only; COM
  packaged-Paint path omitted.

## Round 10 - Clarion alias launch FAILED on Dell; suspected root cause = forced SW_HIDE
- Dell test: Clarion ArcInputFix.exe (alias launch) ran ~19s then exited 0, but
  Clarion MDI caption-drag + border-resize STILL did not work.
- DIAGNOSIS: the Clarion port forced STARTF_USESHOWWINDOW + SW_HIDE in STARTUPINFO
  at CreateProcess time. The PROVEN C++ Round 8/9 alias path used NO forced SW_HIDE
  ("match manual") - Paint shows briefly, then is hidden ONLY AFTER its window
  appears. A pre-hidden Paint never spins up the WinUI3/CoreWindow input+composition
  stack that Round 9 identified as the actual trigger. The ~19s runtime was the tell:
  the wait loop never broke early => no visible Paint window was ever found/hidden
  (HidAny stayed 0) even on the dev box.
- FIX (Round 10): LaunchPaintViaAlias no longer sets STARTF_USESHOWWINDOW/SW_HIDE
  (CLEAR(SI) only). Paint launches with default show (like typing "mspaint"); the
  existing post-launch EnumWindows pass hides it once its window appears. Added an
  Event Log diagnostic line: cmd=, newPid=, targets=, hidWin=, terminated=.
- DEV VERIFICATION: runtime dropped 19s -> ~9s (wait loop now breaks early). Log:
  'alias launch: cmd="...\WindowsApps\mspaint.exe" newPid=29504 targets=1 hidWin=1
  terminated=1' (hidWin=1 = a real Paint window appeared and was hidden; was 0 before).
NEXT (Dell, fresh broken logon): run src/ArcInputFixClarion/0release/ArcInputFix.exe
  (ship ClaRUN.dll beside it) -> does caption-drag/border-resize work now?
  Read the 'alias launch:' Event Log line to confirm hidWin=1 on the Dell too.
  - If YES -> Clarion port reaches parity with C++ Round 9; lock as deliverable.
  - If NO but hidWin=1 -> Paint DID show+init yet still no fix => 32-bit (WOW64)
    parent context is the differentiator vs the 64-bit C++ exe; consider building/
    shipping the C++ exe instead, or a 64-bit launcher.
  - If hidWin=0 on Dell -> packaged Paint ran under a name not in the detection list
    (mspaint.exe/PaintApp.exe/Paint.exe); widen the list.

## Round 11 - bitness CONFIRMED as cause; launch Paint via 64-bit cmd (Sysnative)
- Dell test (Round 10 build, no forced SW_HIDE): Paint NOW opened VISIBLY + lingered
  in Task Manager, log 'alias launch: cmd="...\WindowsApps\mspaint.exe" newPid=21904
  targets=1 hidWin=1 terminated=1' - so Paint genuinely launched+showed+was killed -
  but the bug was STILL not fixed.
- DECISIVE COMPARISON: on the SAME Dell, the 64-bit C++ ArcInputFix.exe DOES fix it.
  => Paint lifecycle is NOT the differentiator; the LAUNCHER's bitness is. A 32-bit
  (WOW64) parent doing CreateProcess(alias) shows Paint but does not re-arm the
  session input path; a native 64-bit parent does. Clarion classic is 32-bit only.
- FIX (Round 11, option B): LaunchPaintViaAlias now launches Paint THROUGH the 64-bit
  cmd so Paint is created in a native 64-bit context:
  CreateProcess('%WINDIR%\Sysnative\cmd.exe /s /c "<alias>"', CREATE_NO_WINDOW).
  Sysnative = the real 64-bit System32 as seen from a 32-bit process; no 'start' so
  the 64-bit cmd is Paint's DIRECT parent. Snapshot diff still finds+hides+kills the
  real Paint (the launched PID is now the cmd shell, excluded from the target set in
  cmd64 mode). Falls back to direct 32-bit launch if Sysnative\cmd.exe is absent.
  Diagnostic line now includes via=cmd64|direct.
- DEV VERIFY: via=cmd64, cmd="C:\WINDOWS\Sysnative\cmd.exe" /s /c ""...\mspaint.exe"",
  targets=1 hidWin=1 terminated=1, ~9s. Ready for Dell test.
NEXT (Dell, fresh broken logon): run src/ArcInputFixClarion/0release/ArcInputFix.exe
  (with ClaRUN.dll beside it) -> does caption-drag/border-resize work now?
  - If YES -> the 64-bit launch context was the missing piece; lock as deliverable.
  - If NO -> a 32-bit process cannot trigger the fix even via a 64-bit child launcher
    (the re-arm likely keys off the ORIGINATING process token/bitness, not the cmd
    child). Conclusion: ship the proven 64-bit C++ ArcInputFix.exe or start_mspaint.ps1;
    Clarion classic (32-bit) can't deliver this specific hardware fix.

## Round 12 - SOLVED on Dell (via=cmd64). Flicker reduced.
- Dell test (Round 11 build): caption-drag + border-resize WORK. The 64-bit cmd
  launch context was the missing piece. Clarion port now reaches parity with the
  C++ Round 9 fix.
- DRAWBACK: brief screen flicker - Paint's window showed for up to ~200ms before
  the poll loop caught + hid it.
- NOTE: Paint MUST render (pre-hidden SW_HIDE launch did NOT fix - Round 10), so we
  can't open it fully hidden. Instead tightened the detect-and-hide loop from
  PumpMessages(200) x50 to PumpMessages(15) x600: Paint is now hidden within ~1
  frame of appearing, so the render still happens (fix preserved) but the visible
  flash drops from ~12 frames to ~1. Dev: exit 0, hidWin=1, ~9s (8s dwell dominates).

## Round 13 - Replicate the C++ exactly (64-bit CreateProcess + SW_HIDE, no flicker)
- WHY: Round 12 cmd64 fixed the Dell but flickered (cmd.exe cannot pass SW_HIDE to
  its child, so Paint's window flashed). The proven 64-bit C++ exe launches the
  alias with STARTF_USESHOWWINDOW + SW_HIDE (ArcInputFix.cpp ~L178-179) and fixes
  the Dell WITH NO FLICKER - so "Paint must render visibly" (Round 10) was WRONG.
- CONSTRAINT: Clarion 11 classic is 32-bit only; it cannot itself do a native 64-bit
  CreateProcess. cmd64 gave the 64-bit context but not SW_HIDE. Need BOTH.
- FIX: LaunchPaintViaAlias now delegates the launch to 64-bit Windows PowerShell
  running a deployed helper, `launch-paint-hidden.ps1`, which does the IDENTICAL
  Win32 CreateProcess(alias) with STARTF_USESHOWWINDOW + SW_HIDE as the C++ -> native
  64-bit context (the fix) AND genuinely hidden (no flicker). Clarion (32-bit) builds
  the command line for `%WINDIR%\Sysnative\WindowsPowerShell\v1.0\powershell.exe`
  (Sysnative = real 64-bit System32 from a 32-bit process), launches it hidden +
  CREATE_NO_WINDOW, WaitForSingleObject, then reads the helper's exit code.
  Diagnostic line: `alias launch: via=ps64 alias=<path> helperExit=<code> wait=<n>`.
- HELPER PID RESOLUTION GOTCHA: CreateProcess on the WindowsApps reparse alias with
  lpApplicationName = NULL fails with ERROR_PATH_NOT_FOUND (3); passing the resolved
  full alias path as lpApplicationName (as start_mspaint.ps1 documents) succeeds.
  The helper now sets lpApplicationName = $AliasPath when it is a full path.
- DEPLOY: build.cmd now copies launch-paint-hidden.ps1 into 0release\ alongside
  ArcInputFix.exe + ClaRUN.dll. All three must ship together.
- DEV VERIFY: build 0 warn/0 err; exe exit 0; log `via=ps64 ... helperExit=0 wait=0`
  -> "ArcInputFix mspaint succeeded". Paint launched fully hidden (no flash). Ready
  for Dell test.
- NEXT (Dell, fresh broken logon): run 0release\ArcInputFix.exe (with ClaRUN.dll +
  launch-paint-hidden.ps1 beside it) -> caption-drag/border-resize fixed AND no
  flicker? Expected YES (this is byte-for-byte the C++ launch, just hosted in a
  64-bit PowerShell helper instead of the 64-bit C++ exe).

## Round 14 - Owned MSIX warm-up helper FAILED on Dell (Paint dependency stays)
- GOAL: drop the Paint dependency with an owned, package-identity helper. Built
  src/ArcInputFixWarmup/ - a windowless 64-bit Win32 exe that spins up the modern
  in-box stack (CreateDispatcherQueueController + Windows.UI.Composition.Compositor
  + ICompositorDesktopInterop::CreateDesktopWindowTarget on a hidden top-level
  window, pump ~3s, exit), wrapped in a signed MSIX (AppxManifest.xml: runFullTrust
  Windows.FullTrustApplication + App Execution Alias ArcInputFixWarmup.exe). The
  At-logon task launches it via that alias - the SAME CreateProcess-with-identity
  path the proven Paint alias uses. This satisfies ALL THREE Round 9 conditions:
  package identity + CreateProcess child in the interactive session + the modern
  WinUI3/CoreWindow composition+input stack.
- BUILD: build.cmd compiles, generates placeholder assets, makeappx pack, signs
  (self-signed dev cert by default; SIGN_PFX for release). Deploy via
  deploy/Install-ArcInputFixWarmup.ps1 (Add-AppxPackage + hidden At-logon task,
  -DevCert trusts the test cert). Dev: built clean /W4, packed+signed OK.
- DELL TEST RESULT: DID NOT FIX. From a fresh broken logon, one run of the signed,
  alias-launched helper did NOT re-arm caption drag / border resize / min-max-close.
  Packaged Paint in the same session still fixes it.
- CONCLUSION: the Round 9 signature is NECESSARY BUT NOT SUFFICIENT. Package
  identity + the in-box composition/input warm-up is not the whole trigger - real
  packaged Paint does something MORE that this minimal helper does not (not yet
  identified). Ship stays the proven 64-bit C++ ArcInputFix.exe (alias launch) /
  start_mspaint.ps1. src/ArcInputFixWarmup/ is retained as a documented dead-end +
  a base for module-diff investigation (see docs/test-warmup-helper.md).
- NEXT (differential diagnosis from data ALREADY captured): tools/Capture-Modules.ps1
  was already run on the Dell - outputs in tools/fixdiff-out/ (mspaint-modules.csv =
  Paint's DLLs; mspaint-children.csv empty = in-process; services/processes/drivers
  before|during|after). The module list pins a concrete differentiator: real Paint
  loads the LIFTED Windows App SDK 1.8 Microsoft.UI.* input/composition stack -
  Microsoft.UI.Input.dll, Microsoft.InputStateManager.dll, Microsoft.UI.Windowing.dll,
  Microsoft.UI.Composition.OSSupport.dll, Microsoft.Internal.FrameworkUdk.dll, plus
  CoreMessagingXP/dcompi/dwmcorei/wuceffectsi (all Microsoft.WindowsAppRuntime.1.8).
  ArcInputFixWarmup used only the IN-BOX Windows.UI.Composition.Compositor, so it never
  loaded the lifted Microsoft.UI.Input / InputStateManager stack = the most likely
  missing ingredient. NEW HYPOTHESIS to test (one, not another blind warm-up): a
  package-identity helper that spins up the LIFTED Microsoft.UI input stack (Windows App
  SDK Microsoft.UI.Windowing.AppWindow + Microsoft.UI.Input.InputPointerSource), which
  reverses the original "in-box only / no NuGet" choice that caused the miss. Keep
  ArcInputFix.exe shipped meanwhile.

## Round 15 - Lifted-stack helper BUILT (src/ArcInputFixLifted; awaiting Dell test)
- BUILT the Round 14 "new hypothesis": src/ArcInputFixLifted/ - a real WinUI 3 app
  (C#, .NET 8, Windows App SDK 1.8). Being an actual WinUI 3 app it loads the SAME
  lifted Microsoft.UI.* stack packaged Paint does, instead of the in-box Compositor
  ArcInputFixWarmup used. Headless: OnLaunched creates a WinUI3 Window, moves it
  off-screen + hides it via the lifted AppWindow (Microsoft.UI.Windowing), explicitly
  arms InputNonClientPointerSource.GetForWindowId (the lifted NON-CLIENT pointer input
  owner = exactly the subsystem the bug kills), dwells ~3s, Application.Exit. Logs one
  line to the Application event log (source ArcInputFixLifted).
- PACKAGING: built UNPACKAGED + self-contained (WindowsAppSDKSelfContained=true,
  WindowsPackageType=None) so `dotnet publish -r win-x64` drops the whole lifted runtime
  next to the exe (no fleet WindowsAppRuntime dependency). build.cmd then overlays
  AppxManifest.xml (Identity ArcInputFix.Lifted, runFullTrust, App Execution Alias
  ArcInputFixLifted.exe) + placeholder assets into the publish folder, makeappx pack ->
  ArcInputFixLifted.msix (~86MB, self-contained), signtool sign (self-signed dev cert by
  default; SIGN_PFX for release). Deploy via deploy/Install-ArcInputFixLifted.ps1
  (Add-AppxPackage + hidden At-logon task launching the alias; -DevCert, -Uninstall).
- DEV VERIFY: dotnet build + publish 0 errors; publish folder CONFIRMED to contain
  Microsoft.UI.Input.dll, Microsoft.InputStateManager.dll, Microsoft.UI.Windowing.dll,
  Microsoft.UI.Composition.OSSupport.dll, Microsoft.Internal.FrameworkUdk.dll,
  CoreMessagingXP/dcompi/dwmcorei/wuceffectsi (the exact lifted DLLs from the capture).
  makeappx pack + dev-sign OK; headless exe runs and self-exits code 0 in ~5s, no
  visible window. Ready for Dell test.
- NEXT (Dell, fresh broken logon): Install-ArcInputFixLifted.ps1 -DevCert ... then
  Start-ScheduledTask ArcInputFixLifted (or run the alias) -> does caption-drag /
  border-resize / min-max-close work, no flash, persist to logoff?
  - If YES -> the lifted Microsoft.UI.Input stack was the missing ingredient; sign with
    a real cert (SIGN_PFX) and ship ArcInputFixLifted as the Paint-independent
    deliverable, keep ArcInputFix.exe as fallback.
  - If NO -> even the full lifted stack under identity is insufficient; go to a Procmon
    handle/registry/ALPC diff of a Paint-alias run vs the helper. Keep ArcInputFix.exe
    shipped meanwhile.

## Round 16 - BREAKTHROUGH: the LAUNCH CONTEXT is the missing ingredient
- DELL 268V TEST of ArcInputFixLifted (binary unchanged from Round 15):
  - Launched by the At-logon SCHEDULED TASK (automatically on logon AND manually via
    Start-ScheduledTask): DOES NOT FIX. Caption drag / border resize / min-max-close
    stay broken.
  - DOUBLE-CLICKING the SAME alias in File Explorer
    (%LOCALAPPDATA%\Microsoft\WindowsApps\ArcInputFixLifted.exe): FIXES IT. All three
    work and persist for the whole session.
- CONCLUSION: the helper and its lifted Microsoft.UI.* stack are CORRECT. The missing
  ingredient was never the binary - it is the LAUNCH CONTEXT. The fix requires the
  helper to be launched BY THE INTERACTIVE SHELL (explorer.exe) inside the user's
  interactive logon session, NOT spawned by the Task Scheduler SERVICE host. This
  finally explains the long-standing paradox: broker activation fixed the bug from
  powershell.exe (interactive session) but not from a plain service-spawned Win32 exe.
  The differentiator was always shell/interactive-session launch context.
- IMPLICATION: ArcInputFixLifted is very likely a SHIPPABLE, Paint-independent fix - it
  just has to be launched the way a double-click launches it: by explorer, at logon.
- NEW PLAN - reproduce the explorer/double-click context automatically at logon
  (ranked, both explorer-launched):
  1. Startup-folder shortcut / Run-key value (deploy/Install-ArcInputFixLifted-Shell.ps1).
     explorer.exe launches these at every logon - same path as a double-click.
     - Dell retest (single user): CurrentUser Startup .lnk to the alias (default).
     - Fleet: HKLM\...\Run REG_EXPAND_SZ %LOCALAPPDATA%\...\ArcInputFixLifted.exe so the
       path resolves per-user at logon + provision the MSIX for all users so each user's
       alias exists.
  2. (fallback) a scheduled task that DELEGATES the launch to the running explorer
     (explorer.exe <path> relaunch / IShellDispatch from the running shell). Keeps the
     Task trigger but launches via the shell; more fragile - use only if 1 is blocked.
  3. (fallback) a GPO user logon script that runs in the interactive user context.
- DIAGNOSTIC quick-checks (do these in the interactive session BEFORE relogon, to confirm
  the hypothesis without a reboot): run the alias from (a) a normal PowerShell window and
  (b) the Win+R Run dialog. Both are explorer/interactive launches - expect both to fix
  it, cementing the launch-context conclusion.
- NEXT (Dell): Install-ArcInputFixLifted-Shell.ps1 -DevCert ... -> log off and back on ->
  confirm Clarion is ALREADY fixed before touching anything, no flash, persists to logoff.
  If yes -> sign with a real cert, switch to AllUsers/HKLM Run + provisioned package, ship
  as the Paint-independent fix (keep ArcInputFix.exe as the fallback).
