using System.IO;
using Mila.Windows.Uia;

/// <summary>
/// @cc [owner:ghuntley,label:verification] mila-windows-uia-real-desktop
/// The UI Automation journey MUST report the desktop facts it ran on and MUST
/// exit non-zero when the client cannot be driven; an unavailable desktop
/// MUST NOT count as passing evidence.
/// </summary>
internal static class Program
{
    private static int Main(string[] args)
    {
        if (args is not ["--app", { Length: > 0 } app])
        {
            Console.Error.WriteLine("usage: Mila.Windows.Uia --app PATH\\Mila.Windows.exe");
            return 2;
        }
        DesktopFacts facts = DesktopProbe.Probe();
        Console.Error.WriteLine($"desktop: {facts}");
        if (!facts.Interactive)
            Console.Error.WriteLine("desktop: not an interactive desktop; attempting UI Automation anyway, failures are reported as such");
        try
        {
            PickerJourney.Run(Path.GetFullPath(app), facts);
        }
        catch (UiaCheckFailed failure)
        {
            Console.Error.WriteLine($"FAIL: {failure.Message}");
            Console.Error.WriteLine($"desktop: {facts}");
            return 1;
        }
        Console.Error.WriteLine("Windows deployment picker UI Automation journey passed");
        return 0;
    }
}
