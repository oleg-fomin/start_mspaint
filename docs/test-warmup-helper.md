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

### Next step now that it failed: differential diagnosis

Package identity + this in-box composition warm-up is insufficient; the differentiator
is something else packaged Paint does. From a fresh broken logon, capture a
module/handle/service diff of a **Paint-alias run** vs an **`ArcInputFixWarmup` run**
with `tools/Capture-Modules.ps1` (add `-WithProcmon` for a one-off Procmon trace) and
compare — look for a DLL/COM server/device/RPC-ALPC port/service that Paint touches and
the helper does not. Form a single hypothesis from the diff and test only that. Until a
concrete differentiator is found and validated, keep shipping the proven Paint-alias
`ArcInputFix.exe`.

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
