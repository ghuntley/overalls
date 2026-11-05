using System.Runtime.Versioning;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Text;

namespace Mila.Windows.Interop;

/// <summary>
/// @cc [owner:ghuntley,label:security;privacy] mila-windows-durable-snapshot
/// Only complete Rust-validated snapshots may persist. DPAPI user scope and
/// deployment entropy bind each owner-only, non-reparse file to its management
/// host and SSH port. Atomic newest-wins writes are fenced by bind generation.
/// Cached rows have no read/write/manage permission and grant no session authority.
/// </summary>
[SupportedOSPlatform("windows")]
internal sealed class MilaSnapshotStore(string? directory = null)
{
    private readonly string directory = directory ?? Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Mila", "snapshots");
    private readonly object gate = new();
    private long generation;
    private MilaDeployment? target;
    private const int MaximumBytes = 1 << 20;

    internal long Bind(MilaDeployment? deployment)
    {
        lock (gate) { generation = checked(generation + 1); target = deployment; return generation; }
    }

    internal MilaSessionListing? Load(MilaDeployment deployment)
    {
        lock (gate)
        {
            if (Read(deployment) is not { } bytes) return null;
            MilaSessionListing listing = MilaSessionListing.Decode(bytes);
            return new(listing.Machines.Select(row => row with { CanRead = false, CanWrite = false, CanManage = false }).ToArray(), false);
        }
    }

    internal bool Save(ReadOnlySpan<byte> bytes, MilaDeployment deployment, long expectedGeneration)
    {
        lock (gate)
        {
            if (generation != expectedGeneration || target != deployment) return false;
            ulong savedAt = Validate(bytes, deployment);
            if (Read(deployment) is { } previous && Validate(previous, deployment) >= savedAt) return false;
            MilaWindowsPokeKeyStore.EnsureOwnerOnlyDirectory(directory);
            RequireRegular(directory, isDirectory: true);
            byte[] blob = MilaDpapi.Protect(bytes.ToArray(), Entropy(deployment));
            string path = PathFor(deployment);
            string temporary = path + "." + Guid.NewGuid().ToString("N") + ".new";
            try
            {
                FileSecurity security = new();
                security.SetSecurityDescriptorSddlForm(MilaWindowsPokeKeyStore.OwnerOnlySddl(isDirectory: false));
                using (FileStream stream = new FileInfo(temporary).Create(FileMode.CreateNew, FileSystemRights.Write,
                    FileShare.None, 4096, FileOptions.WriteThrough, security))
                { stream.Write(blob); stream.Flush(true); }
                File.Move(temporary, path, overwrite: true);
            }
            finally { if (File.Exists(temporary)) File.Delete(temporary); }
            return true;
        }
    }

    internal void Forget(MilaDeployment deployment)
    {
        lock (gate)
        {
            if (target == deployment) generation = checked(generation + 1);
            if (!Directory.Exists(directory)) return;
            RequireRegular(directory, isDirectory: true);
            MilaWindowsPokeKeyStore.RequireOwnerOnly(new DirectoryInfo(directory).GetAccessControl());
            string path = PathFor(deployment);
            if (File.Exists(path)) File.Delete(path);
        }
    }

    private byte[]? Read(MilaDeployment deployment)
    {
        if (!Directory.Exists(directory)) return null;
        RequireRegular(directory, isDirectory: true);
        MilaWindowsPokeKeyStore.RequireOwnerOnly(new DirectoryInfo(directory).GetAccessControl());
        string path = PathFor(deployment);
        if (!File.Exists(path)) return null;
        RequireRegular(path, isDirectory: false);
        MilaWindowsPokeKeyStore.RequireOwnerOnly(new FileInfo(path).GetAccessControl());
        if (new FileInfo(path).Length is 0 or > MaximumBytes + 65536) throw new InvalidDataException("snapshot bounds");
        byte[] bytes = MilaDpapi.Unprotect(File.ReadAllBytes(path), Entropy(deployment));
        _ = Validate(bytes, deployment);
        return bytes;
    }

    private static ulong Validate(ReadOnlySpan<byte> bytes, MilaDeployment deployment)
    {
        if (bytes.Length > MaximumBytes) throw new InvalidDataException("snapshot bounds");
        MilaNativeSnapshotResult result = RustNative.TryValidateSnapshot(bytes, deployment.Host, deployment.Port, true);
        return result.Status == MilaNativeStatus.Ok && result.Summary is { } summary ? summary.SavedAt : throw new InvalidDataException("invalid snapshot");
    }

    private string PathFor(MilaDeployment deployment)
    {
        if (!MilaDeploymentHost.IsCanonical(deployment.Host) || deployment.Port == 0) throw new InvalidDataException("invalid deployment");
        return Path.Combine(directory, Convert.ToHexStringLower(SHA256.HashData(Entropy(deployment))) + ".snapshot");
    }
    private static byte[] Entropy(MilaDeployment deployment) => Encoding.UTF8.GetBytes($"dev.overalls.mila.snapshot.v1|{deployment.Host}:{deployment.Port}");
    private static void RequireRegular(string path, bool isDirectory)
    {
        FileAttributes attributes = File.GetAttributes(path);
        if ((attributes & FileAttributes.ReparsePoint) != 0 || ((attributes & FileAttributes.Directory) != 0) != isDirectory)
            throw new UnauthorizedAccessException("snapshot storage is not regular");
    }
}
