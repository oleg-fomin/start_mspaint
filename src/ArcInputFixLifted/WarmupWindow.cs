using System;
using System.Diagnostics;
using Microsoft.UI;
using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using WinRT.Interop;

namespace ArcInputFixLifted;

/// <summary>
/// Headless host window used purely to force the lifted Microsoft.UI.* stack to load
/// and to arm the lifted (non-client) pointer input source. Never shown to the user.
/// </summary>
public sealed class WarmupWindow : Window
{
    public WarmupWindow()
    {
        // No content is required - merely constructing/activating the Window pulls in
        // Microsoft.UI.Xaml + Microsoft.UI.Composition.OSSupport + the input stack.
        this.Title = "ArcInputFixLifted";
    }

    /// <summary>
    /// Move the host window off-screen and hide it via the lifted AppWindow API, then
    /// touch the lifted input sources so Microsoft.UI.Input / InputStateManager are
    /// fully initialised for the session.
    /// </summary>
    public static void PrepareLiftedInputStack(Window window)
    {
        try
        {
            IntPtr hwnd = WindowNative.GetWindowHandle(window);
            WindowId windowId = Win32Interop.GetWindowIdFromWindow(hwnd);

            // Lifted Microsoft.UI.Windowing - loads Microsoft.UI.Windowing.dll and
            // its dependencies, exactly as Paint does.
            AppWindow appWindow = AppWindow.GetFromWindowId(windowId);

            // Park it far off-screen at 1x1 and keep it out of the taskbar/switcher so
            // there is no visible flash, then hide outright.
            appWindow.MoveAndResize(new Windows.Graphics.RectInt32(-32000, -32000, 1, 1));
            if (appWindow.Presenter is OverlappedPresenter presenter)
            {
                presenter.IsMinimizable = false;
                presenter.IsMaximizable = false;
                presenter.SetBorderAndTitleBar(false, false);
            }
            appWindow.IsShownInSwitchers = false;
            appWindow.Hide();

            // Arm the lifted pointer input sources. These come from
            // Microsoft.UI.Input.dll / Microsoft.InputStateManager.dll - the modules
            // the in-box C++ helper never loaded. InputNonClientPointerSource is the
            // lifted owner of the NON-CLIENT (caption/border) pointer input path, i.e.
            // precisely the subsystem the 268V bug disables.
            var nonClient = InputNonClientPointerSource.GetForWindowId(windowId);
            _ = nonClient; // referencing/creating it initialises the NC input source
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[ArcInputFixLifted] input-stack prep note: {ex.Message}");
        }
    }

    // -----------------------------------------------------------------------------
    // One line to the Windows Application event log (source ArcInputFixLifted), so the
    // logon run is diagnosable on the fleet without a console - same pattern as the
    // C++ helpers.
    // -----------------------------------------------------------------------------
    public static void LogResult(bool ok)
    {
        const string source = "ArcInputFixLifted";
        string message = "ArcInputFixLifted lifted-stack warm-up " +
                         (ok ? "succeeded" : "did not complete");
        try
        {
            if (!EventLog.SourceExists(source))
            {
                // Creating a source needs admin; ignore if unavailable and fall back
                // to an existing generic source.
                try { EventLog.CreateEventSource(source, "Application"); } catch { }
            }
            using var log = new EventLog("Application") { Source = EventLog.SourceExists(source) ? source : "Application" };
            log.WriteEntry(message, ok ? EventLogEntryType.Information : EventLogEntryType.Warning);
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[ArcInputFixLifted] {message} (log failed: {ex.Message})");
        }
    }
}
