// ArcInputFix - hidden logon utility to work around the Intel Arc (Core Ultra 7
// 268V / Lunar Lake) non-client-mouse bug on Windows 11, where Clarion MDI child
// windows stop responding to caption-drag / border-resize until some GUI app
// (e.g. mspaint) is run once per session.
//
// This is a GUI-subsystem exe (no console window). It launches Paint exactly the
// way typing "mspaint" in a prompt does - via its App Execution Alias - lets it
// reach its interactive state hidden, then terminates it. On the affected
// hardware that single launch re-arms the non-client input path for the session.
// The alias launch is the only behaviour proven to fix it (broker activation and
// in-process graphics warm-ups did not), so it is the sole action.
//
// Build: see build.cmd (MSVC, /SUBSYSTEM:WINDOWS, static CRT /MT, x64).

#ifndef UNICODE
#define UNICODE
#endif
#ifndef _UNICODE
#define _UNICODE
#endif

#include <windows.h>
#include <shobjidl_core.h>      // IApplicationActivationManager (packaged Paint)
#include <objbase.h>            // CoInitializeEx / CoCreateInstance
#include <tlhelp32.h>           // process enumeration (find Paint by image name)
#include <string>
#include <vector>

#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "user32.lib")

// CLSID_ApplicationActivationManager - last-resort launch of packaged Paint via
// IApplicationActivationManager (from <shobjidl_core.h>) if the alias is absent.
static const CLSID kCLSID_ApplicationActivationManager =
    { 0x45ba127d, 0x10a8, 0x46ea, { 0x8a, 0xb7, 0x56, 0xea, 0x90, 0x78, 0x94, 0x3c } };

// AppUserModelId of packaged Paint (same id the proven start_mspaint.ps1 uses).
static const wchar_t* kPaintAumid = L"Microsoft.Paint_8wekyb3d8bbwe!App";

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
// Shared: pump the message queue for ms milliseconds (an STA-style pump while
// Paint initializes and before terminating it).
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
// Action: run Paint briefly via its App Execution Alias (the proven fix).
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
//
// Single purpose: run the proven App Execution Alias launch of Paint. Any
// command-line arguments are ignored - there is exactly one behaviour.
// --------------------------------------------------------------------------
int WINAPI wWinMain(HINSTANCE, HINSTANCE, LPWSTR, int)
{
    bool ok = DoMspaintFallback();

    LogEvent(ok ? EVENTLOG_INFORMATION_TYPE : EVENTLOG_WARNING_TYPE,
             std::wstring(L"ArcInputFix mspaint ") +
             (ok ? L"succeeded" : L"did not complete"));

    return ok ? 0 : 1;
}

