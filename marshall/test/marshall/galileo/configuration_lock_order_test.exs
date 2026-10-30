defmodule Marshall.Galileo.ConfigurationLockOrderTest do
  @moduledoc """
  Committed lock-order regression for Galileo configuration against guest rosters.

  A guest roster pull (`Marshall.SSH.GuestAccess.roster/2`) locks the VM row
  and then its writers' User rows. A real holder transaction takes the same
  VM lock on its own connection while the production configure or attach
  action runs on another. Once that action is blocked, the holder takes the
  User row lock with NOWAIT. It must be free: an action that already holds a
  User key-share lock while it waits on the VM is the observed deadlock.
  """
  use ExUnit.Case, async: false
  alias Marshall.Galileo
  alias Marshall.GalileoPeerFixture, as: Fixture
  alias Marshall.Repo

  @moduletag :distributed
  @moduletag timeout: 120_000

  @type probe :: :acquired | atom()

  # @cc [owner:ghuntley,label:verification] galileo-lock-order-fixture-preservation
  # Every case MUST restore the complete pre-test committed row inventory.
  setup do
    before =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, &Marshall.CommittedFixtureInventory.snapshot/0)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        Marshall.CommittedFixtureInventory.assert_restored!(before)
      end)
    end)

    :ok
  end

  # @cc [owner:ghuntley,label:verification;concurrency] galileo-configure-vm-before-user
  # A peer configuration blocked behind a roster's VM lock MUST NOT hold any
  # lock on the actor's User row, and MUST complete once the VM is released.
  test "peer configuration waits for the VM before referencing the owner" do
    fixture = unboxed(&Fixture.create/0)
    name = "peer-order-" <> binary_part(Ash.UUID.generate(), 0, 12)
    on_exit(fn -> unboxed(fn -> cleanup!(fixture, name) end) end)

    {probe, result} =
      contend(fixture, fn ->
        Galileo.configure_integration(
          %{
            name: name,
            target: nil,
            headers: [],
            peer: true,
            peer_vm_id: fixture.vm.id,
            idempotency_key: Ash.UUID.generate()
          },
          actor: fixture.owner
        )
      end)

    assert probe == :acquired
    assert {:ok, %Galileo.Integration{peer_vm_id: vm_id}} = result
    assert vm_id == fixture.vm.id
  end

  # @cc [owner:ghuntley,label:verification;concurrency] galileo-attach-vm-before-user
  # An attachment blocked behind a roster's VM lock MUST NOT hold any lock on
  # the attaching User row, and MUST complete once the VM is released.
  test "attachment waits for the VM before referencing the attaching user" do
    fixture = unboxed(&Fixture.create/0)
    on_exit(fn -> unboxed(fn -> cleanup!(fixture, nil) end) end)

    {probe, result} =
      contend(fixture, fn ->
        Galileo.attach_integration(%{name: fixture.integration.name, vm_id: fixture.vm.id},
          actor: fixture.owner
        )
      end)

    assert probe == :acquired
    assert {:ok, %{attached: _, vm_id: vm_id}} = result
    assert vm_id == fixture.vm.id
  end

  # Holds the VM row as a roster does, runs `action` until it blocks on that
  # lock, then probes the User row the roster would lock next.
  @spec contend(Fixture.t(), (-> term())) :: {probe(), term()}
  defp contend(fixture, action) do
    parent = self()
    vm = Ecto.UUID.dump!(fixture.vm.id)
    user = Ecto.UUID.dump!(fixture.owner.id)

    holder =
      Task.async(fn ->
        unboxed(fn ->
          {:error, probe} =
            Repo.transaction(fn ->
              %{rows: [[pid]]} = Repo.query!("SELECT pg_backend_pid()", [], log: false)

              Repo.query!(
                "SELECT 1 FROM compute_virtual_machines WHERE id=$1 FOR UPDATE",
                [vm],
                log: false
              )

              send(parent, {:holding, pid})

              receive do
                :probe -> :ok
              after
                30_000 -> raise "lock-order probe was never released"
              end

              Repo.rollback(probe_user(user))
            end)

          probe
        end)
      end)

    pid =
      receive do
        {:holding, pid} -> pid
      after
        30_000 -> raise "lock-order holder did not start"
      end

    contender = Task.async(fn -> unboxed(action) end)
    await_blocked!(pid, System.monotonic_time(:millisecond) + 30_000)
    send(holder.pid, :probe)
    probe = Task.await(holder, 60_000)
    {probe, Task.await(contender, 60_000)}
  end

  @spec probe_user(binary()) :: probe()
  defp probe_user(user) do
    Repo.query!("SELECT 1 FROM users WHERE id=$1 FOR UPDATE NOWAIT", [user], log: false)
    :acquired
  rescue
    error in Postgrex.Error -> error.postgres.code
  end

  @spec await_blocked!(integer(), integer()) :: :ok
  defp await_blocked!(pid, deadline) do
    %{rows: [[count]]} =
      unboxed(fn ->
        Repo.query!(
          "SELECT count(*) FROM pg_stat_activity WHERE $1 = ANY(pg_blocking_pids(pid))",
          [pid],
          log: false
        )
      end)

    cond do
      count > 0 ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        raise "contending action never blocked on the held VM row"

      true ->
        Process.sleep(20)
        await_blocked!(pid, deadline)
    end
  end

  @spec cleanup!(Fixture.t(), String.t() | nil) :: :ok
  defp cleanup!(fixture, peer_name) do
    vm = Ecto.UUID.dump!(fixture.vm.id)

    for statement <- [
          "DELETE FROM galileo_attachments_versions WHERE version_source_id IN (SELECT id FROM galileo_attachments WHERE vm_id=$1)",
          "DELETE FROM galileo_attachments WHERE vm_id=$1"
        ],
        do: Repo.query!(statement, [vm], log: false)

    if peer_name do
      %{rows: rows} =
        Repo.query!("SELECT id FROM galileo_integrations WHERE name=$1", [peer_name], log: false)

      for [id] <- rows,
          statement <- [
            "DELETE FROM galileo_integration_headers WHERE integration_id=$1",
            "DELETE FROM account_admin_events WHERE target_id=$1",
            "DELETE FROM galileo_integrations_versions WHERE version_source_id=$1",
            "DELETE FROM galileo_integrations WHERE id=$1"
          ],
          do: Repo.query!(statement, [id], log: false)
    end

    Repo.query!(
      "DELETE FROM account_admin_events WHERE target_id=$1",
      [Ecto.UUID.dump!(fixture.integration.id)],
      log: false
    )

    Fixture.cleanup(fixture)
  end

  @spec unboxed((-> value)) :: value when value: term()
  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)
end
