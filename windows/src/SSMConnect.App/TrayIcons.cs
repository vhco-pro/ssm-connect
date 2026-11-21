using System.Drawing;
using System.Drawing.Drawing2D;
using System.Runtime.Versioning;

namespace SSMConnect.App;

/// <summary>Draws the notification-area icon for the desktop workflow's state (from the helper).</summary>
/// <remarks>
/// Generated rather than shipped as assets so the icon is correct at any DPI. The colours match the
/// macOS client's: grey idle, amber working, green connected, red failed; working states are hollow.
/// </remarks>
[SupportedOSPlatform("windows")]
public static class TrayIcons
{
    static readonly Dictionary<string, Icon> Cache = [];
    static readonly Lock Gate = new();

    public static Icon For(string state)
    {
        lock (Gate)
        {
            if (Cache.TryGetValue(state, out var cached)) return cached;
            var icon = Draw(ColourFor(state), hollow: state is not ("Connected" or "Disconnected" or "Error"));
            Cache[state] = icon;
            return icon;
        }
    }

    public static string Tooltip(string state) => state switch
    {
        "Disconnected" => "Disconnected",
        "Connected" => "Connected",
        "Error" => "Connection failed",
        "" => "SSM Connect",
        _ => state + "…",
    };

    static Color ColourFor(string state) => state switch
    {
        "Connected" => Color.FromArgb(0x2E, 0xA0, 0x43),
        "Error" => Color.FromArgb(0xD1, 0x34, 0x38),
        "Disconnected" or "" => Color.FromArgb(0x8B, 0x8B, 0x8B),
        _ => Color.FromArgb(0xE0, 0x9B, 0x13),
    };

    static Icon Draw(Color colour, bool hollow)
    {
        const int size = 32;
        using var bitmap = new Bitmap(size, size);
        using (var graphics = Graphics.FromImage(bitmap))
        {
            graphics.SmoothingMode = SmoothingMode.AntiAlias;
            graphics.Clear(Color.Transparent);
            var screen = new Rectangle(3, 6, 26, 17);
            using var pen = new Pen(colour, 3f);
            if (hollow) graphics.DrawRectangle(pen, screen);
            else { using var brush = new SolidBrush(colour); graphics.FillRectangle(brush, screen); }
            using var stand = new SolidBrush(colour);
            graphics.FillRectangle(stand, new Rectangle(13, 23, 6, 4));
            graphics.FillRectangle(stand, new Rectangle(8, 27, 16, 3));
        }
        return Icon.FromHandle(bitmap.GetHicon());
    }
}
