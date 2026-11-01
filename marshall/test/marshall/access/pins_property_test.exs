defmodule Marshall.Access.PinsPropertyTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  import Marshall.ComputeFixtures
  @moduletag capture_log: true
  @moduletag timeout: 300_000
  @moduletag hegel_case_sandbox: true

  alias Marshall.{Access, Compute, SSH}
  alias Marshall.Access.{Pin, Pins}
  alias Marshall.Accounts.User
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.{Host, Ledger, Operation, Outcomes, VirtualMachine}
  alias Marshall.SSH.Token

  @type holder :: :owner | :member
  @type guard_command ::
          {:pin, holder()} | {:unpin, holder()} | {:delete, holder(), :api | :ssh}
  @type guard_model :: %{owner: boolean(), member: boolean(), deleted: boolean()}

  @type pin_command :: {:pin | :unpin, :alice | :bob, non_neg_integer()}
  @type pin_model :: %{alice: [String.t()], bob: [String.t()]}

  # @cc [owner:ghuntley,label:verification] pin-generated-fixture-isolation
  # Every generated case and replay MUST start its own SQL sandbox before creating
  # hosts, users or gateway authority and release that owner before the next case.
  @spec property_fixture() :: String.t()
  defp property_fixture do
    isolate_property_case()
    host_fixture()
    {gateway_token, _} = Token.issue(:gateway)

    {:ok, _} =
      SSH.configure_gateway(%{name: "pins-fixture", token: gateway_token},
        actor: SystemActor.compute()
      )

    gateway_token
  end

  @spec guard_commands() :: Hegel.Gen.t(guard_command())
  defp guard_commands do
    one_of([
      tuple({constant(:pin), member_of([:owner, :member])}),
      tuple({constant(:unpin), member_of([:owner, :member])}),
      tuple({constant(:delete), member_of([:owner, :member]), member_of([:api, :ssh])})
    ])
  end

  # @cc [owner:ghuntley,label:verification] pin-guard-history-oracle
  # Generated owner/member pin histories MUST drive the real Access pin actions
  # and the real lifecycle delete through both the domain action and the SSH
  # command path. The expected admission of every delete is computed by this
  # boolean model before the command runs: admitted iff the owner's model pin is
  # absent, whatever the member holds. A refusal MUST leave intent unchanged and
  # enqueue nothing; an admission MUST then archive every live pin on the VM once
  # the deleted outcome arrives.
  test "deletion is admitted exactly when the owner's pin is absent" do
    Hegel.check(
      fn ->
        gateway_token = property_fixture()
        commands = draw("commands", list_of(guard_commands(), min_length: 4, max_length: 16))
        host_fixture()
        owner = user()
        member = user()
        {:ok, vm} = Compute.provision(request(), actor: owner)
        share!(vm, owner, member, :manager)

        sessions = %{
          owner: session(owner, gateway_token),
          member: session(member, gateway_token)
        }

        model = %{owner: false, member: false, deleted: false}

        model =
          Enum.reduce(commands, model, fn command, model ->
            step(command, model, vm, %{owner: owner, member: member}, sessions)
          end)

        if model.deleted do
          assert [%{desired_state: :deleted}] = Ledger.read!(VirtualMachine, id: vm.id)
          [delete] = Enum.filter(Ledger.read!(Operation, vm_id: vm.id), &(&1.kind == :delete))
          assert {:ok, _} = ingest(vm.host_id, outcome(delete, 1, :deleted))
          assert [] = Ledger.read!(Pin, vm_id: vm.id)
          assert [] = Ledger.read!(VirtualMachine, id: vm.id)
          assert Enum.all?(Ledger.history!(Pin, vm_id: vm.id), &(&1.archived_at != nil))
        else
          assert [%{desired_state: :running}] = Ledger.read!(VirtualMachine, id: vm.id)
          assert [] = Enum.filter(Ledger.read!(Operation, vm_id: vm.id), &(&1.kind == :delete))
        end

        assert Pins.owner_pinned?(vm) == (model.owner and not model.deleted)
      end,
      test_cases: 100
    )
  end

  @spec step(guard_command(), guard_model(), VirtualMachine.t(), map(), map()) :: guard_model()
  defp step({:pin, holder}, model, vm, actors, _sessions) do
    case Access.pin_machine(%{vm_id: vm.id}, actor: actors[holder]) do
      {:ok, %Pin{state: :pinned}} ->
        refute model.deleted
        Map.put(model, holder, true)

      {:error, error} ->
        assert model.deleted
        assert Exception.message(error) =~ "vm_deleted"
        model
    end
  end

  defp step({:unpin, holder}, model, vm, actors, _sessions) do
    case Access.unpin_machine(%{vm_id: vm.id}, actor: actors[holder]) do
      {:ok, %Pin{state: :unpinned}} ->
        assert live_row?(vm, actors[holder])
        Map.put(model, holder, false)

      {:error, error} ->
        refute live_row?(vm, actors[holder])
        assert Exception.message(error) =~ "forbidden"
        model
    end
  end

  defp step({:delete, holder, path}, model, vm, actors, sessions) do
    before = Ledger.read!(Operation, vm_id: vm.id)
    result = delete(path, vm, actors[holder], sessions[holder])

    cond do
      model.deleted ->
        # Deleted intent is terminal; a second delete is refused or replays.
        assert match?({:error, _}, result) or match?({:ok, _}, result)
        assert Ledger.read!(Operation, vm_id: vm.id) == before
        model

      model.owner ->
        assert {:error, reason} = result
        assert reason =~ "machine_pinned"
        assert Ledger.read!(Operation, vm_id: vm.id) == before
        assert [%{desired_state: :running}] = Ledger.read!(VirtualMachine, id: vm.id)
        model

      true ->
        assert {:ok, _} = result
        assert [%{desired_state: :deleted}] = Ledger.read!(VirtualMachine, id: vm.id)
        assert length(Ledger.read!(Operation, vm_id: vm.id)) == length(before) + 1
        # Pins other than the owner's survive until the archive.
        assert live_row?(vm, actors.member) ==
                 (model.member or not is_nil(row(vm, actors.member)))

        %{model | deleted: true}
    end
  end

  @spec delete(:api | :ssh, VirtualMachine.t(), User.t(), String.t()) ::
          {:ok, term()} | {:error, String.t()}
  defp delete(:api, vm, actor, _session) do
    case Compute.lifecycle(
           %{vm_id: vm.id, kind: :delete, idempotency_key: Ash.UUID.generate()},
           actor: actor
         ) do
      {:ok, operation} -> {:ok, operation}
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  defp delete(:ssh, vm, _actor, session) do
    {:ok, command} =
      OverallsProtocol.SSHCommand.parse("rm #{vm.id} --request-id #{Ash.UUID.generate()}")

    case SSH.execute(
           %{
             gateway_token: session.gateway_token,
             session_token: session.session_token,
             command: command |> Jason.encode!() |> Jason.decode!()
           },
           actor: SystemActor.compute()
         ) do
      {:ok, receipt} -> {:ok, receipt}
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  @spec pin_commands() :: Hegel.Gen.t(pin_command())
  defp pin_commands,
    do: tuple({member_of([:pin, :unpin]), member_of([:alice, :bob]), integer(0..2)})

  # @cc [owner:ghuntley,label:verification] pin-state-model-oracle
  # Generated pin/unpin histories for two users over three machines MUST match
  # an ordered-set model: a pin moves the machine to the front of that user's
  # list unless already pinned, an unpin removes it, repeats change nothing,
  # each user/VM pair keeps at most one live row, and `pinned_vm_ids/1` and the
  # pinned view return exactly the model order and never another user's pins.

  # The full 100-case isolated run measured 276 seconds; the default profile's
  # 30s heuristic counted SQL body costs and stopped after only seven cases.
  # At hegel-erlang 44b4c8e / engine 0.43.7, CI derandomizes (one fixed seed for
  # every property: hegel_ex sets no database key; HEGEL_SEED overrides it),
  # disables the example database and only suppresses TooSlow. Shrinking/blob replay and other
  # health checks remain. Keep all cases, the SQL deadline and complete oracle.
  @tag timeout: 600_000
  property "pin histories match the per-user ordered-set model", profile: :ci, test_cases: 100 do
    property_fixture()
    commands = draw("commands", list_of(pin_commands(), min_length: 3, max_length: 20))
    # Each synthetic host admits two of these machines.
    for _ <- 1..2, do: host_fixture()
    alice = user()
    bob = user()

    vms =
      for _ <- 0..2 do
        {:ok, vm} = Compute.provision(request(), actor: alice)
        share!(vm, alice, bob, :viewer)
        vm
      end

    actors = %{alice: alice, bob: bob}

    model =
      Enum.reduce(commands, %{alice: [], bob: []}, fn {action, who, index}, model ->
        vm = Enum.at(vms, index)
        actor = actors[who]
        pinned? = vm.id in model[who]

        case action do
          :pin ->
            assert {:ok, %Pin{state: :pinned}} =
                     Access.pin_machine(%{vm_id: vm.id}, actor: actor)

          :unpin ->
            case Access.unpin_machine(%{vm_id: vm.id}, actor: actor) do
              {:ok, %Pin{state: :unpinned}} -> assert live_row?(vm, actor)
              {:error, _} -> refute live_row?(vm, actor)
            end
        end

        expected =
          case action do
            :pin when pinned? -> model[who]
            :pin -> [vm.id | model[who]]
            :unpin -> List.delete(model[who], vm.id)
          end

        model = Map.put(model, who, expected)
        assert_model(model, actors, vms)
        model
      end)

    assert_model(model, actors, vms)
  end

  @spec assert_model(pin_model(), map(), [VirtualMachine.t()]) :: :ok
  defp assert_model(model, actors, vms) do
    for {who, actor} <- actors do
      assert Pins.pinned_vm_ids(actor) == model[who]
      assert {:ok, %{items: items}} = Compute.pinned_vms(%{}, actor: actor)
      assert Enum.map(items, & &1.id) == model[who]
      assert Enum.all?(items, & &1.pinned)

      for vm <- vms do
        assert length(Ledger.read!(Pin, vm_id: vm.id, user_id: actor.id)) <= 1
        assert {:ok, %{pinned: pinned}} = Compute.get_vm(%{vm_id: vm.id}, actor: actor)
        assert pinned == vm.id in model[who]
      end
    end

    :ok
  end

  # @cc [owner:ghuntley,label:verification] pin-ordering-pagination-oracle
  # For a random pinned subset of a user's machines and random page sizes, the
  # pinned section followed by the excluded keyset pages MUST yield every
  # authorized machine exactly once, pinned machines first in pin order and the
  # rest in id order, independent of the page size.
  property "pinned section plus excluded pages covers each machine once", test_cases: 100 do
    property_fixture()
    pin_order = draw("pin_order", list_of(integer(0..5), min_length: 0, max_length: 8))
    page_size = draw("page_size", integer(1..4))
    for _ <- 1..3, do: host_fixture()
    owner = user()

    vms =
      for _ <- 0..5 do
        {:ok, vm} = Compute.provision(request(), actor: owner)
        vm
      end

    pinned_ids =
      Enum.reduce(pin_order, [], fn index, acc ->
        vm = Enum.at(vms, index)
        assert {:ok, _} = Access.pin_machine(%{vm_id: vm.id}, actor: owner)
        if vm.id in acc, do: acc, else: [vm.id | acc]
      end)

    assert {:ok, %{items: pinned}} = Compute.pinned_vms(%{}, actor: owner)
    assert Enum.map(pinned, & &1.id) == pinned_ids

    pages = collect_pages(owner, page_size, pinned_ids, nil, [])
    rest = Enum.map(pages, & &1.id)
    assert rest == Enum.sort(rest)
    assert rest == Enum.sort(Enum.map(vms, & &1.id) -- pinned_ids)
    assert Enum.sort(pinned_ids ++ rest) == Enum.sort(Enum.map(vms, & &1.id))
    assert Enum.all?(pages, &(not &1.pinned))
  end

  @spec collect_pages(User.t(), pos_integer(), [String.t()], String.t() | nil, [map()]) :: [map()]
  defp collect_pages(owner, page_size, exclude, cursor, acc) do
    assert {:ok, page} =
             Compute.list_vms(%{limit: page_size, after: cursor, exclude: exclude}, actor: owner)

    assert length(page.items) <= page_size

    case page.next_cursor do
      nil -> acc ++ page.items
      next -> collect_pages(owner, page_size, exclude, next, acc ++ page.items)
    end
  end

  @spec share!(VirtualMachine.t(), User.t(), User.t(), atom()) :: :ok
  defp share!(vm, owner, recipient, role) do
    assert {:ok, _} =
             Access.set_access(
               %{
                 vm_id: vm.id,
                 email: to_string(recipient.email),
                 role: role,
                 idempotency_key: Ash.UUID.generate()
               },
               actor: owner
             )

    :ok
  end

  @spec session(User.t(), String.t()) :: %{gateway_token: String.t(), session_token: String.t()}
  defp session(actor, gateway_token) do
    blob = <<11::32, "ssh-ed25519", 32::32, :crypto.strong_rand_bytes(32)::binary>>
    public_key = "ssh-ed25519 " <> Base.encode64(blob)
    {:ok, _} = SSH.add_key(%{public_key: public_key}, actor: actor)

    {:ok, session} =
      SSH.open_session(%{gateway_token: gateway_token, public_key: public_key},
        actor: SystemActor.compute()
      )

    %{gateway_token: gateway_token, session_token: session.session_token}
  end

  @spec row(VirtualMachine.t(), User.t()) :: Pin.t() | nil
  defp row(vm, actor), do: List.first(Ledger.read!(Pin, vm_id: vm.id, user_id: actor.id))

  @spec live_row?(VirtualMachine.t(), User.t()) :: boolean()
  defp live_row?(vm, actor), do: row(vm, actor) != nil

  defp ingest(host, event) do
    {:ok, event} =
      OverallsProtocol.Execution.outcome(OverallsProtocol.Execution.encode_outcome(event))

    Ledger.transaction(fn ->
      Ledger.lock!(Host, host)
      Outcomes.ingest_locked!(host, [event])
    end)
  end

  defp outcome(operation, sequence, state) do
    %{
      id: Ash.UUID.generate(),
      vm_id: operation.vm_id,
      placement_id: operation.placement_id,
      execution_epoch: operation.execution_epoch,
      operation_id: operation.id,
      generation: operation.generation,
      sequence: sequence,
      state: state,
      compute_empty: state in [:stopped, :deleted, :failed],
      disk_present: state != :deleted,
      cleanup_complete: state == :deleted,
      reason: :none
    }
  end
end
