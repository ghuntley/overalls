defmodule Marshall.CredentialRetirementFixture do
  @moduledoc "Disposable committed fixtures for registration and retirement ordering."
  alias Marshall.Accounts.{User, UserDeletion}
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  alias Marshall.SSH
  alias Marshall.SSH.{Approval, Key, Session, Token}

  @type operation :: :manual | :approval
  @type gate_kind :: :registration | :retirement
  @type registration :: %{
          public_key: String.t(),
          gateway_id: String.t(),
          gateway_token: String.t(),
          session_id: String.t(),
          session_token: String.t(),
          approval_token: String.t()
        }
  @type snapshot :: %{
          retired: boolean(),
          keys: [{String.t(), String.t(), boolean()}],
          versions: [{String.t(), atom(), atom() | nil, String.t() | nil}],
          approvals: [{String.t(), String.t() | nil, boolean()}],
          sessions: [{String.t(), String.t() | nil}],
          deletions: [{String.t(), boolean(), non_neg_integer(), boolean()}],
          events: [{String.t(), String.t(), atom()}]
        }

  @spec registration(binary()) :: registration()
  def registration(bytes \\ :crypto.strong_rand_bytes(32)) do
    public_key = "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, bytes::binary>>)
    {gateway_token, _} = Token.issue(:gateway)

    {:ok, gateway} =
      SSH.configure_gateway(%{name: "credential-" <> Ash.UUID.generate(), token: gateway_token},
        actor: SystemActor.compute()
      )

    {:ok, pending} =
      SSH.open_session(%{gateway_token: gateway_token, public_key: public_key},
        actor: SystemActor.compute()
      )

    %{
      public_key: public_key,
      gateway_id: gateway.id,
      gateway_token: gateway_token,
      session_id: pending.session_id,
      session_token: pending.session_token,
      approval_token: String.replace_prefix(pending.approval_path, "/ssh/approve/", "")
    }
  end

  @spec register(operation(), registration(), User.t()) :: {:ok, map()} | {:error, term()}
  def register(:manual, fixture, actor),
    do: SSH.add_key(%{public_key: fixture.public_key, label: "disposable-fixture"}, actor: actor)

  def register(:approval, fixture, actor),
    do:
      SSH.approve_key(%{token: fixture.approval_token, label: "disposable-fixture"}, actor: actor)

  @spec retire(User.t(), User.t()) :: {:ok, map()} | {:error, term()}
  def retire(admin, account) do
    User
    |> Ash.ActionInput.for_action(
      :delete_user,
      %{user_id: account.id, confirmation: to_string(account.email)},
      actor: admin
    )
    |> Ash.run_action()
  end

  @spec complete(String.t()) :: {:ok, map()} | {:error, term()}
  def complete(id),
    do:
      Marshall.Accounts.DeleteUserMachines.run(
        %Ash.ActionInput{arguments: %{primary_key: %{"id" => id}}},
        [],
        %{actor: SystemActor.compute()}
      )

  @spec retire_and_complete(User.t(), User.t()) :: {:ok, map()} | {:error, term()}
  def retire_and_complete(admin, account) do
    with {:ok, deletion} <- retire(admin, account),
         {:ok, %{complete: true}} <- complete(deletion.id),
         do: {:ok, deletion}
  end

  # @cc [owner:ghuntley,label:verification] credential-real-action-write-gates
  # Disposable gates MUST pause only the selected account's actual production
  # write. They MUST NOT acquire account admission locks for the tested actions.
  @spec install_gate(gate_kind(), String.t(), pos_integer()) :: :ok
  def install_gate(kind, id, gate) do
    id = Ecto.UUID.cast!(id)
    name = name(id)

    {table, event, condition} =
      case kind do
        :registration ->
          {"ssh_keys", "INSERT", "NEW.user_id = TG_ARGV[0]::uuid"}

        :retirement ->
          {"users", "UPDATE OF deleted_at",
           "NEW.id = TG_ARGV[0]::uuid AND NEW.deleted_at IS NOT NULL"}
      end

    query("""
    CREATE FUNCTION #{name}() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF #{condition} THEN
        PERFORM pg_advisory_xact_lock(TG_ARGV[1]::bigint);
      END IF;
      RETURN NEW;
    END;
    $$
    """)

    query("""
    CREATE TRIGGER #{name} BEFORE #{event} ON #{table}
    FOR EACH ROW EXECUTE FUNCTION #{name}('#{id}', '#{gate}')
    """)

    :ok
  end

  @spec remove_gate(gate_kind(), String.t()) :: :ok
  def remove_gate(kind, id) do
    table = if kind == :registration, do: "ssh_keys", else: "users"
    query("DROP TRIGGER IF EXISTS #{name(id)} ON #{table}")
    query("DROP FUNCTION IF EXISTS #{name(id)}()")
    :ok
  end

  @spec snapshot(String.t(), registration()) :: snapshot()
  def snapshot(account_id, fixture) do
    keys = Ledger.history!(Key, user_id: account_id)

    %{
      retired: Marshall.Accounts.Security.current(account_id).deleted_at != nil,
      keys: keys |> Enum.map(&{&1.id, &1.user_id, &1.archived_at != nil}) |> Enum.sort(),
      versions:
        keys
        |> Enum.flat_map(&Ledger.read!(Key.Version, version_source_id: &1.id))
        |> Enum.map(&{&1.version_source_id, &1.version_action_name, &1.actor_kind, &1.actor_id})
        |> Enum.sort(),
      approvals:
        Ledger.read!(Approval, session_id: fixture.session_id)
        |> Enum.map(&{&1.id, &1.user_id, &1.consumed_at != nil}),
      sessions: Ledger.read!(Session, id: fixture.session_id) |> Enum.map(&{&1.id, &1.key_id}),
      deletions:
        Ledger.read!(UserDeletion, user_id: account_id)
        |> Enum.map(&{&1.id, &1.completed_at != nil, &1.remaining, &1.blocked}),
      events:
        Ledger.read!(Marshall.Accounts.AdminEvent, target_id: account_id)
        |> Enum.map(&{&1.actor_id, &1.target_id, &1.kind})
        |> Enum.sort()
    }
  end

  # @cc [owner:ghuntley,label:verification] credential-retirement-fixture-history-ownership
  # Callers MUST finish or stop all remote operations before disposal. Job
  # histories may be deleted only for raw jobs returned by deletion receipts
  # belonging to these owned fixture users; unrelated history MUST survive.
  @spec cleanup(registration(), [User.t()]) :: :ok
  def cleanup(fixture, users) do
    gateway_id = Ecto.UUID.dump!(fixture.gateway_id)

    for table <- ["ssh_approvals", "ssh_sessions"] do
      selector =
        if table == "ssh_approvals",
          do: "session_id IN (SELECT id FROM ssh_sessions WHERE gateway_id=$1)",
          else: "gateway_id=$1"

      query("DELETE FROM #{table} WHERE #{selector}", [gateway_id])
    end

    query("DELETE FROM ssh_gateways WHERE id=$1", [gateway_id])

    for user <- users do
      id = Ecto.UUID.dump!(user.id)

      query(
        "DELETE FROM ssh_keys_versions WHERE version_source_id IN (SELECT id FROM ssh_keys WHERE user_id=$1)",
        [id]
      )

      query("DELETE FROM ssh_keys WHERE user_id=$1", [id])

      Marshall.CommittedFixtureCleanup.subscription_reviews!([user.id])

      for deletion <- Ledger.read!(UserDeletion, user_id: user.id) do
        Marshall.CommittedFixtureCleanup.jobs!("args->'primary_key'->>'id'=$1", [deletion.id])
      end

      query("DELETE FROM account_user_deletions WHERE user_id=$1", [id])
      Marshall.PasskeyFixture.cleanup(user)
      query("DELETE FROM account_admin_events WHERE actor_id=$1 OR target_id=$1", [id])
      query("DELETE FROM users WHERE id=$1", [id])
    end

    :ok
  end

  @spec query(String.t(), [term()]) :: Postgrex.Result.t()
  def query(sql, params \\ []),
    do: Ecto.Adapters.SQL.query!(Marshall.Repo, sql, params, log: false)

  @spec name(String.t()) :: String.t()
  defp name(id), do: "credential_retire_gate_" <> String.replace(Ecto.UUID.cast!(id), "-", "_")
end
