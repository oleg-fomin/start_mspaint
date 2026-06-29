// ArcInputFixWarmup - owned, package-identity logon helper that re-arms the
// Intel Arc (Core Ultra 7 268V / Lunar Lake) non-client-mouse path on Windows 11
// WITHOUT depending on Microsoft Paint being installed.
//
// Root cause (already proven elsewhere in this repo): Clarion MDI child windows
// lose ALL non-client mouse input (caption drag, border resize, min/max/close)
// each logon until SOME process that has ALL of the following runs once in the
// session:
//   1) PACKAGE IDENTITY,
//   2) launched as a normal CreateProcess child in the INTERACTIVE session,
//   3) that spins up the modern WinUI 3 / CoreWindow input + composition stack
//      (DispatcherQueue + Compositor + a desktop composition target).
//
// The identity-less version of (3) - CreateDispatcherQueueController +
// Windows.UI.Composition.Compositor + ICompositorDesktopInterop /
// DesktopWindowTarget - was already tried as a plain Win32 exe and did NOT fix
// the session. The ONLY thing it was missing was package identity. This exe runs
// the SAME in-box warm-up, but is shipped inside a signed MSIX (see
// AppxManifest.xml) and launched via its App Execution Alias, so it now runs with
// package identity in the interactive session - the proven trigger - and exits.
//
// It is windowless: the composition target is hosted on a hidden top-level window
// that is never shown (WS_POPUP, no WS_VISIBLE, WS_EX_TOOLWINDOW), so there is no
// visible window flash.
//
// Build: see build.cmd (MSVC, /SUBSYSTEM:WINDOWS, static CRT /MT, x64), which also
// packs and signs the MSIX. Deploy: deploy\Install-ArcInputFixWarmup.ps1.

#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif

#include <windows.h>
#include <roapi.h>                          // RoInitialize / RoActivateInstance
#include <winstring.h>                      // WindowsCreateString / ...Delete
#include <inspectable.h>                    // IInspectable
#include <wrl/client.h>                     // Microsoft::WRL::ComPtr
#include <dispatcherqueue.h>                // DispatcherQueueOptions / DQ* enums
#include <windows.system.h>                 // ABI::Windows::System::IDispatcherQueueController
#include <windows.ui.composition.h>         // ABI::Windows::UI::Composition::*
#include <windows.ui.composition.interop.h> // ICompositorDesktopInterop (Desktop ns)
#include <windows.ui.composition.desktop.h> // IDesktopWindowTarget (full definition)
#include <string>

#pragma comment(lib, "runtimeobject.lib")   // RoInitialize / WindowsCreateString
#pragma comment(lib, "advapi32.lib")        // event log
#pragma comment(lib, "user32.lib")

using Microsoft::WRL::ComPtr;
namespace WUC  = ABI::Windows::UI::Composition;
namespace WUCD = ABI::Windows::UI::Composition::Desktop;
namespace WSYS = ABI::Windows::System;

// CreateDispatcherQueueController lives in CoreMessaging.dll. We resolve it
// dynamically to avoid any import-library coupling.
using PFN_CreateDispatcherQueueController =
    HRESULT(WINAPI*)(DispatcherQueueOptions, WSYS::IDispatcherQueueController**);

// --------------------------------------------------------------------------
// Logging - one line to the Windows Application event log (source
// ArcInputFixWarmup) so fleet machines are diagnosable without a console.
// --------------------------------------------------------------------------
static void LogEvent(WORD type, const std::wstring& message)
{
    HANDLE src = RegisterEventSourceW(nullptr, L"ArcInputFixWarmup");
    if (src) {
        LPCWSTR strings[1] = { message.c_str() };
        ReportEventW(src, type, 0, 0, nullptr, 1, 0, strings, nullptr);
        DeregisterEventSource(src);
    }
    OutputDebugStringW((L"[ArcInputFixWarmup] " + message + L"\n").c_str());
}

static std::wstring HrStr(HRESULT hr)
{
    wchar_t buf[16];
    swprintf_s(buf, L"0x%08X", static_cast<unsigned>(hr));
    return buf;
}

// --------------------------------------------------------------------------
// Pump the STA / dispatcher queue for ms milliseconds so the composition stack
// commits its first frame and the input/composition subsystem finishes its
// session-wide initialisation, then we tear down.
// --------------------------------------------------------------------------
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
// A hidden top-level window to host the desktop composition target. It is never
// shown (no WS_VISIBLE, never ShowWindow'd) so there is no visible flash. A real
// top-level HWND is required - a message-only (HWND_MESSAGE) window cannot host a
// composition target.
// --------------------------------------------------------------------------
static HWND CreateHiddenHostWindow()
{
    static const wchar_t* kClass = L"ArcInputFixWarmupSink";
    HINSTANCE hInst = GetModuleHandleW(nullptr);

    WNDCLASSEXW wc{};
    wc.cbSize        = sizeof(wc);
    wc.lpfnWndProc   = DefWindowProcW;
    wc.hInstance     = hInst;
    wc.lpszClassName = kClass;
    RegisterClassExW(&wc);   // ignore "already registered"

    return CreateWindowExW(
        WS_EX_TOOLWINDOW | WS_EX_NOREDIRECTIONBITMAP,
        kClass, L"", WS_POPUP,
        0, 0, 1, 1,
        nullptr, nullptr, hInst, nullptr);
}

// --------------------------------------------------------------------------
// The warm-up: bring up the modern input + composition stack exactly as a
// packaged WinUI 3 app does, then exit. With package identity (supplied by the
// MSIX wrapper) this single run re-arms the non-client input path for the
// session.
// --------------------------------------------------------------------------
static bool WarmUpCompositionStack()
{
    // 1) A DispatcherQueue must exist on this thread before the Compositor can be
    //    created. Create one bound to the current (UI) thread.
    HMODULE coreMsg = LoadLibraryW(L"CoreMessaging.dll");
    if (!coreMsg) {
        LogEvent(EVENTLOG_ERROR_TYPE, L"LoadLibrary(CoreMessaging.dll) failed: " +
                 std::to_wstring(GetLastError()));
        return false;
    }
    auto pCreateDQC = reinterpret_cast<PFN_CreateDispatcherQueueController>(
        GetProcAddress(coreMsg, "CreateDispatcherQueueController"));
    if (!pCreateDQC) {
        LogEvent(EVENTLOG_ERROR_TYPE, L"GetProcAddress(CreateDispatcherQueueController) failed");
        FreeLibrary(coreMsg);
        return false;
    }

    DispatcherQueueOptions opts{};
    opts.dwSize        = sizeof(opts);
    opts.threadType    = DQTYPE_THREAD_CURRENT;
    opts.apartmentType = DQTAT_COM_NONE;   // COM already initialised (RoInitialize STA)

    ComPtr<WSYS::IDispatcherQueueController> dqController;
    HRESULT hr = pCreateDQC(opts, dqController.GetAddressOf());
    if (FAILED(hr)) {
        LogEvent(EVENTLOG_ERROR_TYPE, L"CreateDispatcherQueueController failed: " + HrStr(hr));
        FreeLibrary(coreMsg);
        return false;
    }

    // 2) Activate the in-box Compositor (Windows.UI.Composition) - the same
    //    composition engine WinUI 3 / packaged Paint spin up.
    const wchar_t* kCompositorClass = L"Windows.UI.Composition.Compositor";
    HSTRING hClass = nullptr;
    hr = WindowsCreateString(kCompositorClass,
                             static_cast<UINT32>(wcslen(kCompositorClass)), &hClass);
    if (FAILED(hr)) {
        LogEvent(EVENTLOG_ERROR_TYPE, L"WindowsCreateString failed: " + HrStr(hr));
        FreeLibrary(coreMsg);
        return false;
    }
    ComPtr<IInspectable> inspectable;
    hr = RoActivateInstance(hClass, inspectable.GetAddressOf());
    WindowsDeleteString(hClass);
    if (FAILED(hr)) {
        LogEvent(EVENTLOG_ERROR_TYPE, L"RoActivateInstance(Compositor) failed: " + HrStr(hr));
        FreeLibrary(coreMsg);
        return false;
    }
    ComPtr<WUC::ICompositor> compositor;
    hr = inspectable.As(&compositor);
    if (FAILED(hr)) {
        LogEvent(EVENTLOG_ERROR_TYPE, L"QI ICompositor failed: " + HrStr(hr));
        FreeLibrary(coreMsg);
        return false;
    }

    // 3) Bind the Compositor to a hidden top-level window via the desktop interop
    //    (ICompositorDesktopInterop is in ABI::Windows::UI::Composition::Desktop)
    //    and give the target a root visual so a frame is actually composed.
    HWND hwnd = CreateHiddenHostWindow();
    if (!hwnd) {
        LogEvent(EVENTLOG_ERROR_TYPE, L"CreateHiddenHostWindow failed: " +
                 std::to_wstring(GetLastError()));
        FreeLibrary(coreMsg);
        return false;
    }

    ComPtr<WUCD::ICompositorDesktopInterop> desktopInterop;
    hr = compositor.As(&desktopInterop);
    if (SUCCEEDED(hr)) {
        ComPtr<WUCD::IDesktopWindowTarget> target;
        hr = desktopInterop->CreateDesktopWindowTarget(hwnd, TRUE, target.GetAddressOf());
        if (SUCCEEDED(hr)) {
            ComPtr<WUC::IContainerVisual> container;
            if (SUCCEEDED(compositor->CreateContainerVisual(container.GetAddressOf()))) {
                ComPtr<WUC::IVisual> rootVisual;
                ComPtr<WUC::ICompositionTarget> compTarget;
                if (SUCCEEDED(container.As(&rootVisual)) &&
                    SUCCEEDED(target.As(&compTarget))) {
                    compTarget->put_Root(rootVisual.Get());

                    // 4) Pump so the dispatcher commits the first frame and the
                    //    input + composition stack settles, then tear down.
                    PumpMessages(3000);

                    compTarget->put_Root(nullptr);
                    hr = S_OK;
                }
            }
        }
    }
    if (FAILED(hr)) {
        LogEvent(EVENTLOG_ERROR_TYPE, L"Desktop composition target setup failed: " + HrStr(hr));
    }

    DestroyWindow(hwnd);
    FreeLibrary(coreMsg);
    return SUCCEEDED(hr);
}

// --------------------------------------------------------------------------
// Entry point (GUI subsystem -> no console window). Single purpose: run the
// composition/input warm-up once with package identity, then exit. Command-line
// arguments are ignored.
// --------------------------------------------------------------------------
int WINAPI wWinMain(HINSTANCE, HINSTANCE, LPWSTR, int)
{
    // Per-monitor DPI awareness matches how WinUI 3 hosts initialise; best-effort.
    SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);

    bool ok = false;
    HRESULT roHr = RoInitialize(RO_INIT_SINGLETHREADED);   // STA + WinRT
    if (SUCCEEDED(roHr)) {
        ok = WarmUpCompositionStack();
        RoUninitialize();
    } else {
        LogEvent(EVENTLOG_ERROR_TYPE, L"RoInitialize failed: " + HrStr(roHr));
    }

    LogEvent(ok ? EVENTLOG_INFORMATION_TYPE : EVENTLOG_WARNING_TYPE,
             std::wstring(L"ArcInputFixWarmup composition warm-up ") +
             (ok ? L"succeeded" : L"did not complete"));

    return ok ? 0 : 1;
}
