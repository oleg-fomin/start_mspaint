# Handoff brief — paste into a new Visual Studio Copilot chat

Copy everything between the rules below as your **first message** in the new Visual
Studio Copilot Chat. (The repo also has `.github/copilot-instructions.md`, which
Visual Studio loads automatically — this brief adds the immediate task.)

---

I'm continuing work from a VS Code Copilot session. Read
`.github/copilot-instructions.md` and these files first:
`src/ArcInputFix/ArcInputFix.cpp`, `start_mspaint.ps1`,
`deploy/Install-ArcInputFix.ps1`.

**Background (already solved):** On Dell Pro Plus laptops (Intel Core Ultra 7 268V /
Lunar Lake, Arc iGPU, Windows 11 25H2), Clarion MDI child windows lose ALL non-client
mouse input (caption drag, border resize, min/max/close buttons) each logon until a
**package-identity** GUI app is launched as a normal `CreateProcess` child in the
interactive session. The proven fix is launching packaged Paint via its **App
Execution Alias** (`%LOCALAPPDATA%\Microsoft\WindowsApps\mspaint.exe`). We ship that
today as `ArcInputFix.exe` (single-purpose, hidden, runs at logon via Task Scheduler).
The DCOM broker (`IApplicationActivationManager`) and all identity-less Win32 warm-ups
(pointer/DM, D3D, DComp, GDI+, off-screen/foreground windows, lifted-composition
render) do NOT fix it — don't re-suggest those.

**Goal for this Visual Studio session:** build an **owned, minimal MSIX-packaged
WinUI 3 / CoreWindow helper** that has its own package identity, briefly spins up the
modern WinUI 3 input + composition stack (CoreWindow / DispatcherQueue / Compositor),
then exits — so we no longer depend on Microsoft Paint being installed on the fleet.

**Constraints / facts:**
- Target: Windows 11 25H2, x64, Core Ultra 7 268V fleet (Dell Pro Plus).
- Must run hidden at logon (Task Scheduler, interactive user, least privilege), fast,
  no visible window if possible.
- Code signing will be required before fleet rollout (MSIX must be signed to register).
  Assume signing is being arranged; build so it's sign-ready.
- Keep the existing `ArcInputFix.exe` alias-launch fix as the fallback deliverable.
- `ICompositorDesktopInterop` / `IDesktopWindowTarget` are in namespace
  `ABI::Windows::UI::Composition::Desktop`.

**What I want you to do:**
1. Recommend the exact project type(s): WinUI 3 "Blank App, Packaged (WinUI 3 in
   Desktop)" vs a single-project MSIX vs a sparse package over the existing exe — and
   why, for a windowless/headless helper that just needs package identity + the input
   stack.
2. Scaffold it, set the package manifest (identity, App Execution Alias optional),
   and wire a minimal startup that initializes the CoreWindow/lifted-input +
   composition stack and exits cleanly.
3. Tell me how to test it from a fresh broken logon on the 268V hardware to confirm it
   re-arms non-client mouse input WITHOUT launching Paint, and how to register it at
   logon.

Validate by: from a fresh logon in the broken state, run the helper once → Clarion
caption drag, border resize, and min/max/close buttons all work, and stay working
until logoff, with no visible window flash.
