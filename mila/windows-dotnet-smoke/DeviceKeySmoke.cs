using System.Runtime.Versioning;
using System.Security.Cryptography;
using Mila.Windows.Interop;

[SupportedOSPlatform("windows")]
internal static class DeviceKeySmoke
{
    internal static void Run()
    {
        string host = "custody-" + Guid.NewGuid().ToString("N") + ".example.test";
        CngProvider? provider = null;
        try
        {
            using DeviceKey device = DeviceKey.OpenOrCreate(host);
            provider = device.Provider ?? throw new CryptographicException("Missing CNG provider");
            byte[] publicKey = device.PublicPoint();
            using DeviceKey reopened = DeviceKey.OpenOrCreate(host);
            Program.Require(publicKey.SequenceEqual(reopened.PublicPoint()), "persistent deployment identity");
            byte[] point = OpenSshPoint(publicKey);
            using var verifier = ECDsa.Create(new ECParameters {
                Curve = ECCurve.NamedCurves.nistP256,
                Q = new ECPoint { X = point[1..33], Y = point[33..65] },
            });
            for (int size = 0; size <= 4096; size = size == 0 ? 1 : size * 2)
            {
                byte[] message = RandomNumberGenerator.GetBytes(size);
                byte[] signature = reopened.Sign(message);
                Program.Require(signature.Length == 64 && verifier.VerifyData(message, signature,
                    HashAlgorithmName.SHA256, DSASignatureFormat.IeeeP1363FixedFieldConcatenation),
                    "CNG signature matches Rust format");
            }
            using CngKey stored = CngKey.Open(DeviceKey.KeyName(host), provider);
            Program.Require(stored.ExportPolicy == CngExportPolicies.None, "nonexportable policy");
            bool exportRefused = false;
            try { _ = stored.Export(CngKeyBlobFormat.EccPrivateBlob); }
            catch (CryptographicException) { exportRefused = true; }
            Program.Require(exportRefused, "private export refusal");
        }
        finally
        {
            // Delete only the random synthetic key created by this invocation.
            if (provider is not null)
            {
                using CngKey cleanup = CngKey.Open(DeviceKey.KeyName(host), provider);
                cleanup.Delete();
            }
        }
    }

    /// <summary>
    /// PublicPoint returns the OpenSSH line `ecdsa-sha2-nistp256 <base64>`; the
    /// base64 body is three length-prefixed fields: algorithm, curve and the
    /// uncompressed point (0x04 || X || Y).
    /// </summary>
    private static byte[] OpenSshPoint(byte[] publicKey)
    {
        string line = System.Text.Encoding.ASCII.GetString(publicKey);
        string[] parts = line.Split(' ');
        Program.Require(parts is ["ecdsa-sha2-nistp256", _], "OpenSSH public key line");
        byte[] blob = Convert.FromBase64String(parts[1]);
        int offset = 0;
        byte[] Field()
        {
            Program.Require(blob.Length - offset >= 4, "OpenSSH field length");
            int length = (int)System.Buffers.Binary.BinaryPrimitives.ReadUInt32BigEndian(blob.AsSpan(offset, 4));
            offset += 4;
            Program.Require(length >= 0 && blob.Length - offset >= length, "OpenSSH field bounds");
            byte[] value = blob[offset..(offset + length)];
            offset += length;
            return value;
        }
        Program.Require(System.Text.Encoding.ASCII.GetString(Field()) == "ecdsa-sha2-nistp256", "OpenSSH algorithm field");
        Program.Require(System.Text.Encoding.ASCII.GetString(Field()) == "nistp256", "OpenSSH curve field");
        byte[] point = Field();
        Program.Require(offset == blob.Length && point is { Length: 65 } && point[0] == 4, "uncompressed P-256 point");
        return point;
    }
}
