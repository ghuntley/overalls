using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace Mila.Windows.Uia;

/// <summary>
/// Facts about the window station and desktop this process runs on. UI
/// Automation reaches only windows on the client's own desktop, and a WinUI
/// window needs a desktop with a compositor, so the journey reports these
/// facts before it launches the client and repeats them in any failure.
/// </summary>
internal sealed record DesktopFacts(
    int SessionId,
    uint ConsoleSessionId,
    string WindowStation,
    string ThreadDesktop,
    bool InputDesktopReadable,
    bool UserInteractive)
{
    /// <summary>
    /// An interactive desktop: a non-zero session, the interactive window
    /// station and a readable input desktop. Session 0 is isolated from the
    /// console and has no interactive input desktop.
    /// </summary>
    internal bool Interactive =>
        SessionId != 0 && InputDesktopReadable &&
        string.Equals(WindowStation, "WinSta0", StringComparison.OrdinalIgnoreCase);

    public override string ToString() =>
        $"session={SessionId} consoleSession={ConsoleSessionId} windowStation={WindowStation} " +
        $"threadDesktop={ThreadDesktop} inputDesktopReadable={InputDesktopReadable} " +
        $"userInteractive={UserInteractive} interactive={Interactive}";
}

internal static partial class DesktopProbe
{
    private const int UoiName = 2;
    private const uint DesktopReadObjects = 0x0001;

    internal static DesktopFacts Probe()
    {
        nint input = OpenInputDesktop(0, false, DesktopReadObjects);
        bool readable = input != 0;
        if (readable) CloseDesktop(input);
        return new DesktopFacts(
            Process.GetCurrentProcess().SessionId,
            WTSGetActiveConsoleSessionId(),
            ObjectName(GetProcessWindowStation()),
            ObjectName(GetThreadDesktop(GetCurrentThreadId())),
            readable,
            Environment.UserInteractive);
    }

    private static string ObjectName(nint handle)
    {
        if (handle == 0) return "<none>";
        byte[] buffer = new byte[512];
        if (!GetUserObjectInformationW(handle, UoiName, buffer, (uint)buffer.Length, out uint needed))
            return $"<error {Marshal.GetLastPInvokeError()}>";
        int length = (int)Math.Min(needed, (uint)buffer.Length);
        return Encoding.Unicode.GetString(buffer, 0, length).TrimEnd('\0');
    }

    [LibraryImport("user32.dll", SetLastError = true)]
    private static partial nint OpenInputDesktop(uint flags, [MarshalAs(UnmanagedType.Bool)] bool inherit, uint desiredAccess);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool CloseDesktop(nint desktop);

    [LibraryImport("user32.dll", SetLastError = true)]
    private static partial nint GetProcessWindowStation();

    [LibraryImport("user32.dll", SetLastError = true)]
    private static partial nint GetThreadDesktop(uint threadId);

    [LibraryImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static partial bool GetUserObjectInformationW(nint handle, int index, [Out] byte[] info, uint length, out uint needed);

    [LibraryImport("kernel32.dll")]
    private static partial uint GetCurrentThreadId();

    [LibraryImport("kernel32.dll")]
    private static partial uint WTSGetActiveConsoleSessionId();
}
