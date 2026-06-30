# Test & deploy the owned warm-up helper (ArcInputFixWarmup)
# Test the owned warm-up helper (ArcInputFixWarmup)

> **STATUS: TESTED ON 268V HARDWARE — DOES NOT FIX THE BUG.** One run of the signed,
> alias-launched helper did **not** re-arm Clarion caption drag / border resize /
> min-max-close. So package identity + the in-box composition/input warm-up is
> **necessary but not sufficient** — real packaged Paint does something more that this
> minimal helper does not. **Keep shipping the proven Paint-alias `ArcInputFix.exe`.**
> This document and the helper are retained as a documented dead-end and a base for the
> differential-diagnosis next step (see the bottom of this file).

`ArcInputFixWarmup` was the owned, **package-identity** attempt to stop depending on
Microsoft Paint. It is a windowless Win32 exe that spins up the same in-box stack a
packaged WinUI 3 app does — `CreateDispatcherQueueController` +
`Windows.UI.Composition.Compositor` + `ICompositorDesktopInterop` /
`IDesktopWindowTarget` on a hidden top-level window — then exits. The MSIX wrapper
(`runFullTrust` `Windows.FullTrustApplication` + an App Execution Alias) gives it package
identity, and the logon task launches it via that alias — the same
CreateProcess-with-identity path the Paint alias uses. It satisfies **all three**
necessary conditions of the deduced root-cause signature, yet on the 268V hardware it
still did not fix the session.

## Why this project shape (and not the alternatives)

| Option | Verdict |
| --- | --- |
| **WinUI 3 "Blank App, Packaged (WinUI 3 in Desktop)"** | Overkill. Pulls in the Windows App SDK runtime dependency, XAML, an `App`/`Window` you'd have to suppress, and a visible window to hide. We don't need XAML — only the **in-box** CoreMessaging + `Windows.UI.Composition` stack, which is present on every Windows 11 box with no redistributable. |
| **Single-project MSIX (packaged WinUI 3)** | Same SDK/XAML baggage as above; convenient in VS but heavier than required for a headless helper. |
| **Sparse package over an existing exe** | A sparse/external-location package still needs a signed identity *and* an `externalLocation` registration; it adds complexity without removing the real requirement (identity). |
| **? Plain GUI-subsystem Win32 exe + classic `AppxManifest.xml` MSIX (this project)** | Minimal. No Windows App SDK, no NuGet, static CRT, one `.cpp`. Gets **package identity** via the MSIX wrapper, and runs the exact in-box composition/input warm-up. Windowless, so no flash. Sign-ready. (Chosen as the smallest thing that supplies identity — but see the status banner: it was **not enough** on hardware.) |

The reasoning at build time was: the identity-less version of this warm-up did not fix
the session, so package identity must be the missing ingredient. **The 268V test
disproved that** — the helper has identity *and* the warm-up and still fails. The real
differentiator is something else packaged Paint does; it is not yet identified.

## Build (dev/test)

From a *x64 Native Tools Command Prompt for VS* (or let `build.cmd` import vcvars):

```cmd
cd src\ArcInputFixWarmup
build.cmd
```

`build.cmd` will:

1. Compile `ArcInputFixWarmup.exe` (`/W4 /O1 /EHsc /MT /std:c++17`, `/SUBSYSTEM:WINDOWS`).
2. Stage the package layout and generate placeholder logo assets (`New-Assets.ps1`).
3. `makeappx pack` ? `ArcInputFixWarmup.msix`.
4. Sign it. With no `SIGN_PFX` set it creates/reuses a **self-signed dev cert** whose
   subject matches the manifest `Publisher`, signs with it, and exports
   `ArcInputFixWarmup.cer` to trust on the test box.

## Build (release / sign-ready)

```cmd
set SIGN_PFX=C:\path\to\codesigning.pfx
set SIGN_PFX_PASSWORD=...                  & rem optional
build.cmd
```

Before a signed build, edit `AppxManifest.xml` so `Identity/Publisher` **exactly**
equals the certificate Subject (e.g. `CN=Contoso Ltd, O=Contoso Ltd, C=US`). The
package will not register if they differ. Keep `Identity/Name` + the cert stable across
the fleet so updates install in place.

## Reproduce the negative result from a fresh broken logon (268V hardware)

These are the steps that were run; they confirm the helper does **not** fix the bug. They
remain useful for re-validating after any change, or as the harness for the
differential-diagnosis next step.

1. **Reproduce the break.** Reboot and log in. Open the Clarion app and confirm an MDI
   child window is broken: caption **drag** does nothing, **border resize** does
   nothing, and the **min/max/close** caption buttons don't respond. (Do *not* run
   Paint — that would mask the test.)
2. **Trust the dev cert once** (only for self-signed dev builds), elevated:
   ```powershell
   Import-Certificate -FilePath .\src\ArcInputFixWarmup\ArcInputFixWarmup.cer `
       -CertStoreLocation Cert:\LocalMachine\TrustedPeople
   ```
3. **Install the package + logon task** (elevated):
   ```powershell
   .\deploy\Install-ArcInputFixWarmup.ps1 -DevCert .\src\ArcInputFixWarmup\ArcInputFixWarmup.cer
   ```
   (For a CA-signed release package, omit `-DevCert`.)
4. **Run it once now** (simulates the logon task firing):
   ```powershell
   Start-ScheduledTask -TaskName ArcInputFixWarmup
   ```
   Or launch the alias directly the way the task does — this is the proven path:
   ```powershell
   & "$env:LOCALAPPDATA\Microsoft\WindowsApps\ArcInputFixWarmup.exe"
   ```
5. **Verify the fix.** Back in the Clarion MDI child window confirm **all three** now
   work: caption drag moves the window, border resize works, and min/max/close
   respond. There must be **no visible window flash** from the helper.
6. **Confirm persistence.** Keep using the session; the fix must hold until logoff
   without re-running anything.
7. **Confirm the clean-logon path.** Log off and back on (the task is At-logon). Before
   touching anything else, confirm the Clarion window is *already* fixed, and check the
   result line in **Event Viewer ? Windows Logs ? Application**, source
   `ArcInputFixWarmup`.

### Expected outcome (observed on 268V)

The helper runs and exits cleanly (event-log line written, no visible window), but
Clarion caption drag, border resize, and min/max/close **stay broken**. Launching
packaged Paint (or the proven `ArcInputFix.exe`) in the same session still fixes it —
confirming the session was genuinely in the broken state and that Paint, not the helper,
carries the missing ingredient.

### Next step now that it failed: use the capture we already have

`tools/Capture-Modules.ps1` has **already been run on the Dell**; its output is in
`tools/fixdiff-out/`:

- `mspaint-modules.csv` — every DLL real packaged Paint loaded.
- `mspaint-children.csv` — empty (Paint is in-process; no child host process).
- `services-{before,during,after}.csv`, `processes-*.csv`, `drivers-*.csv` — state diffs
  around the Paint launch (the service deltas are Store-activation noise; see README
  Round 4).

That capture pins down a concrete differentiator. Real Paint loads the **lifted Windows
App SDK 1.8 `Microsoft.UI.*` input/composition stack**:

- `Microsoft.UI.Input.dll`, `Microsoft.InputStateManager.dll`
- `Microsoft.UI.Windowing.dll`, `Microsoft.UI.Windowing.Core.dll`
- `Microsoft.UI.Composition.OSSupport.dll`, `Microsoft.Internal.FrameworkUdk.dll`
- `CoreMessagingXP.dll`, `dcompi.dll`, `dwmcorei.dll`, `wuceffectsi.dll`

all from `Microsoft.WindowsAppRuntime.1.8`. **Our helper used only the in-box
`Windows.UI.Composition.Compositor`** (deliberately, to avoid a NuGet / Windows App SDK
dependency) and therefore never loaded the lifted `Microsoft.UI.Input` /
`InputStateManager` stack — the most likely missing ingredient.

So the next hypothesis to test (just one, not another blind warm-up): a package-identity
helper that initialises the **lifted Microsoft.UI input stack**. **That helper is now
built** — see `src/ArcInputFixLifted/` and the next section.

## ArcInputFixLifted — the lifted-stack helper (next hypothesis, awaiting 268V test)

`src/ArcInputFixLifted/` is a real **WinUI 3** (C#, Windows App SDK 1.8) helper. Being an
actual WinUI 3 app, it loads the **same lifted `Microsoft.UI.*` stack packaged Paint
does** (verified: the self-contained publish carries `Microsoft.UI.Input.dll`,
`Microsoft.InputStateManager.dll`, `Microsoft.UI.Windowing.dll`,
`Microsoft.UI.Composition.OSSupport.dll`, `Microsoft.Internal.FrameworkUdk.dll`,
`CoreMessagingXP.dll`, `dcompi.dll`, `dwmcorei.dll`, `wuceffectsi.dll`). On launch it
creates a WinUI 3 `Window` (off-screen, hidden via the lifted `AppWindow`), explicitly
arms the lifted **non-client** pointer input owner
(`InputNonClientPointerSource.GetForWindowId`) — the exact subsystem the bug disables —
dwells ~3 s, then exits. It is wrapped in a signed MSIX (same pack/sign pipeline as
`ArcInputFixWarmup`) for package identity and launched at logon via its App Execution
Alias.

This reverses the original "in-box only / no NuGet" choice — which is exactly why
`ArcInputFixWarmup` missed the lifted stack.

### Build

```cmd
cd src\ArcInputFixLifted
build.cmd
```

`build.cmd` runs `dotnet publish -c Release -r win-x64` (self-contained, so the lifted
runtime ships in the package — no fleet WindowsAppRuntime dependency), overlays
`AppxManifest.xml` + placeholder assets, `makeappx pack` -> `ArcInputFixLifted.msix`, and
signs it (self-signed dev cert by default; set `SIGN_PFX` for a release cert). For
release, make `AppxManifest.xml`'s `Identity/Publisher` match the cert subject exactly.

### Test on the 268V (fresh broken logon)

Identical procedure to the `ArcInputFixWarmup` steps above, with the Lifted names:

```powershell
# elevated, from the repo root
.\deploy\Install-ArcInputFixLifted.ps1 -DevCert .\src\ArcInputFixLifted\ArcInputFixLifted.cer
Start-ScheduledTask -TaskName ArcInputFixLifted
# or launch the alias directly:
& "$env:LOCALAPPDATA\Microsoft\WindowsApps\ArcInputFixLifted.exe"
```

Then check Clarion caption drag / border resize / min-max-close (and the Application
event log, source `ArcInputFixLifted`). Uninstall with
`.\deploy\Install-ArcInputFixLifted.ps1 -Uninstall`.

- **If it fixes the bug:** the lifted `Microsoft.UI.Input` stack was the missing
  ingredient. Get a real code-signing cert, rebuild with `SIGN_PFX`, and ship
  `ArcInputFixLifted` as the Paint-independent deliverable (keep `ArcInputFix.exe` as
  fallback).
- **If it does NOT:** even the full lifted stack under identity is insufficient; the
  differentiator is narrower (a specific Paint init call / device / broker). Capture a
  Procmon trace of a Paint-alias run (`tools/Capture-Modules.ps1 -WithProcmon`) and diff
  handle/registry/ALPC activity. Keep shipping `ArcInputFix.exe`.

## Roll out / fall back

- **Do NOT roll out `ArcInputFixWarmup`.** It was tested on the 268V hardware and does
  not fix the bug, so it is not a shippable deliverable.
- **Ship the proven fix:** `ArcInputFix.exe` (Paint-alias launch) / `start_mspaint.ps1`
  remain the confirmed-working deliverables. The helper stays in-repo only as a
  documented dead-end and a harness for the module-diff investigation above.

## Uninstall

```powershell
.\deploy\Install-ArcInputFixWarmup.ps1 -Uninstall
```

Removes the scheduled task and the registered package.
