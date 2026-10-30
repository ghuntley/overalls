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

    /// <summary>
    /// @cc [owner:ghuntley,label:security] mila-dotnet-device-key-custody
    /// Existing deployment keys MUST be reused without exporting private material.
    /// New keys MUST be nonexportable P-256, preferring the TPM with software fallback.
    /// Access errors opening existing keys MUST propagate rather than replacing identity.
    /// </summary>
    internal static DeviceKey OpenOrCreate(string host)
    {
        string name = KeyName(host);
        CngProvider platform = CngProvider.MicrosoftPlatformCryptoProvider;
        CngProvider software = CngProvider.MicrosoftSoftwareKeyStorageProvider;
        if (Exists(name, platform)) return new(CngKey.Open(name, platform));
        if (CngKey.Exists(name, software)) return new(CngKey.Open(name, software));
        try { return Create(name, platform); }
        catch (CryptographicException)
        {
            // A concurrent creator may have won; never replace its identity.
            if (Exists(name, platform)) return new(CngKey.Open(name, platform));
            if (CngKey.Exists(name, software)) return new(CngKey.Open(name, software));
            return Create(name, software);
        }
    }

    private static bool Exists(string name, CngProvider provider)
    {
        try { return CngKey.Exists(name, provider); }
        catch (CryptographicException error) when (error.HResult is
            unchecked((int)0x80090013) or unchecked((int)0x80090017) or unchecked((int)0x80090029))
        {
            // Missing/undefined/unsupported platform provider, not a key access denial.
            return false;
        }
    }

    private static DeviceKey Create(string name, CngProvider provider) => new(CngKey.Create(
        CngAlgorithm.ECDsaP256, name, new CngKeyCreationParameters {
            Provider = provider, ExportPolicy = CngExportPolicies.None,
            KeyUsage = CngKeyUsages.Signing,
        }));

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
