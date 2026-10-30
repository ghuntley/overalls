defmodule Lilly.Lifecycle.ProvisioningTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Lilly.Host.Lock
  alias Lilly.Lifecycle.{Journal, Provisioning}
  @moduletag :tmp_dir

  @type model :: %{
          effects: MapSet.t(atom()),
          retired: boolean(),
          failed: boolean(),
          payload: map(),
          revision: pos_integer()
        }

  setup %{tmp_dir: root} do
    File.chmod!(root, 0o700)
    now = System.system_time(:millisecond)

    %{
      payload: %{
        "state" => "pending",
        "host_id" => Lilly.UUID.generate(),
        "placement_id" => Lilly.UUID.generate(),
        "execution_epoch" => 1,
        "generation" => 1,
        "started_at" => now,
        "launched_at" => nil,
        "deadline" => nil,
        "boot_challenge" => nil,
        "boot_id" => nil
      }
    }
  end

  # @cc [owner:ghuntley,label:verification] provisioning-independent-history-oracle
  # The oracle MUST track completed prerequisites and terminal facts independently
  # of Ash's transition table. Reopen after every command; invalid requests MUST
  # preserve state and revision. Duplicate writes MUST NOT change either.
  @tag :hegel
  # The full 100-case budget measured 15-26 s under the parallel suite on
  # 8 local CPUs; the slower CI runner exceeded the 60 s default.
  @tag timeout: 180_000
  test "generated progress, faults and replays preserve prerequisites and bindings", c do
    Hegel.check(
      fn ->
        history =
          draw(
            "history",
            list_of(
              member_of([
                :disk,
                :launch,
                :trust,
                :ssh,
                :receipt,
                :fail,
                :retire,
                :replay,
                :extend_deadline,
                :wrong_boot,
                :stale_generation
              ]),
              min_length: 1,
              max_length: 24
            )
          )

        directory = Path.join(c.tmp_dir, Lilly.UUID.generate())
        locked(directory, fn -> assert :ok = write(directory, c.payload) end)

        initial = %{
          effects: MapSet.new(),
          retired: false,
          failed: false,
          payload: c.payload,
          revision: 1
        }

        Enum.reduce(history, initial, fn command, model ->
          {allowed, proposal, next} = step(model, command)
          {:ok, before} = Journal.load(Provisioning, directory, "provisioning.json")
          result = locked(directory, fn -> write(directory, proposal) end)
          assert result == :ok == allowed
          assert {:ok, after_record} = Journal.load(Provisioning, directory, "provisioning.json")

          if allowed and proposal != model.payload do
            assert after_record.payload == proposal
            assert after_record.revision == model.revision + 1
            %{next | payload: proposal, revision: model.revision + 1}
          else
            assert after_record == before
            model
          end
        end)
      end,
      test_cases: 100
    )
  end

  test "ready needs a current boot receipt; newer generations supersede preserving identity",
       c do
    directory = c.tmp_dir
    nonce = String.duplicate("a", 64)

    locked(directory, fn ->
      assert :ok = write(directory, c.payload)
      assert :ok = write(directory, %{c.payload | "state" => "materializing"})

      payload = %{
        c.payload
        | "state" => "launching",
          "boot_challenge" => nonce,
          "launched_at" => c.payload["started_at"],
          "deadline" => c.payload["started_at"] + 120_000
      }

      assert :ok = write(directory, payload)
      assert :ok = write(directory, %{payload | "state" => "awaiting_trust"})
      assert :ok = write(directory, %{payload | "state" => "awaiting_ssh"})
      assert {:error, _} = write(directory, %{payload | "state" => "ready"})
      ready = %{payload | "state" => "ready", "boot_id" => Lilly.UUID.generate()}
      assert :ok = write(directory, ready)
      assert {:error, _} = write(directory, %{c.payload | "generation" => 2})
      assert :ok = write(directory, %{ready | "state" => "superseded"})
    end)

    assert {:ok, before} = Journal.load(Provisioning, directory, "provisioning.json")
    locked(directory, fn -> assert :ok = write(directory, %{c.payload | "generation" => 2}) end)

    assert {:ok, %{revision: 8, state: :pending} = latest} =
             Journal.load(Provisioning, directory, "provisioning.json")

    assert latest.id == before.id
    assert latest.payload["generation"] == 2
    assert is_nil(latest.payload["boot_challenge"])
    assert is_nil(latest.payload["boot_id"])
  end

  test "corrupt typed payload is retained and cannot be replaced", c do
    locked(c.tmp_dir, fn -> assert :ok = write(c.tmp_dir, c.payload) end)
    path = Path.join(c.tmp_dir, "provisioning.json")
    bytes = File.read!(path) |> JSON.decode!() |> Map.put("deadline", "forever") |> JSON.encode!()
    File.write!(path, bytes)
    assert {:error, _} = Journal.load(Provisioning, c.tmp_dir, "provisioning.json")
    locked(c.tmp_dir, fn -> assert {:error, _} = write(c.tmp_dir, c.payload) end)
    assert File.read!(path) == bytes
  end

  test "expired deadline cannot publish a late ready proof", c do
    payload = %{c.payload | "started_at" => 1}

    locked(c.tmp_dir, fn ->
      assert :ok = write(c.tmp_dir, payload)
      assert :ok = write(c.tmp_dir, %{payload | "state" => "materializing"})

      payload = %{
        payload
        | "boot_challenge" => String.duplicate("a", 64),
          "launched_at" => 1,
          "deadline" => 2
      }

      for state <- ~w(launching awaiting_trust awaiting_ssh),
          do: assert(:ok = write(c.tmp_dir, %{payload | "state" => state}))

      assert {:error, _} =
               write(c.tmp_dir, %{
                 payload
                 | "state" => "ready",
                   "boot_id" => Lilly.UUID.generate()
               })
    end)
  end

  @spec step(model(), atom()) :: {boolean(), map(), model()}
  defp step(model, :replay), do: {true, model.payload, model}

  defp step(model, :extend_deadline),
    do: {false, Map.update!(model.payload, "deadline", &((&1 || 0) + 1)), model}

  defp step(model, :stale_generation), do: {false, Map.put(model.payload, "generation", 0), model}

  defp step(model, :wrong_boot),
    do: {false, Map.put(model.payload, "boot_challenge", "wrong"), model}

  defp step(model, :retire),
    do: {true, Map.put(model.payload, "state", "superseded"), %{model | retired: true}}

  defp step(model, :fail) do
    allowed = not model.retired and not MapSet.member?(model.effects, :receipt)
    {allowed, Map.put(model.payload, "state", "failed"), %{model | failed: true}}
  end

  defp step(model, command) do
    prerequisites = %{
      disk: [],
      launch: [:disk],
      trust: [:disk, :launch],
      ssh: [:disk, :launch, :trust],
      receipt: [:disk, :launch, :trust, :ssh]
    }

    states = %{
      disk: "materializing",
      launch: "launching",
      trust: "awaiting_trust",
      ssh: "awaiting_ssh",
      receipt: "ready"
    }

    allowed =
      not model.retired and not model.failed and
        MapSet.equal?(model.effects, MapSet.new(Map.fetch!(prerequisites, command)))

    proposal = Map.put(model.payload, "state", Map.fetch!(states, command))

    proposal =
      if command == :launch,
        do:
          Map.merge(proposal, %{
            "boot_challenge" => String.duplicate("a", 64),
            "launched_at" => model.payload["started_at"],
            "deadline" => model.payload["started_at"] + 120_000
          }),
        else: proposal

    proposal =
      if command == :receipt,
        do: Map.put(proposal, "boot_id", Lilly.UUID.generate()),
        else: proposal

    # An exact duplicate phase is an idempotent publication, irrespective of
    # terminality. It cannot establish any new prerequisite.
    {allowed or proposal == model.payload, proposal,
     %{model | effects: MapSet.put(model.effects, command)}}
  end

  defp write(directory, payload),
    do: Journal.write(Provisioning, directory, "provisioning.json", payload)

  @spec locked(Path.t(), (-> result)) :: result when result: term()
  defp locked(directory, fun) do
    {:ok, lock} = Lock.acquire(directory)

    try do
      fun.()
    after
      Lock.release(lock)
    end
  end

  test "an agentless boot reaches unattested with a challenge and can never become ready", c do
    directory = c.tmp_dir
    nonce = String.duplicate("c", 64)

    locked(directory, fn ->
      assert :ok = write(directory, c.payload)
      assert :ok = write(directory, %{c.payload | "state" => "materializing"})

      payload = %{
        c.payload
        | "state" => "launching",
          "boot_challenge" => nonce,
          "launched_at" => c.payload["started_at"],
          "deadline" => c.payload["started_at"] + 120_000
      }

      assert :ok = write(directory, payload)
      # unattested follows awaiting_trust only, never launching or awaiting_ssh.
      assert {:error, _} = write(directory, %{payload | "state" => "unattested"})
      assert :ok = write(directory, %{payload | "state" => "awaiting_trust"})

      # An unattested record never carries a guest boot UUID.
      assert {:error, _} =
               write(directory, %{
                 payload
                 | "state" => "unattested",
                   "boot_id" => Lilly.UUID.generate()
               })

      assert :ok = write(directory, %{payload | "state" => "unattested"})
      assert :ok = write(directory, %{payload | "state" => "unattested"})

      for state <- ~w(awaiting_ssh awaiting_trust) do
        assert {:error, _} = write(directory, %{payload | "state" => state})
      end

      assert {:error, _} =
               write(directory, %{
                 payload
                 | "state" => "ready",
                   "boot_id" => Lilly.UUID.generate()
               })

      assert :ok = write(directory, %{payload | "state" => "superseded"})
    end)

    assert {:ok, %{state: :superseded}} =
             Journal.load(Provisioning, directory, "provisioning.json")
  end
end
