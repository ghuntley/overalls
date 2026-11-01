using System.Runtime.Versioning;
using System.Security.Cryptography;

namespace Mila.Windows.Interop;

/// <summary>OS custody for one deployment's existing CNG identity.</summary>
[SupportedOSPlatform("windows")]
internal sealed class DeviceKey : IDisposable
{
    private readonly CngKey key;
    internal CngProvider? Provider => key.Provider;
    private DeviceKey(CngKey key)
    {
        if (key.Algorithm != CngAlgorithm.ECDsaP256 || key.ExportPolicy != CngExportPolicies.None)
        {
            key.Dispose();
            throw new CryptographicException("Invalid device key policy");
        }
        this.key = key;
    }

    internal static string KeyName(string host)
    {
        ArgumentNullException.ThrowIfNull(host);
        string[] labels = host.Split('.');
        // `localhost` is the only single-label host: the loopback journey fixture.
        if (host.Length > 253 || (labels.Length < 2 && host != "localhost") || labels.Any(label =>
            label.Length is < 1 or > 63 || label[0] == '-' || label[^1] == '-' ||
            label.Any(c => !(c is >= 'a' and <= 'z' or >= '0' and <= '9' or '-'))))
            throw new ArgumentException("Invalid canonical deployment host", nameof(host));
        return "dev.overalls.mila.device." + host;
    }

    /// <summary>How this deployment's key is held; anything but Platform is a recorded software downgrade.</summary>
    internal MilaDeviceKeyCustody Custody { get; }

    private DeviceKey(CngKey key, MilaDeviceKeyCustody custody) : this(key) => Custody = custody;

    /// <summary>
    /// @cc [owner:ghuntley,label:security] mila-dotnet-device-key-custody
    /// Existing deployment keys MUST be reused without exporting private material.
    /// New keys MUST be nonexportable P-256, preferring the TPM with software fallback
    /// under <see cref="MilaDeviceKeyPolicy"/>, and the custody MUST be recorded.
    /// Access errors opening existing keys MUST propagate rather than replacing identity.
    /// </summary>
    internal static DeviceKey OpenOrCreate(string host, MilaDeviceKeyPolicy? policy = null)
    {
        string name = KeyName(host);
        (CngKey key, MilaDeviceKeyCustody custody) = MilaDeviceKeyCustodyPolicy.OpenOrCreate(
            name, CngKeyStore.Instance, policy ?? MilaDeviceKeyPolicy.Default, Thread.Sleep);
        return new(key, custody);
    }

    private sealed class CngKeyStore : IMilaKeyStore<CngKey>
    {
        internal static readonly CngKeyStore Instance = new();
        private static CngProvider Provider(MilaKeyProvider provider) => provider == MilaKeyProvider.Platform
            ? CngProvider.MicrosoftPlatformCryptoProvider : CngProvider.MicrosoftSoftwareKeyStorageProvider;
        public bool Exists(string name, MilaKeyProvider provider) => CngKey.Exists(name, Provider(provider));
        public CngKey Open(string name, MilaKeyProvider provider) => CngKey.Open(name, Provider(provider));
        public CngKey Create(string name, MilaKeyProvider provider) => CngKey.Create(
            CngAlgorithm.ECDsaP256, name, new CngKeyCreationParameters {
                Provider = Provider(provider), ExportPolicy = CngExportPolicies.None,
                KeyUsage = CngKeyUsages.Signing,
            });
    }

    internal byte[] PublicPoint()
    {
        using var signer = new ECDsaCng(key);
        ECParameters parameters = signer.ExportParameters(false);
        if (parameters.Q.X is not { Length: 32 } x || parameters.Q.Y is not { Length: 32 } y)
            throw new CryptographicException("Invalid device public point");
        byte[] point = new byte[65];
        point[0] = 4;
        x.CopyTo(point, 1);
        y.CopyTo(point, 33);
        static void Field(Stream stream, byte[] value)
        {
            Span<byte> length = stackalloc byte[4];
            System.Buffers.Binary.BinaryPrimitives.WriteUInt32BigEndian(length, (uint)value.Length);
            stream.Write(length); stream.Write(value);
        }
        using var encoded = new MemoryStream();
        byte[] algorithm = System.Text.Encoding.ASCII.GetBytes("ecdsa-sha2-nistp256");
        byte[] curve = System.Text.Encoding.ASCII.GetBytes("nistp256");
        Field(encoded, algorithm); Field(encoded, curve); Field(encoded, point);
        return System.Text.Encoding.ASCII.GetBytes("ecdsa-sha2-nistp256 " + Convert.ToBase64String(encoded.ToArray()));
    }

    /// <summary>SHA-256 ECDSA signature in Rust's fixed-width r || s format.</summary>
    internal byte[] Sign(ReadOnlySpan<byte> message)
    {
        using var signer = new ECDsaCng(key);
        return signer.SignData(message, HashAlgorithmName.SHA256,
            DSASignatureFormat.IeeeP1363FixedFieldConcatenation);
    }

    public void Dispose() => key.Dispose();
}

/// <summary>The CNG key storage provider a device key lives in.</summary>
internal enum MilaKeyProvider { Platform, Software }

/// <summary>Recorded custody of a deployment device key.</summary>
internal enum MilaDeviceKeyCustody
{
    /// <summary>Non-exportable key in the TPM (Microsoft Platform Crypto Provider).</summary>
    Platform,
    /// <summary>Software key: the platform provider is missing, undefined or unsupported.</summary>
    SoftwarePlatformUnavailable,
    /// <summary>Software key: the TPM stayed not ready for the whole retry budget.</summary>
    SoftwarePlatformNotReady,
    /// <summary>An existing software key for this deployment, reused so the identity is kept.</summary>
    SoftwareExisting,
}

/// <summary>
/// Software-fallback policy. ADR-0235 decision 3: a Windows machine without a
/// usable TPM is not refused. Set <see cref="AllowSoftwareFallback"/> false to
/// refuse every software custody instead.
/// </summary>
internal sealed record MilaDeviceKeyPolicy(IReadOnlyList<TimeSpan> NotReadyBackoff, bool AllowSoftwareFallback)
{
    /// <summary>About 5 s of backoff for a TPM that is starting (TBS, early boot, provisioning).</summary>
    internal static MilaDeviceKeyPolicy Default { get; } = new(
        [TimeSpan.FromMilliseconds(250), TimeSpan.FromMilliseconds(500), TimeSpan.FromSeconds(1),
         TimeSpan.FromMilliseconds(1250), TimeSpan.FromSeconds(2)],
        AllowSoftwareFallback: true);
}

/// <summary>Software custody refused by <see cref="MilaDeviceKeyPolicy.AllowSoftwareFallback"/>.</summary>
internal sealed class MilaDeviceKeyCustodyRefusedException(MilaDeviceKeyCustody refused)
    : System.Security.Cryptography.CryptographicException($"Software device key refused ({refused})")
{
    internal MilaDeviceKeyCustody Refused { get; } = refused;
}

/// <summary>Key operations the custody policy needs; CNG in production, a fake in tests.</summary>
internal interface IMilaKeyStore<TKey>
{
    bool Exists(string name, MilaKeyProvider provider);
    TKey Open(string name, MilaKeyProvider provider);
    TKey Create(string name, MilaKeyProvider provider);
}

/// <summary>
/// @cc [owner:ghuntley,label:security] mila-dotnet-device-key-fallback
/// NTE_DEVICE_NOT_READY from the platform provider MUST be retried within the
/// policy's bounded backoff before any software fallback. A missing, undefined or
/// unsupported platform provider falls back at once. Every software outcome MUST
/// be returned as a non-Platform custody (never silent) and MUST be refused when
/// the policy disallows software keys. Any other error, including access denial,
/// MUST propagate. An existing key is always reopened from its own provider.
/// </summary>
internal static class MilaDeviceKeyCustodyPolicy
{
    internal const int NotReady = unchecked((int)0x80090030);
    private const int AlreadyExists = unchecked((int)0x8009000F);

    /// <summary>NTE_BAD_KEYSET_PARAM, NTE_PROV_DLL_NOT_FOUND, NTE_NOT_SUPPORTED: no usable platform provider.</summary>
    internal static bool PlatformUnavailable(int hresult) => hresult is
        unchecked((int)0x80090013) or unchecked((int)0x80090017) or unchecked((int)0x80090029);

    private enum Step { Done, NotReady, Unavailable }

    internal static (TKey Key, MilaDeviceKeyCustody Custody) OpenOrCreate<TKey>(
        string name, IMilaKeyStore<TKey> store, MilaDeviceKeyPolicy policy, Action<TimeSpan> wait)
    {
        MilaDeviceKeyCustody fallback;
        for (int attempt = 0; ; attempt++)
        {
            Step step = TryPlatform(name, store, out TKey? key, out bool software);
            if (step == Step.Done)
            {
                if (!software) return (key!, MilaDeviceKeyCustody.Platform);
                return Software(policy, MilaDeviceKeyCustody.SoftwareExisting, key!);
            }
            if (step == Step.Unavailable) { fallback = MilaDeviceKeyCustody.SoftwarePlatformUnavailable; break; }
            if (attempt >= policy.NotReadyBackoff.Count) { fallback = MilaDeviceKeyCustody.SoftwarePlatformNotReady; break; }
            wait(policy.NotReadyBackoff[attempt]);
        }
        if (!policy.AllowSoftwareFallback) throw new MilaDeviceKeyCustodyRefusedException(fallback);
        return store.Exists(name, MilaKeyProvider.Software)
            ? (store.Open(name, MilaKeyProvider.Software), MilaDeviceKeyCustody.SoftwareExisting)
            : (store.Create(name, MilaKeyProvider.Software), fallback);
    }

    private static (TKey, MilaDeviceKeyCustody) Software<TKey>(MilaDeviceKeyPolicy policy, MilaDeviceKeyCustody custody, TKey key)
    {
        if (policy.AllowSoftwareFallback) return (key, custody);
        (key as IDisposable)?.Dispose();
        throw new MilaDeviceKeyCustodyRefusedException(custody);
    }

    /// <summary>One platform attempt: reopen the existing key (platform first), or create it in the TPM.</summary>
    private static Step TryPlatform<TKey>(string name, IMilaKeyStore<TKey> store, out TKey? key, out bool software)
    {
        key = default;
        software = false;
        try
        {
            if (store.Exists(name, MilaKeyProvider.Platform)) { key = store.Open(name, MilaKeyProvider.Platform); return Step.Done; }
            if (store.Exists(name, MilaKeyProvider.Software)) { key = store.Open(name, MilaKeyProvider.Software); software = true; return Step.Done; }
            try { key = store.Create(name, MilaKeyProvider.Platform); return Step.Done; }
            catch (System.Security.Cryptography.CryptographicException error) when (error.HResult == AlreadyExists)
            {
                // A concurrent creator won; never replace its identity.
                key = store.Open(name, MilaKeyProvider.Platform);
                return Step.Done;
            }
        }
        catch (System.Security.Cryptography.CryptographicException error) when (error.HResult == NotReady) { return Step.NotReady; }
        catch (System.Security.Cryptography.CryptographicException error) when (PlatformUnavailable(error.HResult)) { return Step.Unavailable; }
    }
}
