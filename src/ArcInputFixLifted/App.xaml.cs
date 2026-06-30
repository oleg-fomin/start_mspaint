using System;
using System.Diagnostics;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace ArcInputFixLifted;

/// <summary>
/// Owned WinUI 3 logon helper that brings up the LIFTED Microsoft.UI.* input +
/// composition stack (Windows App SDK) once per session, then exits.
///
/// Why this exists: the Dell module capture (tools/fixdiff-out/mspaint-modules.csv)
/// showed real packaged Paint loads the lifted Microsoft.UI.Input /
/// Microsoft.InputStateManager / Microsoft.UI.Windowing / Microsoft.UI.Composition.OSSupport
/// stack from Microsoft.WindowsAppRuntime.1.8. Our earlier C++ helper
/// (src/ArcInputFixWarmup) used only the IN-BOX Windows.UI.Composition.Compositor and
/// did NOT fix the 268V non-client-mouse bug. This helper loads the lifted stack the
/// same way Paint does - by being an actual WinUI 3 app - and additionally arms the
/// lifted non-client pointer input source (InputNonClientPointerSource), the exact
/// subsystem the bug disables.
///
/// It is headless: the host Window is created off-screen and never shown, so there is
/// no visible flash. After a short dwell (enough for the stack to initialise and
/// commit a frame) it calls Application.Current.Exit().
/// </summary>
public partial class App : Application
{
    private Window? _window;

    public App()
    {
        this.InitializeComponent();
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        // Creating and activating a WinUI 3 Window is what forces the lifted
        // Microsoft.UI.* input/composition stack to load and initialise - the same
        // modules real Paint loads. We keep the window off-screen and hidden.
        _window = new WarmupWindow();
        _window.Activate();

        WarmupWindow.PrepareLiftedInputStack(_window);

        // Give the dispatcher time to commit the first frame and let the input /
        // composition subsystem finish its session-wide initialisation, then exit.
        DispatcherQueue.GetForCurrentThread().TryEnqueue(async () =>
        {
            try
            {
                await System.Threading.Tasks.Task.Delay(TimeSpan.FromSeconds(3));
            }
            finally
            {
                WarmupWindow.LogResult(true);
                _window?.Close();
                this.Exit();
            }
        });
    }
}
