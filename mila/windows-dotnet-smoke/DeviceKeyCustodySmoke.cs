using System.Security.Cryptography;
using Mila.Windows.Interop;

/// <summary>The device-key fallback policy against a scripted key store (no CNG).</summary>
internal static class DeviceKeyCustodySmoke
{
    private const int NotReady = unchecked((int)0x80090030);
    private const int NotSupported = unchecked((int)0x80090029);
    private const int AccessDenied = unchecked((int)0x80090010);

    private sealed record Key(MilaKeyProvider Provider);

    /// <summary>Each platform call fails with the next scripted HRESULT (0 passes), then behaves.</summary>
    private sealed class FakeStore(params int[] platformFailures) : IMilaKeyStore<Key>
    {
        private readonly Queue<int> failures = new(platformFailures);
        internal HashSet<MilaKeyProvider> Present { get; } = [];
        internal List<MilaKeyProvider> Created { get; } = [];
        internal int PlatformCalls { get; private set; }
        private void Platform(MilaKeyProvider provider)
        {
            if (provider != MilaKeyProvider.Platform) return;
            PlatformCalls++;
            // 0 scripts a passing call.
            if (failures.Count > 0 && failures.Dequeue() is var hresult and not 0) throw new CryptographicException(hresult);
        }
        public bool Exists(string name, MilaKeyProvider provider) { Platform(provider); return Present.Contains(provider); }
        public Key Open(string name, MilaKeyProvider provider) { Platform(provider); return new(provider); }
        public Key Create(string name, MilaKeyProvider provider)
        {
            Platform(provider);
            Created.Add(provider);
            Present.Add(provider);
            return new(provider);
        }
    }

    private static readonly MilaDeviceKeyPolicy Policy = new(
        [TimeSpan.FromMilliseconds(1), TimeSpan.FromMilliseconds(2), TimeSpan.FromMilliseconds(3)], AllowSoftwareFallback: true);

    private static (Key Key, MilaDeviceKeyCustody Custody, List<TimeSpan> Waits) Open(FakeStore store, MilaDeviceKeyPolicy? policy = null)
    {
        List<TimeSpan> waits = [];
        (Key key, MilaDeviceKeyCustody custody) = MilaDeviceKeyCustodyPolicy.OpenOrCreate("k", store, policy ?? Policy, waits.Add);
        return (key, custody, waits);
    }

    private static bool Throws<T>(Action action) where T : Exception
    {
        try { action(); return false; }
        catch (T) { return true; }
    }

    internal static void Run()
    {
        TimeSpan budget = MilaDeviceKeyPolicy.Default.NotReadyBackoff.Aggregate(TimeSpan.Zero, (sum, next) => sum + next);
        Program.Require(MilaDeviceKeyPolicy.Default.AllowSoftwareFallback && budget >= TimeSpan.FromSeconds(4) && budget <= TimeSpan.FromSeconds(6),
            "default not-ready budget is about 5 s and falls back (ADR-0235)");

        // Retry then success: the TPM comes up within the budget and is used.
        FakeStore warming = new(NotReady, NotReady);
        var warmed = Open(warming);
        Program.Require(warmed.Custody == MilaDeviceKeyCustody.Platform && warmed.Key.Provider == MilaKeyProvider.Platform &&
            warmed.Waits.SequenceEqual(Policy.NotReadyBackoff.Take(2)) && warming.Created.SequenceEqual([MilaKeyProvider.Platform]),
            "a TPM that becomes ready within the backoff holds the key");

        // A not-ready create (after a passing existence check) is retried too.
        FakeStore creating = new(0, NotReady);
        var createdAfterRetry = Open(creating);
        Program.Require(createdAfterRetry.Custody == MilaDeviceKeyCustody.Platform && createdAfterRetry.Waits.Count == 1 &&
            creating.Created.SequenceEqual([MilaKeyProvider.Platform]), "a not-ready TPM create is retried, then holds the key");

        // A ready TPM creates without waiting.
        var created = Open(new FakeStore());
        Program.Require(created.Custody == MilaDeviceKeyCustody.Platform && created.Waits.Count == 0, "a ready TPM creates without waiting");

        // Retry then fallback: still not ready after the whole budget.
        FakeStore stuck = new(Enumerable.Repeat(NotReady, 32).ToArray());
        var fellBack = Open(stuck);
        Program.Require(fellBack.Custody == MilaDeviceKeyCustody.SoftwarePlatformNotReady && fellBack.Key.Provider == MilaKeyProvider.Software &&
            fellBack.Waits.SequenceEqual(Policy.NotReadyBackoff) && stuck.PlatformCalls == Policy.NotReadyBackoff.Count + 1 &&
            stuck.Created.SequenceEqual([MilaKeyProvider.Software]),
            "a TPM still not ready after the backoff falls back to a recorded software key");

        // Missing/unsupported provider: immediate, recorded fallback.
        var unsupported = Open(new FakeStore(NotSupported));
        Program.Require(unsupported.Custody == MilaDeviceKeyCustody.SoftwarePlatformUnavailable && unsupported.Waits.Count == 0,
            "an unsupported platform provider falls back at once, recorded");

        // An existing software key is reopened, never replaced, and is recorded as software.
        FakeStore existing = new();
        existing.Present.Add(MilaKeyProvider.Software);
        var reopened = Open(existing);
        Program.Require(reopened.Custody == MilaDeviceKeyCustody.SoftwareExisting && existing.Created.Count == 0,
            "an existing software key is reused and recorded");

        // Access denied still refuses.
        Program.Require(Throws<CryptographicException>(() => Open(new FakeStore(AccessDenied))), "access denial propagates");
        Program.Require(Throws<CryptographicException>(() => Open(new FakeStore(NotReady, AccessDenied))), "access denial after a retry propagates");

        // The strict flip refuses every software custody.
        MilaDeviceKeyPolicy strict = Policy with { AllowSoftwareFallback = false };
        Program.Require(Throws<MilaDeviceKeyCustodyRefusedException>(() => Open(new FakeStore(Enumerable.Repeat(NotReady, 32).ToArray()), strict)),
            "strict policy refuses a not-ready fallback");
        Program.Require(Throws<MilaDeviceKeyCustodyRefusedException>(() => Open(new FakeStore(NotSupported), strict)),
            "strict policy refuses a missing platform provider");
        FakeStore strictExisting = new();
        strictExisting.Present.Add(MilaKeyProvider.Software);
        Program.Require(Throws<MilaDeviceKeyCustodyRefusedException>(() => Open(strictExisting, strict)), "strict policy refuses an existing software key");
        Program.Require(Open(new FakeStore(NotReady), strict).Custody == MilaDeviceKeyCustody.Platform, "strict policy still retries to a ready TPM");
    }
}
