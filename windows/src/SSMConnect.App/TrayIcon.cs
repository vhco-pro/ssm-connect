using System.Drawing;
using System.Runtime.InteropServices;
using System.Runtime.Versioning;
using System.Windows;
using System.Windows.Interop;

namespace SSMConnect.App;

/// <summary>How prominent a balloon notification is.</summary>
public enum TrayNotificationKind
{
    Information,
    Warning,
    Error,
}

/// <summary>
/// A notification-area icon built directly on <c>Shell_NotifyIcon</c>.
/// </summary>
/// <remarks>
/// WPF has no tray primitive, and the usual answer is Windows Forms' <c>NotifyIcon</c>. That was the
/// first implementation here and it cost more than it looked: referencing Windows Forms makes the
/// whole application ineligible for trimming (NETSDK1175), which on a self-contained WPF app is the
/// difference between a very large payload and a merely large one. Calling the shell API directly
/// removes the dependency for perhaps eighty lines of interop.
/// <para>
/// The icon needs a window to receive its callback messages, so a message-only window is created
/// and never shown.
/// </para>
/// </remarks>
[SupportedOSPlatform("windows")]
public sealed class TrayIcon : IDisposable
{
    private const int WmTrayCallback = NativeMethods.WmUser + 1;

    private readonly HwndSource _window;
    private readonly uint _id = 1;
    private Icon? _icon;
    private bool _added;
    private bool _disposed;

    public TrayIcon()
    {
        // A message-only window: never shown, exists solely to receive the icon's callbacks.
        _window = new HwndSource(new HwndSourceParameters("SSM Connect tray")
        {
            WindowStyle = 0,
            ParentWindow = NativeMethods.HwndMessage,
        });
        _window.AddHook(OnMessage);
    }

    /// <summary>Raised on left-click or double-click: the shell's "do the obvious thing" gesture.</summary>
    public event Action? PrimaryActionRequested;

    /// <summary>Raised on right-click, with the menu expected to appear at the cursor.</summary>
    public event Action? ContextMenuRequested;

    public void Update(Icon icon, string tooltip)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);

        Icon? previous = _icon;
        _icon = icon;

        var data = NewData();
        data.uFlags = NativeMethods.NifIcon | NativeMethods.NifTip | NativeMethods.NifMessage;
        data.uCallbackMessage = WmTrayCallback;
        data.hIcon = icon.Handle;
        // Windows silently drops a tooltip longer than 127 characters, so it is capped here.
        data.szTip = tooltip.Length <= 127 ? tooltip : tooltip[..127];

        _added = NativeMethods.Shell_NotifyIcon(
            _added ? NativeMethods.NimModify : NativeMethods.NimAdd, ref data) || _added;

        if (!ReferenceEquals(previous, icon))
        {
            previous?.Dispose();
        }
    }

    public void ShowNotification(string title, string message, TrayNotificationKind kind)
    {
        if (_disposed || !_added)
        {
            return;
        }

        var data = NewData();
        data.uFlags = NativeMethods.NifInfo;
        data.szInfoTitle = title.Length <= 63 ? title : title[..63];
        data.szInfo = message.Length <= 255 ? message : message[..255];
        data.dwInfoFlags = kind switch
        {
            TrayNotificationKind.Warning => NativeMethods.NiifWarning,
            TrayNotificationKind.Error => NativeMethods.NiifError,
            _ => NativeMethods.NiifInfo,
        };

        NativeMethods.Shell_NotifyIcon(NativeMethods.NimModify, ref data);
    }

    private NativeMethods.NotifyIconData NewData() => new()
    {
        cbSize = Marshal.SizeOf<NativeMethods.NotifyIconData>(),
        hWnd = _window.Handle,
        uID = _id,
    };

    private IntPtr OnMessage(IntPtr hwnd, int msg, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (msg != WmTrayCallback)
        {
            return IntPtr.Zero;
        }

        switch ((int)lParam)
        {
            case NativeMethods.WmLButtonUp:
            case NativeMethods.WmLButtonDblClk:
                PrimaryActionRequested?.Invoke();
                handled = true;
                break;

            case NativeMethods.WmRButtonUp:
            case NativeMethods.WmContextMenu:
                ContextMenuRequested?.Invoke();
                handled = true;
                break;
        }

        return IntPtr.Zero;
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;

        if (_added)
        {
            var data = NewData();
            NativeMethods.Shell_NotifyIcon(NativeMethods.NimDelete, ref data);
            _added = false;
        }

        _icon?.Dispose();
        _window.RemoveHook(OnMessage);
        _window.Dispose();
    }

    private static class NativeMethods
    {
        internal const int WmUser = 0x0400;
        internal const int WmLButtonUp = 0x0202;
        internal const int WmLButtonDblClk = 0x0203;
        internal const int WmRButtonUp = 0x0205;
        internal const int WmContextMenu = 0x007B;

        internal const int NimAdd = 0x00000000;
        internal const int NimModify = 0x00000001;
        internal const int NimDelete = 0x00000002;

        internal const uint NifMessage = 0x00000001;
        internal const uint NifIcon = 0x00000002;
        internal const uint NifTip = 0x00000004;
        internal const uint NifInfo = 0x00000010;

        internal const uint NiifInfo = 0x00000001;
        internal const uint NiifWarning = 0x00000002;
        internal const uint NiifError = 0x00000003;

        internal static readonly IntPtr HwndMessage = new(-3);

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        internal struct NotifyIconData
        {
            internal int cbSize;
            internal IntPtr hWnd;
            internal uint uID;
            internal uint uFlags;
            internal int uCallbackMessage;
            internal IntPtr hIcon;

            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
            internal string szTip;

            internal uint dwState;
            internal uint dwStateMask;

            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
            internal string szInfo;

            internal uint uTimeoutOrVersion;

            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
            internal string szInfoTitle;

            internal uint dwInfoFlags;
        }

        // Classic DllImport rather than LibraryImport: the source generator cannot marshal a
        // struct with fixed-length inline strings, which is exactly what NOTIFYICONDATA is.
        [DllImport("shell32.dll", EntryPoint = "Shell_NotifyIconW", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool Shell_NotifyIcon(int message, ref NotifyIconData data);
    }
}

/// <summary>Places a WPF context menu at the cursor and keeps it dismissible.</summary>
[SupportedOSPlatform("windows")]
internal static class TrayMenuPlacement
{
    /// <summary>
    /// A tray menu must close when the user clicks elsewhere. WPF only does that for a menu whose
    /// placement target is a focused window, so the owning window is activated first.
    /// </summary>
    public static void ShowAtCursor(System.Windows.Controls.ContextMenu menu)
    {
        menu.Placement = System.Windows.Controls.Primitives.PlacementMode.MousePoint;
        menu.IsOpen = true;

        if (PresentationSource.FromVisual(menu) is HwndSource source)
        {
            NativeMenuMethods.SetForegroundWindow(source.Handle);
        }
    }

    private static class NativeMenuMethods
    {
        [DllImport("user32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        internal static extern bool SetForegroundWindow(IntPtr hWnd);
    }
}
