# ArcInputFix — Copilot project instructions

Durable context for any Copilot chat (VS Code **or** Visual Studio) working in this repo.

## What this project is

A hidden Windows-logon utility that works around an **Intel Arc (Core Ultra 7 268V /
Lunar Lake) bug on Windows 11** where Clarion MDI child windows lose **all non-client
mouse input** (caption drag, border resize, and the min/max/close caption buttons)
until some GUI app with package identity runs once per logon session. The fix persists
for the whole session.

## The solved root cause (do not re-litigate)

The trigger requires **all** of:
1. a process **with package identity**,
2. launched as a **normal child via `CreateProcess`** in the **interactive session**,
3. that spins up the modern **WinUI 3 / CoreWindow input + composition stack**.

The proven mechanism is the **App Execution Alias**:
`%LOCALAPPDATA%\Microsoft\WindowsApps\mspaint.exe` (a reparse-point alias on the user's
PATH). `CreateProcess` on that alias launches packaged Paint with package identity
directly in the interactive session and **re-arms the non-client input path**.

What was tried and **does NOT fix it** (don't suggest these again):
- Identity-less Win32 warm-ups: `EnableMouseInPointer`, `DirectManipulationManager`,
  off-screen/foreground windows, D3D11 swapchain, DirectComposition, GDI+,
  `CreateDispatcherQueueController` + `Windows.UI.Composition.Compositor`, and even a
  real lifted-composition render (`ICompositorDesktopInterop` / `DesktopWindowTarget`).
- Packaged Paint launched via the **DCOM broker** (`IApplicationActivationManager`) —
  wrong context. (Paradox: the same activation fixes it from `powershell.exe` but not
  from a plain Win32 exe — the differentiator is launch method/identity context, not
  timing or message pumping.)

## Confirmed-working deliverables

1. `src/ArcInputFix/ArcInputFix.exe` — launches Paint via the alias (primary fix).
2. `start_mspaint.ps1` — PowerShell workaround (classic CreateProcess or packaged
   activation), launched hidden by `start_mspaint.cmd`.

## Repo layout

- `src/ArcInputFix/ArcInputFix.cpp` — the utility. **Single purpose**: always runs
  `DoMspaintFallback()` (alias launch → classic System32 mspaint → broker as last
  resort). Ignores all command-line arguments. Paint runs hidden (`SW_HIDE`) and is
  terminated after a dwell. Logs one line to the Windows Application event log
  (source `ArcInputFix`).
- `src/ArcInputFix/build.cmd` — MSVC build. Auto-imports `vcvars64` via `vswhere`,
  then `cl /nologo /W4 /O1 /EHsc /MT /std:c++17 /DUNICODE /D_UNICODE ArcInputFix.cpp
  /link /SUBSYSTEM:WINDOWS /OUT:ArcInputFix.exe`. GUI-subsystem (windowless), static
  CRT, x64.
- `deploy/Install-ArcInputFix.ps1` — copies the exe to `%ProgramFiles%\ArcInputFix`
  and registers a hidden **At-logon** scheduled task running as the interactive user
  (`S-1-5-32-545`, `Limited`), **no arguments**. `-Uninstall` removes it.
- `deploy/ArcInputFix-Logon.xml` — reference scheduled-task template.
- `tools/Invoke-FixDiff.ps1`, `tools/Capture-Modules.ps1` — Phase-1 diagnostics
  (service/process/DLL diffs; Procmon is opt-in via `-WithProcmon`). No longer central.

## Conventions & gotchas

- C++17, MSVC (VS 2022 Community), `/SUBSYSTEM:WINDOWS`, `/MT`. No console.
- The exe must stay **single-purpose** — do not re-add the old `--pointer-dm`,
  `--render`, `--service`, etc. action flags.
- `ICompositorDesktopInterop` / `IDesktopWindowTarget` live in namespace
  `ABI::Windows::UI::Composition::Desktop` (NOT global) — relevant only if composition
  code is reintroduced.
- Target fleet: Dell Pro Plus (Core Ultra 7 268V), Windows 11 25H2. **Classic
  `System32\mspaint.exe` is ABSENT** there — only packaged Paint exists.
- **Code signing is not yet available** — blocks shipping a custom MSIX helper to the
  fleet. The current ship is the unsigned alias-launch exe / PS script.

## Open next step (for Visual Studio)

To drop the dependency on Paint being installed, build an **owned minimal MSIX
WinUI 3 / CoreWindow helper** that has package identity and spins up the lifted
input/composition stack itself, then exits. This needs the Windows App SDK and code
signing — hence best done in **Visual Studio** (WinUI 3 + Windows Application Packaging
project templates, MSIX identity, signing, deploy-with-identity F5 loop). See
`docs/handoff-visual-studio.md` for the task brief.
