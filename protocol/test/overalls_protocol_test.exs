defmodule OverallsProtocolTest do
  use ExUnit.Case, async: true
  import Hegel, except: [draw: 2]
  import OverallsProtocol.TestProperties, only: [draw: 2]
  import Hegel.Gen
  alias OverallsProtocol, as: Protocol
  alias OverallsProtocol.Execution
  @id "11111111-1111-4111-8111-111111111111"

  property "command encoding preserves supported intent, sizes and generation",
    database: :disabled,
    print_blob: false,
    test_cases: 100,
    seed: 966_314_123 do
    generation = draw("generation", integer(1..9_223_372_036_854_775_807))
    kind = draw("kind", member_of([:provision, :start, :stop, :delete]))
    profile = draw("profile", member_of([:customer, :standard, :oss]))
    cores = draw("cores", integer(1..32))

    command = %{
      id: @id,
      owner_id: @id,
      vm_id: @id,
      placement_id: @id,
      execution_epoch: 1,
      host_id: @id,
      pool_id: @id,
      generation: generation,
      kind: kind,
      profile: profile,
      architecture: :x86_64,
      vcpu: cores,
      memory_bytes: 536_870_912,
      disk_bytes: 2_147_483_648,
      image_id: "sha256:" <> String.duplicate("a", 64),
      slot: 2
    }

    wire = Execution.encode_command(command) |> JSON.encode!() |> JSON.decode!()
    assert {:ok, [^command]} = Execution.commands([wire])
  end

  property "capacity samples round trip without losing large integer precision",
    database: :disabled,
    print_blob: false,
    test_cases: 100,
    seed: 988_864_127 do
    total = draw("total", integer(1..9_223_372_036_854_775_807))
    free = draw("free", integer(0..total))
    allocated = draw("allocated", integer(0..(total - free)))

    report = %{
      sequence: 1,
      sampled_at: ~U[2026-09-15 12:00:00.000000Z],
      effective_cores: 4,
      effective_memory_bytes: 8_589_934_592,
      inventory: %{
        "architecture" => "x86_64",
        "images" => [],
        "execution_ready" => false,
        "terminal_protocol" => 0,
        "inception_image_id" => nil,
        "checkpoint_image_ids" => [],
        "checkpoint_compatibility" => nil
      },
      pools: [
        %{
          id: @id,
          total_bytes: total,
          free_bytes: free,
          allocations: %{@id => allocated},
          checkpoint_allocations: %{},
          storage: %{
            backend: :zfs,
            zpool_guid: "1",
            dataset_guid: "2",
            dataset: "tank/lilly",
            used_bytes: total - free,
            quota_bytes: total
          }
        }
      ]
    }

    wire = report |> Protocol.encode_report() |> JSON.encode!() |> JSON.decode!()
    assert {:ok, ^report} = Protocol.report(wire)
  end

  # @cc [owner:ghuntley,label:verification;protocol] pool-observed-at-round-trip
  # observed_at MUST round trip on observed pools, stay absent when absent, and
  # reject the whole report when malformed or attached to a busy pool.
  property "observed pools carry an optional observation time",
    database: :disabled,
    print_blob: false,
    test_cases: 100,
    seed: 412_907_311 do
    lag = draw("lag_us", integer(0..3_600_000_000))
    sampled = ~U[2026-10-30 21:00:00.000000Z]
    observed = DateTime.add(sampled, -lag, :microsecond)

    pool = %{
      id: @id,
      total_bytes: 100,
      free_bytes: 60,
      allocations: %{},
      checkpoint_allocations: %{},
      storage: %{
        backend: :zfs,
        zpool_guid: "1",
        dataset_guid: "2",
        dataset: "tank/lilly",
        used_bytes: 40,
        quota_bytes: 100
      }
    }

    report = %{
      sequence: 1,
      sampled_at: sampled,
      effective_cores: 4,
      effective_memory_bytes: 100,
      inventory: %{
        "architecture" => "x86_64",
        "images" => [],
        "execution_ready" => false,
        "terminal_protocol" => 0,
        "inception_image_id" => nil,
        "checkpoint_image_ids" => [],
        "checkpoint_compatibility" => nil
      },
      pools: [Map.put(pool, :observed_at, observed)]
    }

    wire = report |> Protocol.encode_report() |> JSON.encode!() |> JSON.decode!()
    assert {:ok, ^report} = Protocol.report(wire)

    legacy = %{report | pools: [pool]}
    legacy_wire = Protocol.encode_report(legacy) |> JSON.encode!() |> JSON.decode!()
    refute Map.has_key?(hd(legacy_wire["pools"]), "observed_at")
    assert {:ok, ^legacy} = Protocol.report(legacy_wire)

    [entry] = wire["pools"]

    for bad <- ["2026-10-30T21:00:00+01:00", "yesterday", 7, nil] do
      assert {:error, :invalid_message} =
               Protocol.report(%{wire | "pools" => [%{entry | "observed_at" => bad}]})
    end

    busy = %{
      "id" => @id,
      "busy" => true,
      "storage" => entry["storage"] |> Map.take(~w(backend zpool_guid dataset_guid dataset)),
      "observed_at" => entry["observed_at"]
    }

    assert {:error, :invalid_message} = Protocol.report(%{wire | "pools" => [busy]})
  end

  test "unavailable pools round trip without invented counters or credit" do
    pool = %{
      id: @id,
      unavailable: true,
      storage: %{backend: :zfs, zpool_guid: "1", dataset_guid: "2", dataset: "tank/lilly"}
    }

    report = %{
      sequence: 1,
      sampled_at: ~U[2026-09-17 00:00:00Z],
      effective_cores: 4,
      effective_memory_bytes: 100,
      inventory: %{
        "architecture" => "x86_64",
        "images" => [],
        "execution_ready" => false,
        "terminal_protocol" => 0,
        "inception_image_id" => nil,
        "checkpoint_image_ids" => [],
        "checkpoint_compatibility" => nil
      },
      pools: [pool]
    }

    wire = Protocol.encode_report(report)
    assert {:ok, ^report} = Protocol.report(wire)
    [encoded] = wire["pools"]

    for bad <- [
          Map.put(encoded, "total_bytes", 0),
          Map.put(encoded, "allocations", %{}),
          Map.put(encoded, "unavailable", false),
          put_in(encoded, ["storage", "dataset_guid"], "0")
        ] do
      assert {:error, :invalid_message} = Protocol.report(%{wire | "pools" => [bad]})
    end

    assert {:error, :invalid_message} = Protocol.report(%{wire | "pools" => [encoded, encoded]})
  end

  test "busy pools round trip as identity only and cannot also be unavailable or observed" do
    pool = %{
      id: @id,
      busy: true,
      storage: %{backend: :zfs, zpool_guid: "1", dataset_guid: "2", dataset: "tank/lilly"}
    }

    report = %{
      sequence: 1,
      sampled_at: ~U[2026-09-17 00:00:00Z],
      effective_cores: 4,
      effective_memory_bytes: 100,
      inventory: %{
        "architecture" => "x86_64",
        "images" => [],
        "execution_ready" => false,
        "terminal_protocol" => 0,
        "inception_image_id" => nil,
        "checkpoint_image_ids" => [],
        "checkpoint_compatibility" => nil
      },
      pools: [pool]
    }

    wire = Protocol.encode_report(report)
    assert {:ok, ^report} = Protocol.report(wire)
    [encoded] = wire["pools"]

    for bad <- [
          Map.put(encoded, "unavailable", true),
          Map.put(encoded, "free_bytes", 0),
          Map.put(encoded, "allocations", %{}),
          Map.put(encoded, "busy", false),
          put_in(encoded, ["storage", "dataset_guid"], "0")
        ] do
      assert {:error, :invalid_message} = Protocol.report(%{wire | "pools" => [bad]})
    end
  end

  property "arbitrary bytes have a bounded decode result without creating peer atoms",
    database: :disabled,
    print_blob: false,
    test_cases: 100,
    seed: 1_009_087_762 do
    bytes = draw("bytes", binary(max_length: 2048))
    result = Protocol.decode(bytes)
    assert match?({:ok, %{}}, result) or result == {:error, :invalid_message}
  end

  test "unknown versions, fields, oversized input and duplicate IDs are rejected" do
    assert {:error, :unsupported_version} =
             Execution.session(%{"version" => 1, "session_id" => @id})

    assert {:error, :invalid_message} =
             Execution.session(%{"version" => 4, "session_id" => @id, "actor" => "system"})

    assert {:error, :message_too_large} =
             Protocol.decode(:binary.copy(" ", Protocol.max_body() + 1))

    base = %{
      "version" => 4,
      "session_id" => @id,
      "epoch" => 1,
      "report" => nil,
      "acknowledgements" => [],
      "outcomes" => []
    }

    assert {:ok, _} = Execution.exchange(base)

    for value <- [-1, 0, 1.0, 9_223_372_036_854_775_808, "1"] do
      assert {:error, :invalid_message} = Execution.exchange(%{base | "epoch" => value})
    end

    assert {:error, :invalid_message} =
             Execution.exchange(%{base | "acknowledgements" => [@id, @id]})

    assert {:error, :invalid_message} =
             Execution.exchange(%{base | "acknowledgements" => List.duplicate(@id, 17)})
  end

  test "metadata is bounded and allocations cannot exceed used space" do
    report = %{
      "sequence" => 1,
      "sampled_at" => "2026-09-15T12:00:00Z",
      "effective_cores" => 4,
      "effective_memory_bytes" => 8_589_934_592,
      "inventory" => %{
        "architecture" => "x86_64",
        "images" => [],
        "execution_ready" => false,
        "terminal_protocol" => 0,
        "inception_image_id" => nil,
        "checkpoint_image_ids" => [],
        "checkpoint_compatibility" => nil
      },
      "pools" => []
    }

    assert {:ok, %{effective_cores: 0, effective_memory_bytes: 0}} =
             Protocol.report(%{report | "effective_cores" => 0, "effective_memory_bytes" => 0})

    deep = Enum.reduce(1..8, %{}, fn _, acc -> %{"nested" => acc} end)
    assert {:error, :invalid_message} = Protocol.report(%{report | "inventory" => deep})

    assert {:error, :invalid_message} =
             Protocol.report(%{report | "sampled_at" => "2026-09-15T12:00:00+01:00"})

    pool = %{
      "id" => @id,
      "total_bytes" => 100,
      "free_bytes" => 90,
      "allocations" => %{@id => 11}
    }

    assert {:error, :invalid_message} = Protocol.report(%{report | "pools" => [pool]})
    assert {:error, :invalid_message} = Execution.commands([%{"kind" => "new_peer_atom"}])
    assert_raise ArgumentError, fn -> String.to_existing_atom("new_peer_atom") end
  end
end
