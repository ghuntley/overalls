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
            byte[] point = device.PublicPoint();
            using DeviceKey reopened = DeviceKey.OpenOrCreate(host);
            Program.Require(point.SequenceEqual(reopened.PublicPoint()), "persistent deployment identity");
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
}
