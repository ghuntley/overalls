using System.Runtime.Versioning;
using System.Text;
using Mila.Windows.Interop;

[SupportedOSPlatform("windows")]
internal static class SnapshotSmoke
{
    private static byte[] Snapshot(ulong time) => Encoding.UTF8.GetBytes($$"""
        {"version":1,"host":"mgmt.example.test","port":22,"saved_at":{{time}},"machines":[{"id":"11111111-1111-1111-1111-111111111111","name":"vm","desired_state":"running","observed_state":null,"pinned":false,"owner":null,"read":true,"write":true,"manage":true}]}
        """);
    internal static void Run()
    {
        string directory = Path.Combine(Path.GetTempPath(), "mila-snapshot-" + Guid.NewGuid().ToString("N"));
        MilaDeployment deployment = new("mgmt.example.test", 22);
        try
        {
            MilaSnapshotStore store = new(directory);
            long generation = store.Bind(deployment);
            Program.Require(store.Save(Snapshot(20), deployment, generation), "snapshot persists");
            Program.Require(!store.Save(Snapshot(10), deployment, generation), "snapshot newest wins");
            store.Bind(new("other.example.test", 22));
            Program.Require(!store.Save(Snapshot(30), deployment, generation), "snapshot stale generation fenced");
            MilaSnapshotStore restarted = new(directory);
            MilaSessionListing? listing = restarted.Load(deployment);
            Program.Require(listing is { Machines.Count: 1 } && !listing.Machines[0].CanRead && !listing.Machines[0].CanWrite && !listing.Machines[0].CanManage, "restart offline rows have no authority");
            Program.Require(restarted.Load(deployment with { Port = 2222 }) is null, "snapshot port binding");
            byte[] sealedBytes = File.ReadAllBytes(Directory.GetFiles(directory).Single());
            Program.Require(!Encoding.UTF8.GetString(sealedBytes).Contains("mgmt.example.test", StringComparison.Ordinal), "snapshot DPAPI sealed");
            restarted.Forget(deployment);
            Program.Require(restarted.Load(deployment) is null, "forget clears snapshot");
        }
        finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
    }
}
