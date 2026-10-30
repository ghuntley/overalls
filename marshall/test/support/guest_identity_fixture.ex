defmodule Marshall.GuestIdentityFixture do
  @moduledoc "Committed identity fixtures with target-specific production SQL gates."
  alias Marshall.Accounts.{GuestAccount, GuestAccounts, Security, User, UserDeletion}
  alias Marshall.Compute.Ledger
  alias Marshall.Repo
  alias Marshall.CommittedFixtureCleanup, as: Cleanup
  require Ash.Query

  @type gate_kind :: :allocation | :retirement
  @type roster_fixture :: %{
          owner: User.t(),
          created_image_ids: [String.t()],
          host_id: String.t(),
          vm_id: String.t(),
          token: String.t(),
          binding: %{String.t() => String.t() | integer()}
        }
  @type snapshot :: %{
          users: [{String.t(), boolean()}],
          accounts: [{String.t(), String.t(), String.t(), integer(), boolean()}]
        }

  # @cc [owner:ghuntley,label:verification;concurrency] guest-identity-production-gates
  # Write gates MUST pause only their target's real allocation or retirement
  # statement. They MUST NOT obtain namespace or account locks for production.
  # User-row blockers are only the explicit sorted-order observation fixture.
  @spec install_gate(gate_kind(), String.t(), pos_integer()) :: :ok
  def install_gate(kind, target, gate) do
    target = Ecto.UUID.cast!(target)
    name = name(target)

    {table, event, condition} =
      case kind do
        :allocation ->
          {"account_guest_accounts", "INSERT", "NEW.user_id=TG_ARGV[0]::uuid"}

        :retirement ->
          {"users", "UPDATE OF deleted_at",
           "NEW.id=TG_ARGV[0]::uuid AND NEW.deleted_at IS NOT NULL"}
      end

    query("""
    CREATE FUNCTION #{name}() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF #{condition} THEN PERFORM pg_advisory_xact_lock(TG_ARGV[1]::bigint); END IF;
      RETURN NEW;
    END;
    $$
    """)

    query(
      "CREATE TRIGGER #{name} BEFORE #{event} ON #{table} FOR EACH ROW EXECUTE FUNCTION #{name}('#{target}', '#{gate}')"
    )

    :ok
  end

  @spec remove_gate(gate_kind(), String.t()) :: :ok
  def remove_gate(kind, target) do
    table = if kind == :allocation, do: "account_guest_accounts", else: "users"
    query("DROP TRIGGER IF EXISTS #{name(target)} ON #{table}")
    query("DROP FUNCTION IF EXISTS #{name(target)}()")
    :ok
  end

  @spec allocate(String.t()) :: {:ok, GuestAccount.t()} | {:error, term()}
  def allocate(id), do: Ledger.transaction(fn -> GuestAccounts.ensure!(id) end)

  @spec hold_user(String.t(), pos_integer()) :: {:ok, :ok} | {:error, term()}
  def hold_user(id, gate) do
    Ledger.transaction(fn ->
      Security.lock_user!(id)
      query("SELECT pg_advisory_xact_lock($1)", [gate])
      :ok
    end)
  end

  @spec retire(User.t(), User.t()) :: {:ok, map()} | {:error, term()}
  def retire(admin, user),
    do:
      User
      |> Ash.ActionInput.for_action(
        :delete_user,
        %{user_id: user.id, confirmation: to_string(user.email)},
        actor: admin
      )
      |> Ash.run_action()

  @spec snapshot([String.t()]) :: snapshot()
  def snapshot(ids) do
    %{
      users:
        Enum.map(ids, fn id -> {id, Security.current(id).deleted_at != nil} end) |> Enum.sort(),
      accounts:
        GuestAccount
        |> Ash.Query.filter(user_id in ^ids)
        |> Ash.read!(actor: Marshall.Authorization.SystemActor.compute())
        |> Enum.map(&{&1.id, &1.user_id, &1.username, &1.uid, &1.retired_at != nil})
        |> Enum.sort()
    }
  end

  # @cc [owner:ghuntley,label:verification] guest-identity-roster-fixture-placement
  # Setup MUST commit both fixtures or neither. Only the captured first host is
  # temporarily disabled so the second VM uses its own physical machine identity.
  @spec roster_fixtures!() :: [roster_fixture()]
  def roster_fixtures! do
    {:ok, fixtures} =
      Ledger.transaction(fn ->
        first = roster_fixture!()
        [host] = Ledger.read!(Marshall.Compute.Host, id: first.host_id)
        disabled = Ledger.update!(host, :configure, %{enabled: false})
        second = roster_fixture!()
        Ledger.update!(disabled, :configure, %{enabled: true})
        [first, second]
      end)

    fixtures
  end

  @spec single_roster_fixture!() :: roster_fixture()
  def single_roster_fixture!, do: roster_fixture!()

  @spec roster_fixture!() :: roster_fixture()
  defp roster_fixture! do
    images_before = Cleanup.fixture_image_ids()
    fixture = Marshall.TerminalFixtures.terminal_fixture(%{profile: :standard})
    created_image_ids = Cleanup.fixture_image_ids() -- images_before
    {:ok, credential} = Marshall.Inference.Credentials.rotate(fixture.vm.host_id, 3600)

    %{
      owner: fixture.owner,
      created_image_ids: created_image_ids,
      host_id: fixture.host.id,
      vm_id: fixture.vm.id,
      token: credential.id <> "." <> credential.secret,
      binding: Marshall.TerminalFixtures.roster_binding(fixture.vm)
    }
  end

  @spec share!(roster_fixture(), User.t()) :: :ok
  def share!(fixture, user) do
    {:ok, _} =
      Marshall.Access.set_access(
        %{
          vm_id: fixture.vm_id,
          email: to_string(user.email),
          role: :operator,
          idempotency_key: Ash.UUID.generate()
        },
        actor: fixture.owner
      )

    :ok
  end

  @spec roster(roster_fixture()) :: {:ok, map()} | {:error, term()}
  def roster(fixture), do: Marshall.SSH.GuestAccess.roster(fixture.token, fixture.binding)

  # @cc [owner:ghuntley,label:verification] guest-identity-committed-fixture-cleanup
  # Teardown MUST delete only captured fixture users, hosts and VMs after all
  # gated callers have finished; permanent production reservations are untouched.
  @spec cleanup_users([User.t()]) :: :ok
  def cleanup_users(users) do
    for user <- users do
      id = Ecto.UUID.dump!(user.id)

      query(
        "DELETE FROM account_guest_accounts_versions WHERE version_source_id IN (SELECT id FROM account_guest_accounts WHERE user_id=$1)",
        [id]
      )

      query("DELETE FROM account_guest_accounts WHERE user_id=$1", [id])

      Cleanup.subscription_reviews!([user.id])

      for deletion <- Ledger.read!(UserDeletion, user_id: user.id),
          do: Cleanup.jobs!("args->'primary_key'->>'id'=$1", [deletion.id])

      query("DELETE FROM account_user_deletions WHERE user_id=$1", [id])
      Marshall.PasskeyFixture.cleanup(user)
      query("DELETE FROM account_admin_events WHERE actor_id=$1 OR target_id=$1", [id])
      query("DELETE FROM users WHERE id=$1", [id])
    end

    :ok
  end

  @spec cleanup_rosters([roster_fixture()]) :: :ok
  def cleanup_rosters(fixtures) do
    for fixture <- fixtures do
      Cleanup.agent_history!([fixture.vm_id])
      Cleanup.lifecycle!([fixture.host_id], [fixture.vm_id])
      vm = [Ecto.UUID.dump!(fixture.vm_id)]
      host = [Ecto.UUID.dump!(fixture.host_id)]

      Cleanup.jobs!(
        "args->'primary_key'->>'id' IN (SELECT id::text FROM compute_operations WHERE vm_id=$1)",
        vm
      )

      query("UPDATE compute_operations SET completion_outcome_id=NULL WHERE vm_id=$1", vm)
      query("DELETE FROM compute_physical_outcomes WHERE vm_id=$1", vm)

      for table <- [
            "compute_operations",
            "compute_reservations",
            "compute_network_addresses",
            "access_changes"
          ],
          do: query("DELETE FROM #{table} WHERE vm_id=$1", vm)

      for table <- ["ingress_endpoints", "access_grants"] do
        query(
          "DELETE FROM #{table}_versions WHERE version_source_id IN (SELECT id FROM #{table} WHERE vm_id=$1)",
          vm
        )

        query("DELETE FROM #{table} WHERE vm_id=$1", vm)
      end

      query("DELETE FROM compute_virtual_machines_versions WHERE version_source_id=$1", vm)

      query(
        "WITH removed AS (DELETE FROM compute_workload_placements WHERE vm_id=$1 RETURNING vm_id) DELETE FROM compute_virtual_machines WHERE id IN (SELECT vm_id FROM removed)",
        vm
      )

      query("DELETE FROM compute_storage_pools WHERE host_id=$1", host)

      query(
        "DELETE FROM compute_host_credentials_versions WHERE version_source_id IN (SELECT id FROM compute_host_credentials WHERE host_id=$1)",
        host
      )

      query(
        "DELETE FROM inference_credentials_versions WHERE version_source_id IN (SELECT id FROM inference_credentials WHERE host_id=$1)",
        host
      )

      for table <- ["compute_host_credentials", "compute_host_sessions", "inference_credentials"],
          do: query("DELETE FROM #{table} WHERE host_id=$1", host)

      query("DELETE FROM compute_hosts WHERE id=$1", host)
    end

    cleanup_users(Enum.map(fixtures, & &1.owner))
    Cleanup.images!(Enum.flat_map(fixtures, & &1.created_image_ids))

    :ok
  end

  @spec query(String.t(), [term()]) :: Postgrex.Result.t()
  def query(sql, params \\ []), do: Ecto.Adapters.SQL.query!(Repo, sql, params, log: false)

  @spec name(String.t()) :: String.t()
  defp name(id), do: "guest_identity_gate_" <> String.replace(Ecto.UUID.cast!(id), "-", "_")
end
