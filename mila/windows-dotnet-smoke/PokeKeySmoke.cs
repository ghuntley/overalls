using System.Runtime.Versioning;
using System.Security.AccessControl;
using Mila.Windows.Interop;

/// <summary>Windows X25519 poke-key custody: RFC 7748 interop, DPAPI sealing and the owner-only DACL.</summary>
[SupportedOSPlatform("windows")]
internal static class PokeKeySmoke
{
    private static byte[] Hex(string hex) => Convert.FromHexString(hex);

    internal static void Run()
    {
        // RFC 7748 section 6.1: both sides derive the same secret, which fixes the byte order.
        byte[] alicePrivate = Hex("77076d0a7318a57d3c16c17251b26645df4c2f87ebc0992ab177fba51db92c2a");
        byte[] alicePublic = Hex("8520f0098930a754748b7ddcb43ef75a0dbf3a0d26381af4eba4a98eaa9b4e6a");
        byte[] bobPrivate = Hex("5dab087e624a8a4b79e17f8b83800ee66f3bb1292618b6fd1c2f8b27ff88e0eb");
        byte[] bobPublic = Hex("de9edb7d7b7dc1b4d35b61c2ece435373f8343c85b78674dadfc7e146f882b4f");
        byte[] shared = Hex("4a5d9d5ba4ce2de1728e3bf480350f25e07e21c947d19e3376f09b3c1e161742");
        Program.Require(MilaX25519.Agree(alicePrivate, alicePublic, bobPublic).AsSpan().SequenceEqual(shared) &&
            MilaX25519.Agree(bobPrivate, bobPublic, alicePublic).AsSpan().SequenceEqual(shared),
            "X25519 matches RFC 7748 (little-endian keys)");

        (byte[] privateKey, byte[] publicKey) = MilaX25519.Generate();
        (byte[] otherPrivate, byte[] otherPublic) = MilaX25519.Generate();
        Program.Require(MilaX25519.Agree(privateKey, publicKey, otherPublic).AsSpan()
                .SequenceEqual(MilaX25519.Agree(otherPrivate, otherPublic, publicKey)),
            "generated X25519 pairs agree");

        string root = Path.Combine(Path.GetTempPath(), "mila-poke-" + Guid.NewGuid().ToString("N"));
        string directory = Path.Combine(root, "poke-keys");
        try
        {
            MilaWindowsPokeKeyStore store = new(directory);
            string? first = store.PublicKey("mgmt.example.test");
            Program.Require(first is { Length: 43 } && !first.Contains('=') && !first.Contains('+') && !first.Contains('/'),
                "poke public key is unpadded base64url of 32 bytes");
            Program.Require(new MilaWindowsPokeKeyStore(directory).PublicKey("mgmt.example.test") == first,
                "poke key persists per deployment");
            Program.Require(store.PublicKey("other.example.test") is { Length: 43 } other && other != first,
                "each deployment has its own poke key");
            Program.Require(store.PublicKey("not a host") is null, "invalid deployment has no key");

            string file = Path.Combine(directory, "mgmt.example.test.poke");
            (byte[] storedPrivate, byte[] storedPublic) = store.LoadOrCreate("mgmt.example.test");
            byte[] blob = File.ReadAllBytes(file);
            Program.Require(blob.AsSpan().IndexOf(storedPrivate) < 0, "the private key is never stored in clear");
            Program.Require(MilaWindowsPokeKeyStore.Base64Url(storedPublic) == first, "stored pair matches the public key");
            Array.Clear(storedPrivate);

            FileSystemSecurity fileAcl = new FileInfo(file).GetAccessControl();
            MilaWindowsPokeKeyStore.RequireOwnerOnly(fileAcl);
            MilaWindowsPokeKeyStore.RequireOwnerOnly(new DirectoryInfo(directory).GetAccessControl());

            // Another deployment's blob, or a tampered one, does not unseal: unavailable, not replaced.
            File.Copy(Path.Combine(directory, "other.example.test.poke"), file, overwrite: true);
            Program.Require(store.PublicKey("mgmt.example.test") is null && File.Exists(file),
                "a blob sealed for another deployment is refused, not replaced");
            File.WriteAllBytes(file, [.. blob[..^1], (byte)(blob[^1] ^ 1)]);
            Program.Require(store.PublicKey("mgmt.example.test") is null, "a tampered blob is refused");

            // A DACL that admits Everyone is refused.
            FileSecurity open = new();
            open.SetSecurityDescriptorSddlForm(MilaWindowsPokeKeyStore.OwnerOnlySddl(isDirectory: false) + "(A;;FR;;;WD)");
            File.WriteAllBytes(file, blob);
            new FileInfo(file).SetAccessControl(open);
            Program.Require(store.PublicKey("mgmt.example.test") is null, "a poke key readable by others is refused");
        }
        finally
        {
            if (Directory.Exists(root)) Directory.Delete(root, recursive: true);
        }
    }
}
