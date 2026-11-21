using System.Runtime.Versioning;
using System.Windows.Interop;

namespace SSMConnect.App.Shell;

/// <summary>
/// The hidden top-level window that receives Restart Manager's close request. The tray's window is
/// message-only, and message-only windows never receive WM_QUERYENDSESSION, so without this window
/// the installer could not ask SSM Connect to close. Agreeing (the installer's close prompt, or the
/// user signing out) runs <c>close</c> before returning from WM_ENDSESSION, because Windows may end
/// the process once that message returns.
/// </summary>
[SupportedOSPlatform("windows")]
public sealed class SessionEndWindow : IDisposable
{
    const int WmQueryEndSession = 0x0011;
    const int WmEndSession = 0x0016;
    readonly HwndSource window;
    readonly Action close;

    public SessionEndWindow(Action close)
    {
        this.close = close;
        // WS_POPUP and never shown: top-level, so it is sent session-end messages, with no taskbar entry.
        window = new HwndSource(new HwndSourceParameters("SSM Connect") { WindowStyle = unchecked((int)0x80000000), Width = 0, Height = 0 });
        window.AddHook(OnMessage);
    }

    IntPtr OnMessage(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        switch (message)
        {
            case WmQueryEndSession:
                handled = true;
                return 1;
            case WmEndSession when wParam != IntPtr.Zero:
                handled = true;
                close();
                return IntPtr.Zero;
            default:
                return IntPtr.Zero;
        }
    }

    /// <summary>The window's handle (for tests).</summary>
    internal IntPtr Handle => window.Handle;

    public void Dispose() => window.Dispose();
}
