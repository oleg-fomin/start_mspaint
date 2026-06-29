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

## Owned MSIX helper (removes the Paint dependency)

`src/ArcInputFixWarmup/` is the owned, package-identity replacement for depending on
Paint. It is a windowless Win32 exe (`ArcInputFixWarmup.cpp`) that spins up the same
in-box stack a packaged WinUI 3 app does — `CreateDispatcherQueueController` +
`Windows.UI.Composition.Compositor` + `ICompositorDesktopInterop` /
`IDesktopWindowTarget` on a hidden top-level window — then exits. That exact warm-up
failed as a plain Win32 exe **only because it lacked package identity**; wrapping it in
the MSIX (`AppxManifest.xml`, with a `runFullTrust` `Windows.FullTrustApplication` entry
point + an App Execution Alias `ArcInputFixWarmup.exe`) supplies the missing identity.
The logon task launches it via that alias (the proven CreateProcess-with-identity path).
See `docs/test-warmup-helper.md`.

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
- `src/ArcInputFixWarmup/ArcInputFixWarmup.cpp` — the owned warm-up helper (windowless
  GUI-subsystem exe; raw ABI WinRT, no Windows App SDK / NuGet). `AppxManifest.xml`,
  `build.cmd` (compile → `makeappx` pack → `signtool` sign), and `New-Assets.ps1` /
  `New-DevCert.ps1` build/pack/sign it. `.sln`/`.vcxproj` for editing/debugging in VS.
- `deploy/Install-ArcInputFixWarmup.ps1` — registers the MSIX (`Add-AppxPackage`) and a
  hidden At-logon task that launches it via its App Execution Alias
  (`%LOCALAPPDATA%\Microsoft\WindowsApps\ArcInputFixWarmup.exe`). `-Uninstall` removes
  both; `-DevCert` trusts the self-signed test cert.
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

## Open next step

The owned MSIX helper is now **scaffolded** in `src/ArcInputFixWarmup/` (see above) and
compiles clean with `/W4`. Remaining before fleet rollout:
1. Obtain a real code-signing cert and set `SIGN_PFX` for `build.cmd`; update
   `AppxManifest.xml`'s `Identity/Publisher` to the cert subject exactly.
2. Validate on 268V hardware from a fresh broken logon per `docs/test-warmup-helper.md`
   (confirm caption drag / border resize / min-max-close re-arm **without** Paint and
   with no visible window flash).
3. If confirmed, switch the fleet logon task from `ArcInputFix` to `ArcInputFixWarmup`;
   keep the Paint-alias `ArcInputFix.exe` as the documented fallback.
