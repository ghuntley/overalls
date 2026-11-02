using Microsoft.UI.Xaml;

namespace Mila.Windows;

public partial class App : Application
{
    private Window? _window;
    private bool _started;

    /// <summary>Loads App.xaml, whose merged XamlControlsResources every WinUI control style needs.</summary>
    /// <remarks>
    /// @cc [owner:ghuntley,label:reliability] mila-windows-app-resources
    /// The constructor MUST call <c>InitializeComponent</c> before any window is
    /// created: without App.xaml's <c>XamlControlsResources</c> the controls have
    /// no default styles and the window fails to load.
    /// </remarks>
    public App()
    {
        UnhandledException += (_, args) => ReportStartupFailure(args.Exception, args.Message);
        try
        {
            InitializeComponent();
        }
        catch (Exception error)
        {
            ReportStartupFailure(error, error.Message);
            throw;
        }
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        if (_window is MainWindow existing)
        {
            existing.HandleExternalActivation(args.Arguments);
        }
        else
        {
            try
            {
                _window = new MainWindow(args.Arguments);
            }
            catch (Exception error)
            {
                ReportStartupFailure(error, error.Message);
                throw;
            }
        }
        _window.Activate();
        _started = true;
    }

    /// <summary>Names a failure that stops the first window from loading.</summary>
    /// <remarks>
    /// @cc [owner:ghuntley,label:security;verification] mila-windows-startup-failure-report
    /// Until the first window is activated, an exception that ends startup MUST
    /// be written to standard error as its type, HRESULT, message and stack
    /// trace, so a launcher (the UI Automation journey) can name it. After
    /// activation nothing MUST be written: later exceptions can carry session
    /// data, and the app holds no session, key or token before activation.
    /// </remarks>
    private void ReportStartupFailure(Exception error, string message)
    {
        if (_started) return;
        Console.Error.WriteLine($"mila: startup failed: {error.GetType().FullName} 0x{error.HResult:X8}: {message}");
        for (Exception? inner = error.InnerException; inner is not null; inner = inner.InnerException)
            Console.Error.WriteLine($"mila: caused by: {inner.GetType().FullName} 0x{inner.HResult:X8}: {inner.Message}");
        Console.Error.WriteLine(error.StackTrace);
    }
}
