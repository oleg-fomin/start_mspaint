// ArcInputFix - hidden logon utility to work around the Intel Arc (Core Ultra 7
// 268V / Lunar Lake) non-client-mouse bug on Windows 11, where Clarion MDI child
// windows stop responding to caption-drag / border-resize until some GUI app
// (e.g. mspaint) is run once per session.
//
// This is a GUI-subsystem exe (no console window). It performs ONE of several
// candidate "warm-up" actions that reproduce what mspaint does, then exits.
//
// Each action maps to a root-cause hypothesis from the Phase 1 investigation:
//   (default / --pointer-dm)  in-process input warm-up: EnableMouseInPointer +
//                             DirectManipulationManager instantiation + DWM flush.
//   --service <name>          start a demand-start service that logon missed.
//   --mspaint                 fallback: launch mspaint hidden, brief wait, kill.
//
// Once Invoke-FixDiff.ps1 / Capture-Modules.ps1 identify the real trigger on the
// affected hardware, make that the default action and drop the others.
//
// Build: see build.cmd (MSVC, /SUBSYSTEM:WINDOWS, static CRT /MT, x64).

#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif

#include <windows.h>
#include <shellapi.h>
#include <shobjidl_core.h>      // IApplicationActivationManager (packaged Paint)
#include <objbase.h>
#include <tlhelp32.h>           // process enumeration (find Paint by image name)
#include <dwmapi.h>
#include <d3d11.h>
#include <dxgi.h>
#include <dcomp.h>
#include <gdiplus.h>
#include <roapi.h>
#include <winstring.h>
#include <windows.ui.composition.interop.h>   // ICompositorDesktopInterop
#include <winrt/base.h>
#include <winrt/Windows.UI.h>
#include <winrt/Windows.UI.Composition.h>
#include <winrt/Windows.UI.Composition.Desktop.h>
#include <string>
#include <vector>

#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "user32.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "dwmapi.lib")
#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "dcomp.lib")
#pragma comment(lib, "gdiplus.lib")
#pragma comment(lib, "windowsapp.lib")    // WinRT C API + C++/WinRT (RoActivate, WindowsCreateString, ...)

// Module instance, captured in wWinMain - used to create warm-up windows.
static HINSTANCE g_hInst = nullptr;

// Minimal layout-compatible mirror of DispatcherQueueOptions / its enums from
// <dispatcherqueue.h>, so we can call CreateDispatcherQueueController (exported
// by CoreMessaging.dll) without dragging in the full WinRT ABI headers.
struct ArcDispatcherQueueOptions {
    DWORD dwSize;
    int   threadType;       // DQTYPE_THREAD_CURRENT = 2
    int   apartmentType;    // DQTAT_COM_STA = 2
};
typedef HRESULT (WINAPI* PFN_CreateDispatcherQueueController)(
    ArcDispatcherQueueOptions, IUnknown**);

// CLSID_DirectManipulationManager. Instantiating it loads ninput.dll and
// initializes the Direct Manipulation / pointer subsystem - the path most
// likely involved in non-client mouse handling. We bind to IUnknown only so we
// need no DirectManipulation SDK headers.
static const CLSID kCLSID_DirectManipulationManager =
    { 0x54e211b6, 0x3650, 0x4f75, { 0x83, 0x34, 0xfa, 0x35, 0x95, 0x98, 0xe1, 0xc5 } };

// CLSID_ApplicationActivationManager - the documented way to launch a packaged
// (MSIX/UWP) app, used because classic mspaint.exe is absent on this hardware
// (Windows 11 25H2 ships Paint only as a packaged WinUI 3 app). The interface
// IApplicationActivationManager comes from <shobjidl_core.h>.
static const CLSID kCLSID_ApplicationActivationManager =
    { 0x45ba127d, 0x10a8, 0x46ea, { 0x8a, 0xb7, 0x56, 0xea, 0x90, 0x78, 0x94, 0x3c } };

// AppUserModelId of packaged Paint (same id the proven start_mspaint.ps1 uses).
static const wchar_t* kPaintAumid = L"Microsoft.Paint_8wekyb3d8bbwe!App";

// EnableMouseInPointer is resolved dynamically so the exe still loads on the off
// chance it is unavailable.
typedef BOOL (WINAPI *PFN_EnableMouseInPointer)(BOOL);

// --------------------------------------------------------------------------
// Logging - one line to the Windows Application event log (source ArcInputFix),
// so fleet machines are diagnosable without a console.
// --------------------------------------------------------------------------
static void LogEvent(WORD type, const std::wstring& message)
{
    HANDLE src = RegisterEventSourceW(nullptr, L"ArcInputFix");
    if (!src) return;
    LPCWSTR strings[1] = { message.c_str() };
    ReportEventW(src, type, 0, 0, nullptr, 1, 0, strings, nullptr);
    DeregisterEventSource(src);
    OutputDebugStringW((L"[ArcInputFix] " + message + L"\n").c_str());
}

// --------------------------------------------------------------------------
// Action: in-process input subsystem warm-up (default candidate).
// --------------------------------------------------------------------------
static bool DoPointerDmWarmup()
{
    bool anyOk = false;

    // 1) Mouse-in-pointer: routes legacy mouse through the WM_POINTER stack,
    //    forcing it to initialize for this session.
    if (HMODULE user32 = GetModuleHandleW(L"user32.dll")) {
        if (auto fn = reinterpret_cast<PFN_EnableMouseInPointer>(
                GetProcAddress(user32, "EnableMouseInPointer"))) {
            if (fn(TRUE)) anyOk = true;
        }
    }

    // 2) Direct Manipulation manager: loads ninput.dll and spins up the
    //    DM/pointer infrastructure, then releases it.
    HRESULT hrInit = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    if (SUCCEEDED(hrInit)) {
        IUnknown* dm = nullptr;
        HRESULT hr = CoCreateInstance(kCLSID_DirectManipulationManager, nullptr,
                                      CLSCTX_INPROC_SERVER, IID_IUnknown,
                                      reinterpret_cast<void**>(&dm));
        if (SUCCEEDED(hr) && dm) {
            Sleep(200);          // let the subsystem settle
            dm->Release();
            anyOk = true;
        }
        CoUninitialize();
    }

    // 3) Nudge DWM composition.
    BOOL composed = FALSE;
    if (SUCCEEDED(DwmIsCompositionEnabled(&composed)) && composed) {
        DwmFlush();
    }

    return anyOk;
}

// --------------------------------------------------------------------------
// Shared: a real (off-screen) top-level window. Unlike HWND_MESSAGE windows,
// this gets a DWM frame + composition, which is what exercises the non-client
// hit-test / compositor path that the bug affects.
// --------------------------------------------------------------------------
static const wchar_t* kWarmupClass = L"ArcInputFixWarmupWindow";

static LRESULT CALLBACK WarmupWndProc(HWND h, UINT m, WPARAM w, LPARAM l)
{
    return DefWindowProcW(h, m, w, l);
}

static bool EnsureWarmupClass()
{
    static bool registered = false;
    if (registered) return true;
    WNDCLASSW wc{};
    wc.lpfnWndProc   = WarmupWndProc;
    wc.hInstance     = g_hInst;
    wc.lpszClassName = kWarmupClass;
    if (!RegisterClassW(&wc) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS)
        return false;
    registered = true;
    return true;
}

static HWND CreateWarmupWindow()
{
    if (!EnsureWarmupClass()) return nullptr;
    // Off-screen position keeps it invisible while still being a composed,
    // NC-framed top-level window.
    return CreateWindowExW(WS_EX_TOOLWINDOW, kWarmupClass, L"ArcInputFix",
                           WS_OVERLAPPEDWINDOW, -32000, -32000, 320, 240,
                           nullptr, nullptr, g_hInst, nullptr);
}

static void PumpMessages(DWORD ms)
{
    DWORD start = GetTickCount();
    MSG msg;
    while (GetTickCount() - start < ms) {
        while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        Sleep(10);
    }
}

// --------------------------------------------------------------------------
// Action: create a real composed top-level window, force it through the DWM
// frame / NC path, pump messages, destroy.
// --------------------------------------------------------------------------
static bool DoWindowWarmup()
{
    HWND h = CreateWarmupWindow();
    if (!h) return false;
    ShowWindow(h, SW_SHOWNA);
    MARGINS frame{ -1, -1, -1, -1 };
    DwmExtendFrameIntoClientArea(h, &frame);
    PumpMessages(300);
    DestroyWindow(h);
    return true;
}

// --------------------------------------------------------------------------
// Action: create a REAL on-screen window, bring it to the FOREGROUND and keep
// it active (composed on a monitor) for ~1.5s, then close - mimicking what
// mspaint actually does window-wise. The window is fully transparent (layered,
// alpha 0) and 1x1 so it is invisible to the user. This is the main ingredient
// the off-screen --window action did not exercise.
// --------------------------------------------------------------------------
static bool DoForegroundWarmup()
{
    if (!EnsureWarmupClass()) return false;
    HWND h = CreateWindowExW(WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_TOPMOST,
                             kWarmupClass, L"ArcInputFix",
                             WS_OVERLAPPEDWINDOW, 0, 0, 1, 1,
                             nullptr, nullptr, g_hInst, nullptr);
    if (!h) return false;

    SetLayeredWindowAttributes(h, 0, 0, LWA_ALPHA);   // fully transparent
    ShowWindow(h, SW_SHOW);
    SetForegroundWindow(h);
    SetActiveWindow(h);
    SetFocus(h);
    PumpMessages(1500);
    DestroyWindow(h);
    return true;
}

// --------------------------------------------------------------------------
// Action: create a Direct3D11 hardware device + flip-model DXGI swap chain on
// the Intel Arc GPU and present a couple of frames. This warms up the GPU /
// compositor path - a strong candidate for the per-session driver state reset.
// --------------------------------------------------------------------------
static bool DoD3DWarmup()
{
    HWND h = CreateWarmupWindow();
    if (!h) return false;
    ShowWindow(h, SW_SHOWNA);

    DXGI_SWAP_CHAIN_DESC scd{};
    scd.BufferCount        = 2;
    scd.BufferDesc.Width   = 320;
    scd.BufferDesc.Height  = 240;
    scd.BufferDesc.Format  = DXGI_FORMAT_B8G8R8A8_UNORM;
    scd.BufferUsage        = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    scd.OutputWindow       = h;
    scd.SampleDesc.Count   = 1;
    scd.Windowed           = TRUE;
    scd.SwapEffect         = DXGI_SWAP_EFFECT_FLIP_DISCARD;

    ID3D11Device*        dev = nullptr;
    ID3D11DeviceContext* ctx = nullptr;
    IDXGISwapChain*      sc  = nullptr;
    D3D_FEATURE_LEVEL    fl  = D3D_FEATURE_LEVEL_11_0;

    HRESULT hr = D3D11CreateDeviceAndSwapChain(
        nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, 0, nullptr, 0,
        D3D11_SDK_VERSION, &scd, &sc, &dev, &fl, &ctx);

    bool ok = false;
    if (SUCCEEDED(hr)) {
        if (sc) { sc->Present(1, 0); sc->Present(1, 0); }
        PumpMessages(100);
        ok = true;
    } else {
        wchar_t buf[64];
        swprintf_s(buf, L"0x%08X", static_cast<unsigned>(hr));
        LogEvent(EVENTLOG_WARNING_TYPE,
                 std::wstring(L"D3D11CreateDeviceAndSwapChain failed: ") + buf);
    }
    if (ctx) ctx->Release();
    if (dev) dev->Release();
    if (sc)  sc->Release();
    DestroyWindow(h);
    return ok;
}

// --------------------------------------------------------------------------
// Action: create a DirectComposition device + target + visual and commit,
// warming up the DComp compositor for the session.
// --------------------------------------------------------------------------
static bool DoDCompWarmup()
{
    HWND h = CreateWarmupWindow();
    if (!h) return false;
    ShowWindow(h, SW_SHOWNA);

    if (FAILED(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED))) {
        DestroyWindow(h);
        return false;
    }

    bool ok = false;
    IDCompositionDevice* dcdev = nullptr;
    HRESULT hr = DCompositionCreateDevice(
        nullptr, __uuidof(IDCompositionDevice), reinterpret_cast<void**>(&dcdev));
    if (SUCCEEDED(hr) && dcdev) {
        IDCompositionTarget* target = nullptr;
        if (SUCCEEDED(dcdev->CreateTargetForHwnd(h, TRUE, &target)) && target) {
            IDCompositionVisual* visual = nullptr;
            if (SUCCEEDED(dcdev->CreateVisual(&visual)) && visual) {
                target->SetRoot(visual);
                dcdev->Commit();
                PumpMessages(100);
                ok = true;
                visual->Release();
            }
            target->Release();
        }
        dcdev->Release();
    }
    CoUninitialize();
    DestroyWindow(h);
    return ok;
}

// --------------------------------------------------------------------------
// Action: initialize GDI+ and do a trivial draw (classic mspaint is a GDI+
// app). Cheapest of the graphics candidates.
// --------------------------------------------------------------------------
static bool DoGdiplusWarmup()
{
    Gdiplus::GdiplusStartupInput input;
    ULONG_PTR token = 0;
    if (Gdiplus::GdiplusStartup(&token, &input, nullptr) != Gdiplus::Ok)
        return false;
    {
        Gdiplus::Bitmap   bmp(64, 64, PixelFormat32bppARGB);
        Gdiplus::Graphics gfx(&bmp);
        Gdiplus::SolidBrush brush(Gdiplus::Color(255, 0, 120, 215));
        gfx.FillRectangle(&brush, 0, 0, 64, 64);
        gfx.Flush();
    }
    Gdiplus::GdiplusShutdown(token);
    return true;
}

// --------------------------------------------------------------------------
// Action: initialize the MODERN "lifted" input/composition stack the way a
// WinUI 3 / Windows App SDK app (like Paint on this hardware) does:
//   1) CreateDispatcherQueueController -> loads CoreMessaging.dll + InputHost.
//   2) Activate Windows.UI.Composition.Compositor -> loads Windows.UI +
//      composition + the lifted input pipeline.
// This is the path none of the legacy warm-ups (pointer-dm/dcomp/d3d) touched,
// and the module capture shows it is exactly what Paint pulls in.
// --------------------------------------------------------------------------
static bool DoCoreMsgWarmup()
{
    bool roInit = SUCCEEDED(RoInitialize(RO_INIT_SINGLETHREADED));
    bool ok = false;

    // 1) Modern dispatcher queue on this thread (CoreMessaging + InputHost).
    IUnknown* dispatcherController = nullptr;
    if (HMODULE cm = LoadLibraryW(L"CoreMessaging.dll")) {
        auto create = reinterpret_cast<PFN_CreateDispatcherQueueController>(
            GetProcAddress(cm, "CreateDispatcherQueueController"));
        if (create) {
            ArcDispatcherQueueOptions opt{ sizeof(ArcDispatcherQueueOptions), 2, 2 };
            if (SUCCEEDED(create(opt, &dispatcherController)) && dispatcherController)
                ok = true;
        }
    }

    // 2) Windows.UI.Composition.Compositor (lifted composition + input).
    HSTRING clsId = nullptr;
    const wchar_t* name = L"Windows.UI.Composition.Compositor";
    IInspectable* compositor = nullptr;
    if (SUCCEEDED(WindowsCreateString(name, static_cast<UINT32>(wcslen(name)), &clsId))) {
        if (SUCCEEDED(RoActivateInstance(clsId, &compositor)) && compositor)
            ok = true;
        WindowsDeleteString(clsId);
    }

    // Let the dispatcher/compositor settle and process startup work.
    PumpMessages(1000);

    if (compositor)           compositor->Release();
    if (dispatcherController)  dispatcherController->Release();
    if (roInit)                RoUninitialize();
    return ok;
}

// --------------------------------------------------------------------------
// Action: REAL lifted-composition RENDER init (beyond mere object creation).
//
// --coremsg only *constructed* a DispatcherQueue + Compositor. This action goes
// the whole way a WinUI 3 app does: it binds the lifted Windows.UI.Composition
// Compositor to a real top-level HWND via ICompositorDesktopInterop
// (CreateDesktopWindowTarget), builds a visual tree (a SpriteVisual with a
// color brush) as the target Root, and then pumps frames so the compositor
// actually composes and presents through DWM + the input host. That presenting
// step - not object creation - is what we believe re-arms the non-client input
// path on the affected Intel Arc session.
//
// Implemented with C++/WinRT for the composition tree; the DispatcherQueue is
// created with the CoreMessaging.dll C entry point because the Compositor
// requires a DispatcherQueue on the current thread before construction.
// --------------------------------------------------------------------------
static bool DoRenderWarmup()
{
    bool ok = false;
    HWND hwnd = nullptr;
    IUnknown* dispatcherController = nullptr;

    // Compositor construction needs a DispatcherQueue on this thread.
    if (HMODULE cm = LoadLibraryW(L"CoreMessaging.dll")) {
        if (auto create = reinterpret_cast<PFN_CreateDispatcherQueueController>(
                GetProcAddress(cm, "CreateDispatcherQueueController"))) {
            ArcDispatcherQueueOptions opt{ sizeof(ArcDispatcherQueueOptions), 2, 2 };
            create(opt, &dispatcherController);
        }
    }

    try {
        winrt::init_apartment(winrt::apartment_type::single_threaded);

        // A real composed, NC-framed top-level window to host the visual tree.
        // It is off-screen (CreateWarmupWindow) so the user never sees it.
        hwnd = CreateWarmupWindow();
        if (hwnd) {
            ShowWindow(hwnd, SW_SHOWNA);

            namespace wuc = winrt::Windows::UI::Composition;
            namespace abi = ABI::Windows::UI::Composition::Desktop;

            wuc::Compositor compositor{};

            // Bind the lifted compositor to the HWND (the desktop-interop path).
            auto interop = compositor.as<abi::ICompositorDesktopInterop>();
            wuc::Desktop::DesktopWindowTarget target{ nullptr };
            winrt::check_hresult(interop->CreateDesktopWindowTarget(
                hwnd, false,
                reinterpret_cast<abi::IDesktopWindowTarget**>(winrt::put_abi(target))));

            // Build and attach a real visual tree, then present.
            auto root = compositor.CreateSpriteVisual();
            root.RelativeSizeAdjustment({ 1.0f, 1.0f });
            root.Brush(compositor.CreateColorBrush(
                winrt::Windows::UI::Colors::CornflowerBlue()));
            target.Root(root);

            // Drive frames so the compositor actually composes/presents this
            // session (the DispatcherQueue commits while we pump messages).
            PumpMessages(1500);
            BOOL composed = FALSE;
            if (SUCCEEDED(DwmIsCompositionEnabled(&composed)) && composed)
                DwmFlush();

            ok = true;
        }
    } catch (winrt::hresult_error const& e) {
        LogEvent(EVENTLOG_ERROR_TYPE,
                 L"render warm-up failed: hr=0x" +
                 std::to_wstring(static_cast<uint32_t>(e.code())));
    }

    if (hwnd) DestroyWindow(hwnd);
    if (dispatcherController) dispatcherController->Release();
    // Apartment is left initialized; the process exits immediately after.
    return ok;
}
static bool DoStartService(const std::wstring& name)
{
    SC_HANDLE scm = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
    if (!scm) {
        LogEvent(EVENTLOG_ERROR_TYPE, L"OpenSCManager failed: " + std::to_wstring(GetLastError()));
        return false;
    }

    bool ok = false;
    SC_HANDLE svc = OpenServiceW(scm, name.c_str(),
                                 SERVICE_START | SERVICE_QUERY_STATUS);
    if (svc) {
        SERVICE_STATUS st{};
        if (QueryServiceStatus(svc, &st) && st.dwCurrentState == SERVICE_RUNNING) {
            ok = true; // already running - nothing to do
        } else if (StartServiceW(svc, 0, nullptr) ||
                   GetLastError() == ERROR_SERVICE_ALREADY_RUNNING) {
            // Wait briefly for it to reach Running.
            for (int i = 0; i < 50; ++i) {
                if (QueryServiceStatus(svc, &st) && st.dwCurrentState == SERVICE_RUNNING) {
                    ok = true;
                    break;
                }
                Sleep(100);
            }
        } else {
            LogEvent(EVENTLOG_ERROR_TYPE,
                     L"StartService '" + name + L"' failed: " + std::to_wstring(GetLastError()));
        }
        CloseServiceHandle(svc);
    } else {
        LogEvent(EVENTLOG_ERROR_TYPE,
                 L"OpenService '" + name + L"' failed: " + std::to_wstring(GetLastError()));
    }

    CloseServiceHandle(scm);
    return ok;
}

// --------------------------------------------------------------------------
// Action: fallback - run Paint briefly (the original proven workaround).
// Prefers classic mspaint.exe; if it is absent (Windows 11 25H2 ships Paint
// only as a packaged WinUI 3 app) it activates packaged Paint via
// IApplicationActivationManager - the documented "CreateProcess equivalent"
// for MSIX apps (raw CreateProcess fails with ERROR_INVALID_NAME / 123).
//
// IMPORTANT: faithfully replicate what the PROVEN start_mspaint.ps1 does, since
// a naive "activate + Sleep(5s) + kill" did NOT fix the session even though the
// PS script (same activation) does. The two things the PS host did that a blind
// sleep missed:
//   1) WAIT for Paint's top-level window to actually appear (poll EnumWindows),
//      i.e. let Paint reach its interactive/composed state before timing starts.
//   2) Run inside an STA that PUMPS messages during the wait. We therefore pump
//      (PumpMessages) rather than Sleep, and dwell well past the PS timing so
//      Paint completes whatever session-wide input/composition init re-arms the
//      non-client mouse path, then terminate it.
// --------------------------------------------------------------------------
struct PaintWindowSearch {
    DWORD pid;
    bool  hidden;
};

static BOOL CALLBACK FindAndHidePaintWnd(HWND hwnd, LPARAM lp)
{
    auto* s = reinterpret_cast<PaintWindowSearch*>(lp);
    DWORD wpid = 0;
    GetWindowThreadProcessId(hwnd, &wpid);
    if (wpid == s->pid && IsWindowVisible(hwnd)) {
        ShowWindow(hwnd, SW_HIDE);   // same best-effort hide as start_mspaint.ps1
        s->hidden = true;
        return FALSE;                // stop enumerating
    }
    return TRUE;
}

static bool HideWindowsOfPid(DWORD pid)
{
    PaintWindowSearch s{ pid, false };
    EnumWindows(FindAndHidePaintWnd, reinterpret_cast<LPARAM>(&s));
    return s.hidden;
}

// Collect PIDs of all processes whose image name matches exeName (case-insens.).
static void CollectPidsByName(const wchar_t* exeName, std::vector<DWORD>& out)
{
    HANDLE snap = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snap == INVALID_HANDLE_VALUE) return;
    PROCESSENTRY32W pe{};
    pe.dwSize = sizeof(pe);
    if (Process32FirstW(snap, &pe)) {
        do {
            if (_wcsicmp(pe.szExeFile, exeName) == 0)
                out.push_back(pe.th32ProcessID);
        } while (Process32NextW(snap, &pe));
    }
    CloseHandle(snap);
}

// Image names packaged / classic Paint may run under.
static const wchar_t* const kPaintProcNames[] = {
    L"mspaint.exe", L"PaintApp.exe", L"Paint.exe"
};

// --------------------------------------------------------------------------
// PRIMARY fallback: launch Paint via its App Execution Alias - exactly what
// typing "mspaint" in a prompt does. The alias
// (%LOCALAPPDATA%\Microsoft\WindowsApps\mspaint.exe) is a reparse point that
// launches packaged Paint WITH package identity directly in the user's
// interactive context - a different path than IApplicationActivationManager
// (which goes through the DCOM activation broker). The user verified the alias
// launch fixes the session while broker activation did not, so we replicate it:
//   create process via the alias -> find the real Paint PID(s) by image name
//   -> hide their windows -> dwell (pumping) -> terminate.
// --------------------------------------------------------------------------
static bool LaunchPaintViaAlias()
{
    // Resolve the alias path; fall back to a bare PATH search ("mspaint.exe"),
    // since %LOCALAPPDATA%\Microsoft\WindowsApps is on the user's PATH.
    std::wstring cmdline = L"mspaint.exe";
    wchar_t localApp[MAX_PATH];
    DWORD n = GetEnvironmentVariableW(L"LOCALAPPDATA", localApp, MAX_PATH);
    if (n > 0 && n < MAX_PATH) {
        std::wstring aliasPath =
            std::wstring(localApp) + L"\\Microsoft\\WindowsApps\\mspaint.exe";
        if (GetFileAttributesW(aliasPath.c_str()) != INVALID_FILE_ATTRIBUTES)
            cmdline = L"\"" + aliasPath + L"\"";
    }

    // Snapshot existing Paint PIDs so we can tell which are newly spawned.
    std::vector<DWORD> before;
    for (auto* nm : kPaintProcNames) CollectPidsByName(nm, before);
    auto inBefore = [&](DWORD p) {
        for (DWORD b : before) if (b == p) return true;
        return false;
    };

    // Launch the alias with STARTF_USESHOWWINDOW + SW_HIDE so Paint's window is
    // requested hidden from the start (the post-launch EnumWindows hide remains
    // as a fallback, since a packaged app may ignore the show-window hint). Use
    // a guaranteed-valid working dir to avoid ERROR_INVALID_NAME (123).
    wchar_t sysDir[MAX_PATH];
    if (!GetSystemDirectoryW(sysDir, MAX_PATH)) sysDir[0] = L'\0';

    STARTUPINFOW si{};
    si.cb = sizeof(si);
    si.dwFlags     = STARTF_USESHOWWINDOW;
    si.wShowWindow = SW_HIDE;
    PROCESS_INFORMATION pi{};
    std::vector<wchar_t> buf(cmdline.begin(), cmdline.end());
    buf.push_back(L'\0');

    if (!CreateProcessW(nullptr, buf.data(), nullptr, nullptr, FALSE,
                        0, nullptr, sysDir[0] ? sysDir : nullptr, &si, &pi)) {
        LogEvent(EVENTLOG_ERROR_TYPE,
                 L"CreateProcess(mspaint alias) failed: " +
                 std::to_wstring(GetLastError()));
        return false;
    }

    // Build the set of target PIDs: the one we launched plus any new Paint
    // processes that appear (the alias may spawn the real app under another PID).
    std::vector<DWORD> targets;
    if (pi.dwProcessId) targets.push_back(pi.dwProcessId);
    auto addTarget = [&](DWORD p) {
        for (DWORD t : targets) if (t == p) return;
        targets.push_back(p);
    };

    // Wait (pumping messages) for Paint's window to appear, then hide it.
    bool hidAny = false;
    for (int i = 0; i < 50; ++i) {                 // up to ~10s
        std::vector<DWORD> now;
        for (auto* nm : kPaintProcNames) CollectPidsByName(nm, now);
        for (DWORD p : now) if (!inBefore(p)) addTarget(p);

        for (DWORD t : targets) if (HideWindowsOfPid(t)) hidAny = true;
        if (hidAny) break;
        PumpMessages(200);
    }

    // Dwell while pumping so Paint completes the session-wide init that re-arms
    // the non-client input path, then terminate every target.
    PumpMessages(8000);

    for (DWORD t : targets) {
        if (HANDLE th = OpenProcess(PROCESS_TERMINATE, FALSE, t)) {
            TerminateProcess(th, 0);
            CloseHandle(th);
        }
    }
    if (pi.hThread)  CloseHandle(pi.hThread);
    if (pi.hProcess) CloseHandle(pi.hProcess);
    return true;
}

static bool LaunchPackagedPaint()
{
    bool comInit = SUCCEEDED(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED));
    bool ok = false;

    IApplicationActivationManager* mgr = nullptr;
    HRESULT hr = CoCreateInstance(kCLSID_ApplicationActivationManager, nullptr,
                                  CLSCTX_LOCAL_SERVER, IID_PPV_ARGS(&mgr));
    if (SUCCEEDED(hr) && mgr) {
        DWORD pid = 0;
        hr = mgr->ActivateApplication(kPaintAumid, nullptr, AO_NOERRORUI, &pid);
        if (SUCCEEDED(hr) && pid) {
            // Turn the returned PID into a handle so we can terminate it later,
            // the same way the proven start_mspaint.ps1 does.
            HANDLE h = OpenProcess(PROCESS_TERMINATE | SYNCHRONIZE, FALSE, pid);

            // 1) Wait (pumping messages) for Paint's window to appear, then hide
            //    it - this is what the PS script does and what proves Paint has
            //    reached its interactive state.
            PaintWindowSearch search{ pid, false };
            for (int i = 0; i < 50 && !search.hidden; ++i) {   // up to ~10s
                EnumWindows(FindAndHidePaintWnd,
                            reinterpret_cast<LPARAM>(&search));
                if (search.hidden) break;
                PumpMessages(200);
            }

            // 2) Dwell while pumping messages so Paint finishes its session-wide
            //    init (longer than the PS script's post-window 5s, to be safe).
            PumpMessages(8000);

            if (h) {
                TerminateProcess(h, 0);
                CloseHandle(h);
            }
            ok = true;
        } else {
            LogEvent(EVENTLOG_ERROR_TYPE,
                     L"ActivateApplication(packaged Paint) failed: hr=0x" +
                     std::to_wstring(static_cast<uint32_t>(hr)));
        }
        mgr->Release();
    } else {
        LogEvent(EVENTLOG_ERROR_TYPE,
                 L"CoCreateInstance(ApplicationActivationManager) failed: hr=0x" +
                 std::to_wstring(static_cast<uint32_t>(hr)));
    }

    if (comInit) CoUninitialize();
    return ok;
}

static bool DoMspaintFallback()
{
    // PRIMARY: the App Execution Alias launch (what typing "mspaint" does) - the
    // user verified this fixes the session where broker activation did not.
    if (LaunchPaintViaAlias())
        return true;

    // Next: classic desktop Paint if it actually exists in System32.
    wchar_t sysDir[MAX_PATH];
    if (GetSystemDirectoryW(sysDir, MAX_PATH)) {
        std::wstring exe = std::wstring(sysDir) + L"\\mspaint.exe";
        if (GetFileAttributesW(exe.c_str()) != INVALID_FILE_ATTRIBUTES) {
            STARTUPINFOW si{};
            si.cb = sizeof(si);
            si.dwFlags = STARTF_USESHOWWINDOW;
            si.wShowWindow = SW_HIDE;

            PROCESS_INFORMATION pi{};
            std::wstring cmd = L"\"" + exe + L"\"";
            std::wstring dir(sysDir);

            if (CreateProcessW(exe.c_str(), &cmd[0], nullptr, nullptr, FALSE,
                               CREATE_NO_WINDOW, nullptr, dir.c_str(), &si, &pi)) {
                Sleep(5000);
                TerminateProcess(pi.hProcess, 0);
                CloseHandle(pi.hThread);
                CloseHandle(pi.hProcess);
                return true;
            }
            LogEvent(EVENTLOG_ERROR_TYPE,
                     L"CreateProcess(mspaint) failed: " + std::to_wstring(GetLastError()));
        }
    }

    // Last resort: packaged Paint via the activation broker.
    return LaunchPackagedPaint();
}

// --------------------------------------------------------------------------
// Entry point (GUI subsystem -> no console window).
// --------------------------------------------------------------------------
int WINAPI wWinMain(HINSTANCE hInstance, HINSTANCE, LPWSTR, int)
{
    g_hInst = hInstance;

    int argc = 0;
    LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);

    std::wstring action = L"pointer-dm"; // default candidate
    std::wstring serviceName;

    for (int i = 1; i < argc; ++i) {
        std::wstring a = argv[i];
        if (a == L"--pointer-dm") {
            action = L"pointer-dm";
        } else if (a == L"--window") {
            action = L"window";
        } else if (a == L"--foreground") {
            action = L"foreground";
        } else if (a == L"--d3d") {
            action = L"d3d";
        } else if (a == L"--dcomp") {
            action = L"dcomp";
        } else if (a == L"--gdiplus") {
            action = L"gdiplus";
        } else if (a == L"--coremsg") {
            action = L"coremsg";
        } else if (a == L"--render") {
            action = L"render";
        } else if (a == L"--all") {
            action = L"all";
        } else if (a == L"--mspaint") {
            action = L"mspaint";
        } else if (a == L"--service" && i + 1 < argc) {
            action = L"service";
            serviceName = argv[++i];
        }
    }
    if (argv) LocalFree(argv);

    bool ok = false;
    std::wstring what = action;
    if (action == L"service") {
        what = L"start-service " + serviceName;
        ok = DoStartService(serviceName);
    } else if (action == L"mspaint") {
        ok = DoMspaintFallback();
    } else if (action == L"window") {
        ok = DoWindowWarmup();
    } else if (action == L"foreground") {
        ok = DoForegroundWarmup();
    } else if (action == L"d3d") {
        ok = DoD3DWarmup();
    } else if (action == L"dcomp") {
        ok = DoDCompWarmup();
    } else if (action == L"gdiplus") {
        ok = DoGdiplusWarmup();
    } else if (action == L"coremsg") {
        ok = DoCoreMsgWarmup();
    } else if (action == L"render") {
        ok = DoRenderWarmup();
    } else if (action == L"all") {
        // Run every warm-up in sequence; success if any one succeeds. Use this
        // to confirm SOME combination fixes it, then bisect with single flags.
        bool a1 = DoGdiplusWarmup();
        bool a2 = DoWindowWarmup();
        bool a3 = DoForegroundWarmup();
        bool a4 = DoDCompWarmup();
        bool a5 = DoD3DWarmup();
        bool a6 = DoPointerDmWarmup();
        bool a7 = DoCoreMsgWarmup();
        bool a8 = DoRenderWarmup();
        ok = a1 || a2 || a3 || a4 || a5 || a6 || a7 || a8;
    } else {
        ok = DoPointerDmWarmup();
    }

    LogEvent(ok ? EVENTLOG_INFORMATION_TYPE : EVENTLOG_WARNING_TYPE,
             L"ArcInputFix action '" + what + L"' " + (ok ? L"succeeded" : L"did not complete"));

    return ok ? 0 : 1;
}
