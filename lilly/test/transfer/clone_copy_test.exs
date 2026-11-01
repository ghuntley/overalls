defmodule Lilly.Transfer.CloneCopyTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias OverallsProtocol.DiskTransfer
  alias Lilly.Host.{Lock, Pool}
  alias Lilly.Transfer.CloneCopy

  defp id(n), do: "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(n), 12, "0")

  defp descriptor(destination_host, destination_pool) do
    {:ok, descriptor} =
      DiskTransfer.descriptor(%{
        "version" => 3,
        "purpose" => "clone",
        "relocation_id" => id(1),
        "vm_id" => id(2),
        "destination_vm_id" => id(3),
        "source_slot" => 2,
        "source" => %{"host_id" => id(4), "pool_id" => id(5), "placement_id" => id(6)},
        "destination" => %{
          "host_id" => destination_host,
          "pool_id" => destination_pool,
          "placement_id" => id(7)
        },
        "source_epoch" => 9,
        "destination_epoch" => 1,
        "workload" => %{
          "image_id" => "sha256:" <> String.duplicate("a", 64),
          "architecture" => "x86_64",
          "profile" => "customer",
          "slot" => 3,
          "vcpu" => 1,
          "memory_bytes" => 536_870_912,
          "disk_bytes" => 2_147_483_648
        },
        "stream" => %{
          "source_dataset_guid" => "100",
          "to_guid" => "200"
        }
      })

    descriptor
  end

  property "only same-host, same-pool clones are eligible for block copies" do
    host = draw("host", member_of([id(4), id(8)]))
    pool = draw("pool", member_of([id(5), id(9)]))
    assert CloneCopy.same_pool?(descriptor(host, pool)) == (host == id(4) and pool == id(5))
  end

  @tag :tmp_dir
  test "copy history is durable local state and cleanup refuses without it", %{tmp_dir: dir} do
    pool = %{path: dir, storage: %{dataset: "pool/lilly"}}
    descriptor = descriptor(id(4), id(5))
    refute CloneCopy.history?(pool, descriptor)
    intent = Map.delete(descriptor, :stream)
    assert {:error, _} = CloneCopy.cleanup_intent(pool, intent)

    assert CloneCopy.mount_path(descriptor) ==
             "/run/lilly-clone-copies/" <> descriptor.relocation_id
  end

  # clone-copy-contention-stays-busy: a held pool lock is ordinary contention.
  @tag :tmp_dir
  test "adoption under a held pool lock is storage_busy, not unconfirmed", %{tmp_dir: dir} do
    File.chmod!(dir, 0o700)

    pool = %Pool{
      id: id(5),
      path: dir,
      filesystem_id: "zfs:1:2",
      host_id: id(4),
      storage: %{dataset: "pool/lilly"}
    }

    {:ok, owner} = Lock.acquire(Path.join(dir, ".lilly-storage"))

    try do
      task = Task.async(fn -> CloneCopy.adopt(pool, descriptor(id(4), id(5))) end)
      assert Task.await(task, 10_000) == {:error, :storage_busy}
    after
      Lock.release(owner)
    end
  end
end
