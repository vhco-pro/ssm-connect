using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.Versioning;
using SSMConnect.Domain;

namespace SSMConnect.App;

/// <summary>
/// Draws the notification-area icon for each connection state.
/// </summary>
/// <remarks>
/// Generated rather than shipped as assets so the icon is correct at any DPI the shell asks for,
/// and so the state-to-colour mapping lives in one readable place. The colours match the macOS
/// client's: grey idle, amber working, green connected, red failed.
/// </remarks>
[SupportedOSPlatform("windows")]
public static class TrayIcons
{
    private static readonly Dictionary<ConnectionState, Icon> Cache = [];
    private static readonly Lock Gate = new();

    public static Icon For(ConnectionState state)
    {
        lock (Gate)
        {
            if (Cache.TryGetValue(state, out Icon? cached))
            {
                return cached;
            }

            Icon icon = Draw(ColourFor(state), state.IsTransitioning());
            Cache[state] = icon;
            return icon;
        }
    }

    public static string Tooltip(ConnectionState state) => state switch
    {
        ConnectionState.Disconnected => "Disconnected",
        ConnectionState.Authenticating => "Signing in…",
        ConnectionState.Resolving => "Finding the workstation…",
        ConnectionState.Starting => "Starting the workstation…",
        ConnectionState.WaitingForSsm => "Waiting for SSM…",
        ConnectionState.Tunneling => "Opening the tunnel…",
        ConnectionState.Connected => "Connected",
        ConnectionState.Error => "Connection failed",
        _ => "SSM Connect",
    };

    private static Color ColourFor(ConnectionState state) => state switch
    {
        ConnectionState.Connected => Color.FromArgb(0x2E, 0xA0, 0x43),
        ConnectionState.Error => Color.FromArgb(0xD1, 0x34, 0x38),
        ConnectionState.Disconnected => Color.FromArgb(0x8B, 0x8B, 0x8B),
        _ => Color.FromArgb(0xE0, 0x9B, 0x13),
    };

    /// <summary>
    /// A filled monitor glyph. Transitional states are drawn hollow, so the tray reads as
    /// "working" versus "settled" without relying on colour alone.
    /// </summary>
    private static Icon Draw(Color colour, bool hollow)
    {
        const int size = 32;
        using var bitmap = new Bitmap(size, size);
        using (var graphics = Graphics.FromImage(bitmap))
        {
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            graphics.Clear(Color.Transparent);

            var screen = new Rectangle(3, 6, 26, 17);
            using var pen = new Pen(colour, 3f);
            if (hollow)
            {
                graphics.DrawRectangle(pen, screen);
            }
            else
            {
                using var brush = new SolidBrush(colour);
                graphics.FillRectangle(brush, screen);
            }

            // The stand, so the glyph reads as a workstation rather than a plain block.
            using var standBrush = new SolidBrush(colour);
            graphics.FillRectangle(standBrush, new Rectangle(13, 23, 6, 4));
            graphics.FillRectangle(standBrush, new Rectangle(8, 27, 16, 3));
        }

        return Icon.FromHandle(bitmap.GetHicon());
    }
}
