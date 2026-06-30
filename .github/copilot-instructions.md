# ArcInputFix — Copilot project instructions

Durable context for any Copilot chat (VS Code **or** Visual Studio) working in this repo.

## What this project is

A hidden Windows-logon utility that works around an **Intel Arc (Core Ultra 7 268V /
Lunar Lake) bug on Windows 11** where Clarion MDI child windows lose **all non-client
mouse input** (caption drag, border resize, and the min/max/close caption buttons)
until some GUI app with package identity runs once per logon session. The fix persists
for the whole session.

## The proven fix and the (incomplete) root-cause signature

The **only** mechanism confirmed to fix the 268V hardware is launching **packaged
Paint** via its **App Execution Alias**:
`%LOCALAPPDATA%\Microsoft\WindowsApps\mspaint.exe` (a reparse-point alias on the user's
PATH). `CreateProcess` on that alias launches packaged Paint with package identity
directly in the interactive session and **re-arms the non-client input path**.

From all experiments the trigger appears to **require** (necessary conditions):
1. a process **with package identity**,
2. launched as a **normal child via `CreateProcess`** in the **interactive session**,
3. that spins up the modern **WinUI 3 / CoreWindow input + composition stack**.

**These three are NOT sufficient on their own** — see the owned-helper result below.
Real packaged Paint does *something more* that our minimal helper does not, and that
extra ingredient is **not yet identified**. Treat the signature as a lead, not a
solved recipe.

What was tried and **does NOT fix it** (don't suggest these again):
- Identity-less Win32 warm-ups: `EnableMouseInPointer`, `DirectManipulationManager`,
  off-screen/foreground windows, D3D11 swapchain, DirectComposition, GDI+,
  `CreateDispatcherQueueController` + `Windows.UI.Composition.Compositor`, and even a
  real lifted-composition render (`ICompositorDesktopInterop` / `DesktopWindowTarget`).
- Packaged Paint launched via the **DCOM broker** (`IApplicationActivationManager`) —
  wrong context. (Paradox: the same activation fixes it from `powershell.exe` but not
  from a plain Win32 exe — the differentiator is launch method/identity context, not
  timing or message pumping.)
- **Our owned MSIX helper `ArcInputFixWarmup`** (package identity + alias-launched
  `CreateProcess` in the interactive session + the in-box composition/input warm-up,
  i.e. ALL THREE conditions above) — **tested on 268V hardware and did NOT fix it.**
  This is the result that demotes the signature to necessary-but-insufficient. A
  32-bit (WOW64) launcher also does not work even when it does spin up Paint (see
  `README.md` Round 11).

## Confirmed-working deliverables

1. `src/ArcInputFix/ArcInputFix.exe` — launches Paint via the alias (primary fix).
2. `start_mspaint.ps1` — PowerShell workaround (classic CreateProcess or packaged
   activation), launched hidden by `start_mspaint.cmd`.

## Owned MSIX helper (attempt to remove the Paint dependency) — TESTED, DID NOT FIX

`src/ArcInputFixWarmup/` is the owned, package-identity helper built to try to replace
depending on Paint. It is a windowless Win32 exe (`ArcInputFixWarmup.cpp`) that spins up
the same in-box stack a packaged WinUI 3 app does — `CreateDispatcherQueueController` +
`Windows.UI.Composition.Compositor` + `ICompositorDesktopInterop` /
`IDesktopWindowTarget` on a hidden top-level window — then exits. It is wrapped in an
MSIX (`AppxManifest.xml`, with a `runFullTrust` `Windows.FullTrustApplication` entry
point + an App Execution Alias `ArcInputFixWarmup.exe`) to give it package identity, and
the logon task launches it via that alias (the same CreateProcess-with-identity path the
Paint alias uses).

**Result (268V hardware): it does NOT fix the bug.** Despite satisfying all three
necessary conditions, one run of the signed, alias-launched helper did not re-arm
caption drag / border resize / min-max-close. So **package identity + the in-box
composition/input warm-up is insufficient** — keep shipping the proven Paint-alias
`ArcInputFix.exe`. The helper, its build, and `docs/test-warmup-helper.md` are retained
as a documented dead-end and a base for further module-diff investigation.

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
- `src/ArcInputFixLifted/` — the **lifted-stack** helper (WinUI 3, C#, Windows App SDK
  1.8): the next hypothesis after `ArcInputFixWarmup` failed. Being a real WinUI 3 app it
  loads the lifted `Microsoft.UI.*` input/composition stack packaged Paint uses (the
  differentiator from `tools/fixdiff-out/mspaint-modules.csv`). Headless: off-screen
  hidden `AppWindow`, arms `InputNonClientPointerSource`, dwells ~3 s, exits.
  `build.cmd` = `dotnet publish -r win-x64` self-contained → `makeappx` pack →
  `signtool` sign; `AppxManifest.xml`, `New-Assets.ps1`, `New-DevCert.ps1`.
  **Builds clean; awaiting 268V hardware test.**
- `deploy/Install-ArcInputFixLifted.ps1` — registers the Lifted MSIX + hidden At-logon
  task via its alias (`...\WindowsApps\ArcInputFixLifted.exe`). `-Uninstall` / `-DevCert`.
  **Round 16: this scheduled-task launch is proven NOT to re-arm the bug on 268V — kept
  only as a documented dead-end; use `Install-ArcInputFixLifted-Shell.ps1` instead.**
- `deploy/Install-ArcInputFixLifted-Shell.ps1` — installs the Lifted helper so the
  **interactive shell launches it at logon** (Startup-folder shortcut by default, or a
  `Run`-key value; `-Scope AllUsers` uses HKLM `Run` + a provisioned package). This is
  the Round-16 fix for the launch-context finding — use this instead of the scheduled
  task, which is proven not to re-arm the bug. `-Uninstall` / `-DevCert`.
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

**BREAKTHROUGH (Round 16) — the launch context is the trigger.** On 268V hardware,
`ArcInputFixLifted.exe` (the lifted-stack helper) launched by the At-logon **scheduled
task** (auto *and* `Start-ScheduledTask`) does **NOT** fix the bug, but **double-clicking
the same alias in File Explorer DOES.** So the helper binary + its lifted `Microsoft.UI.*`
stack are correct; the missing ingredient is that the fix must be **launched by the
interactive shell (`explorer.exe`) in the user's interactive logon session**, not spawned
by the Task Scheduler service host. This resolves the earlier paradox (broker activation
fixed it from `powershell.exe` but not from a service-spawned Win32 exe): the
differentiator was always interactive-shell launch context.

**Do NOT** go back to launching the helper from a plain scheduled-task action — that
context is proven insufficient on this hardware. (`ArcInputFixWarmup`'s in-box warm-up is
still a dead-end too; the lifted stack in `ArcInputFixLifted` is the correct binary.)

Reproduce the working (double-click) context automatically at logon via mechanisms that
`explorer.exe` itself launches:
1. **DONE (built, awaiting 268V relogon test):** `deploy/Install-ArcInputFixLifted-Shell.ps1`
   installs a **Startup-folder shortcut** (default, current user) or a **`Run`-key value**
   to the alias. For the fleet, `-Scope AllUsers` writes `HKLM\...\Run` as `REG_EXPAND_SZ`
   `%LOCALAPPDATA%\Microsoft\WindowsApps\ArcInputFixLifted.exe` (resolves per-user) and
   provisions the MSIX for all users. Test: run it with `-DevCert`, **log off/on**, and
   confirm Clarion is already fixed before touching anything (no flash, persists).
2. **If the logon test passes:** sign `ArcInputFixLifted` with a real cert (`SIGN_PFX`),
   roll out via `-Scope AllUsers`, and ship it as the Paint-independent deliverable; keep
   `ArcInputFix.exe` (Paint-alias) as the fallback.
3. **If it still fails at logon but the manual double-click works:** the trigger is
   narrower than "explorer-launched" — diff the working double-click vs the Startup/Run
   launch with Procmon (parent process / token / window-station / activation context).

Fallbacks if Startup/Run is blocked: a scheduled task that **delegates** the launch to
the running `explorer.exe` (`explorer.exe <path>` relaunch / `IShellDispatch` from the
running shell), or a GPO user logon script in the interactive context.

Current ship stays the proven Paint-alias `ArcInputFix.exe` (64-bit) / `start_mspaint.ps1`
until the shell-launch test passes.

**Diagnostic data already captured** (`tools/Capture-Modules.ps1` was run on the Dell):
the outputs live in `tools/fixdiff-out/` — `mspaint-modules.csv` (Paint's loaded DLLs),
`mspaint-children.csv` (empty: Paint is in-process), and `services|processes|drivers-{before,during,after}.csv`.
The module capture's differentiator (real Paint loads the **lifted Windows App SDK 1.8
`Microsoft.UI.*` input/composition stack** — `Microsoft.UI.Input.dll`,
`Microsoft.InputStateManager.dll`, `Microsoft.UI.Windowing.dll`,
`Microsoft.UI.Composition.OSSupport.dll`, `Microsoft.Internal.FrameworkUdk.dll`, plus
`CoreMessagingXP.dll` / `dcompi.dll` / `dwmcorei.dll` / `wuceffectsi.dll`) is already
baked into `ArcInputFixLifted` — keep it as the binary; only the launch context changes.
