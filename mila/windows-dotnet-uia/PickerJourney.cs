using System.IO;
using System.Diagnostics;
using System.Text.Json;
using System.Windows.Automation;

namespace Mila.Windows.Uia;

/// <summary>A check of the running client that did not hold.</summary>
internal sealed class UiaCheckFailed(string message) : Exception(message);

/// <summary>A deployment as the client's <c>deployment.json</c> stores it.</summary>
internal sealed record SeededDeployment(string Host, ushort Port);

/// <summary>One list row: its UIA name and the names of the text it displays.</summary>
internal sealed record RowView(AutomationElement Element, string Name, IReadOnlyList<string> Texts)
{
    internal bool Displays(string host) => Name == host || Texts.Contains(host);

    public override string ToString() => $"[name={Name} texts={string.Join('|', Texts)}]";
}

/// <summary>
/// Drives the WinUI deployment picker of the built client through UI
/// Automation, against a seeded per-user deployment store.
/// </summary>
/// <remarks>
/// @cc [owner:ghuntley,label:verification] mila-windows-uia-picker-journey
/// The journey MUST launch the real built <c>Mila.Windows.exe</c> and observe
/// it only through UI Automation and the loopback trust listener. It MUST
/// fail unless (1) the <c>MilaDeploymentList</c> ListView displays exactly the
/// seeded hosts, (2) selecting a row and invoking <c>MilaDeploymentForget</c>
/// removes that row from the list and the store, and (3) selecting a row
/// fills the host and port entries from it and invoking
/// <c>MilaDeploymentSignIn</c> fetches trust from that row's host only, with
/// no row added. A missing window or control MUST fail; nothing is skipped.
/// </remarks>
internal static class PickerJourney
{
    private static readonly SeededDeployment Fixture = new("localhost", 2222);
    private static readonly SeededDeployment Other = new("mila-uia-other.invalid", 2200);
    private static readonly SeededDeployment Forgotten = new("mila-uia-forget.invalid", 22);
    private static readonly TimeSpan Settle = TimeSpan.FromSeconds(15);

    internal static void Run(string app, DesktopFacts facts)
    {
        using DeploymentStoreSeed store = DeploymentStoreSeed.Write([Other, Forgotten, Fixture]);
        using LoopbackTrustListener trust = LoopbackTrustListener.Start(443);
        using LaunchedClient client = LaunchedClient.Start(app, facts);
        AutomationElement window = client.Window;
        AutomationElement list = Find(window, "MilaDeploymentList");
        AutomationElement host = Find(window, "MilaDeploymentHost");
        AutomationElement port = Find(window, "MilaDeploymentPort");
        AutomationElement signIn = Find(window, "MilaDeploymentSignIn");
        AutomationElement forget = Find(window, "MilaDeploymentForget");

        // (1) The ListView shows the saved deployments.
        ExpectRows(list, [Other, Forgotten, Fixture]);
        Step("list shows the three saved deployments");
        Require(!IsEnabled(forget), "Forget is disabled while no deployment is selected");

        // (2) Selecting a row and invoking Forget updates the list and the store.
        Select(list, Forgotten);
        ExpectEntries(host, port, Forgotten);
        Eventually(() => IsEnabled(forget), "Forget is enabled for the selected deployment", () => "");
        Invoke(forget);
        ExpectRows(list, [Other, Fixture]);
        Eventually(() => !IsEnabled(forget), "Forget is disabled after the selected deployment is forgotten", () => "");
        IReadOnlyList<SeededDeployment> stored = store.Read();
        Require(stored.Count == 2 && stored.Contains(Other) && stored.Contains(Fixture),
            $"the store keeps only the remaining deployments: {string.Join(", ", stored)}");
        Step("Forget removed the selected deployment from the list and the store");

        // (3) The selection drives the sign-in target.
        Select(list, Other);
        ExpectEntries(host, port, Other);
        Invoke(signIn);
        Require(trust.Next(TimeSpan.FromSeconds(5)) is null && trust.Accepted == 0,
            $"signing in to {Other.Host} must not fetch trust from localhost");
        ExpectRows(list, [Other, Fixture]);
        Require(IsSelected(list, Other), $"{Other.Host} stays selected after sign-in");

        Select(list, Fixture);
        ExpectEntries(host, port, Fixture);
        Require(trust.Accepted == 0, "no trust fetch reached localhost before its sign-in");
        Invoke(signIn);
        LoopbackConnection fetch = trust.Next(TimeSpan.FromSeconds(20)) ??
            throw new UiaCheckFailed($"signing in to the selected {Fixture.Host} fetched no trust document from it");
        Require(fetch.ServerName is null || fetch.ServerName == Fixture.Host,
            $"the trust fetch named {fetch.ServerName}, not the selected {Fixture.Host}");
        ExpectRows(list, [Other, Fixture]);
        Require(IsSelected(list, Fixture), $"{Fixture.Host} stays selected after sign-in");
        Step($"sign-in followed the selection: no fetch for {Other.Host}, one for {Fixture.Host} " +
             $"from {fetch.Remote} (server name {fetch.ServerName ?? "not sent"})");
    }

    private static void Step(string message) => Console.Error.WriteLine($"ok: {message}");

    private static void Require(bool condition, string check)
    {
        if (!condition) throw new UiaCheckFailed(check);
    }

    private static void Eventually(Func<bool> condition, string check, Func<string> detail)
    {
        Stopwatch clock = Stopwatch.StartNew();
        while (true)
        {
            try
            {
                if (condition()) return;
            }
            catch (ElementNotAvailableException) { }
            if (clock.Elapsed > Settle) throw new UiaCheckFailed($"{check} {detail()}".TrimEnd());
            Thread.Sleep(200);
        }
    }

    private static AutomationElement Find(AutomationElement root, string automationId)
    {
        AutomationElement? found = null;
        Eventually(() => (found = root.FindFirst(TreeScope.Descendants,
                new PropertyCondition(AutomationElement.AutomationIdProperty, automationId))) is not null,
            $"control {automationId} is in the UI Automation tree", () => "");
        return found!;
    }

    private static IReadOnlyList<RowView> Rows(AutomationElement list)
    {
        AutomationElementCollection items = list.FindAll(TreeScope.Descendants,
            new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.ListItem));
        List<RowView> rows = [];
        foreach (AutomationElement item in items)
        {
            List<string> texts = [];
            CollectTexts(item, texts, 0);
            rows.Add(new RowView(item, item.Current.Name, texts));
        }
        return rows;
    }

    /// <summary>Names of every Text element below a row, in the raw view.</summary>
    private static void CollectTexts(AutomationElement element, List<string> texts, int depth)
    {
        if (depth > 8) return;
        for (AutomationElement? child = TreeWalker.RawViewWalker.GetFirstChild(element); child is not null;
             child = TreeWalker.RawViewWalker.GetNextSibling(child))
        {
            if (child.Current.ControlType == ControlType.Text) texts.Add(child.Current.Name);
            CollectTexts(child, texts, depth + 1);
        }
    }

    /// <summary>The rows display exactly <paramref name="expected"/>, one row per host.</summary>
    private static void ExpectRows(AutomationElement list, IReadOnlyList<SeededDeployment> expected)
    {
        IReadOnlyList<RowView> rows = [];
        Eventually(() =>
            {
                rows = Rows(list);
                return rows.Count == expected.Count &&
                    expected.All(deployment => rows.Count(row => row.Displays(deployment.Host)) == 1);
            },
            $"the deployment list displays exactly {string.Join(", ", expected.Select(deployment => deployment.Host))};",
            () => $"rows: {string.Join(' ', rows)}");
    }

    private static RowView Row(AutomationElement list, SeededDeployment deployment) =>
        Rows(list).SingleOrDefault(row => row.Displays(deployment.Host)) ??
            throw new UiaCheckFailed($"no single row displays {deployment.Host}");

    private static void Select(AutomationElement list, SeededDeployment deployment)
    {
        RowView row = Row(list, deployment);
        ((SelectionItemPattern)row.Element.GetCurrentPattern(SelectionItemPattern.Pattern)).Select();
        Eventually(() => IsSelected(list, deployment), $"{deployment.Host} is selected", () => "");
    }

    private static bool IsSelected(AutomationElement list, SeededDeployment deployment) =>
        ((SelectionItemPattern)Row(list, deployment).Element.GetCurrentPattern(SelectionItemPattern.Pattern))
            .Current.IsSelected;

    /// <summary>The host and port entries, which the sign-in reads, show the selected row.</summary>
    private static void ExpectEntries(AutomationElement host, AutomationElement port, SeededDeployment deployment)
    {
        string portText = deployment.Port.ToString(System.Globalization.CultureInfo.InvariantCulture);
        Eventually(() => Value(host) == deployment.Host && Value(port) == portText,
            $"the host and port entries show {deployment.Host}:{portText};",
            () => $"they show {Value(host)}:{Value(port)}");
    }

    private static string Value(AutomationElement element) =>
        ((ValuePattern)element.GetCurrentPattern(ValuePattern.Pattern)).Current.Value;

    private static bool IsEnabled(AutomationElement element) => element.Current.IsEnabled;

    private static void Invoke(AutomationElement button)
    {
        Eventually(() => IsEnabled(button), $"{button.Current.AutomationId} is enabled", () => "");
        ((InvokePattern)button.GetCurrentPattern(InvokePattern.Pattern)).Invoke();
    }
}

/// <summary>
/// Seeds the per-user deployment store the client reads at start and puts
/// any previous store back afterwards.
/// </summary>
internal sealed class DeploymentStoreSeed : IDisposable
{
    private readonly string _path;
    private readonly string _backup;
    private readonly bool _hadStore;

    private DeploymentStoreSeed(string path, bool hadStore)
    {
        _path = path;
        _backup = path + ".uia-backup";
        _hadStore = hadStore;
    }

    internal static DeploymentStoreSeed Write(IReadOnlyList<SeededDeployment> deployments)
    {
        string path = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Mila", "deployment.json");
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        DeploymentStoreSeed seed = new(path, File.Exists(path));
        if (File.Exists(seed._backup))
            throw new UiaCheckFailed($"a previous run left {seed._backup}; restore it by hand first");
        if (seed._hadStore) File.Move(path, seed._backup);
        File.WriteAllText(path, JsonSerializer.Serialize(deployments));
        return seed;
    }

    /// <summary>The store as the client last wrote it.</summary>
    internal IReadOnlyList<SeededDeployment> Read() =>
        JsonSerializer.Deserialize<List<SeededDeployment>>(File.ReadAllText(_path)) ??
            throw new UiaCheckFailed("the deployment store is not a JSON list");

    public void Dispose()
    {
        File.Delete(_path);
        if (_hadStore) File.Move(_backup, _path);
    }
}

/// <summary>The launched client process and its top-level UI Automation window.</summary>
/// <remarks>
/// The client's standard output and error are captured (the app names a
/// startup failure there) and echoed when the journey ends. When the client
/// exits before showing a window, the failure also carries the build layout
/// and recent Application event log crash entries for it.
/// </remarks>
internal sealed class LaunchedClient : IDisposable
{
    private readonly Process _process;
    private readonly ClientOutput _output;

    private LaunchedClient(Process process, ClientOutput output, AutomationElement window)
    {
        _process = process;
        _output = output;
        Window = window;
    }

    internal AutomationElement Window { get; }

    internal static LaunchedClient Start(string app, DesktopFacts facts)
    {
        if (!File.Exists(app)) throw new UiaCheckFailed($"the built client is missing: {app}");
        string directory = Path.GetDirectoryName(app)!;
        Console.Error.WriteLine($"client layout: {Layout(directory)}");
        Process process = new()
        {
            StartInfo = new ProcessStartInfo(app)
            {
                UseShellExecute = false,
                WorkingDirectory = directory,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
            },
        };
        ClientOutput output = new();
        process.OutputDataReceived += (_, line) => output.Add(line.Data);
        process.ErrorDataReceived += (_, line) => output.Add(line.Data);
        if (!process.Start()) throw new UiaCheckFailed($"could not start {app}");
        process.BeginOutputReadLine();
        process.BeginErrorReadLine();
        Condition condition = new AndCondition(
            new PropertyCondition(AutomationElement.ProcessIdProperty, process.Id),
            new PropertyCondition(AutomationElement.ControlTypeProperty, ControlType.Window));
        Stopwatch clock = Stopwatch.StartNew();
        while (clock.Elapsed < TimeSpan.FromSeconds(90))
        {
            if (process.HasExited)
            {
                // Lets the output pipes drain and the crash reach the event log.
                process.WaitForExit();
                Thread.Sleep(3000);
                throw new UiaCheckFailed(
                    $"the client exited with code {process.ExitCode} (0x{process.ExitCode:X8}) before showing a window ({facts})\n" +
                    $"client output:\n{output.Text()}\n" +
                    $"Application event log:\n{CrashEvents()}");
            }
            if (AutomationElement.RootElement.FindFirst(TreeScope.Children, condition) is { } window)
                return new LaunchedClient(process, output, window);
            Thread.Sleep(500);
        }
        process.Kill(entireProcessTree: true);
        throw new UiaCheckFailed(
            $"no top-level window of the client (pid {process.Id}) reached the UI Automation tree within 90 s ({facts})\n" +
            $"client output:\n{output.Text()}");
    }

    /// <summary>Whether the files an unpackaged WinUI launch reads sit beside the executable.</summary>
    private static string Layout(string directory)
    {
        string[] names = ["Mila.Windows.pri", "resources.pri", "Microsoft.UI.Xaml.dll", "Microsoft.WindowsAppRuntime.dll",
            "mila_native.dll", Path.Combine("Resources", "locales", "en.json")];
        IEnumerable<string> present = names.Select(name => $"{name}={File.Exists(Path.Combine(directory, name))}");
        int xbf = Directory.EnumerateFiles(directory, "*.xbf", SearchOption.AllDirectories).Count();
        int pri = Directory.EnumerateFiles(directory, "*.pri", SearchOption.TopDirectoryOnly).Count();
        return $"{string.Join(' ', present)} xbf={xbf} pri={pri} dir={directory}";
    }

    /// <summary>Application Error, .NET Runtime and WER entries from the last ten minutes, newest first.</summary>
    private static string CrashEvents()
    {
        const string query = "*[System[Provider[@Name='Application Error' or @Name='.NET Runtime' or " +
            "@Name='Windows Error Reporting'] and TimeCreated[timediff(@SystemTime) <= 600000]]]";
        ProcessStartInfo start = new("wevtutil.exe")
        {
            UseShellExecute = false,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        foreach (string argument in new[] { "qe", "Application", "/rd:true", "/c:6", "/f:text", $"/q:{query}" })
            start.ArgumentList.Add(argument);
        try
        {
            using Process wevtutil = Process.Start(start) ?? throw new InvalidOperationException("wevtutil did not start");
            Task<string> text = wevtutil.StandardOutput.ReadToEndAsync();
            Task<string> errors = wevtutil.StandardError.ReadToEndAsync();
            if (!wevtutil.WaitForExit(20_000))
            {
                wevtutil.Kill();
                return "<wevtutil timed out>";
            }
            string events = text.GetAwaiter().GetResult() + errors.GetAwaiter().GetResult();
            if (events.Length == 0) return "<no matching entries>";
            return events.Length <= 12_000 ? events : events[..12_000] + "\n<truncated>";
        }
        catch (Exception error) when (error is InvalidOperationException or System.ComponentModel.Win32Exception)
        {
            return $"<wevtutil unavailable: {error.Message}>";
        }
    }

    public void Dispose()
    {
        if (!_process.HasExited)
        {
            _process.Kill(entireProcessTree: true);
            _process.WaitForExit(10_000);
        }
        string text = _output.Text();
        if (text.Length > 0) Console.Error.WriteLine($"client output:\n{text}");
        _process.Dispose();
    }
}

/// <summary>The client's captured output lines, bounded.</summary>
internal sealed class ClientOutput
{
    private const int MaximumLines = 400;
    private readonly List<string> _lines = [];

    internal void Add(string? line)
    {
        if (line is null) return;
        lock (_lines)
            if (_lines.Count < MaximumLines) _lines.Add(line);
    }

    internal string Text()
    {
        lock (_lines) return string.Join('\n', _lines);
    }
}
