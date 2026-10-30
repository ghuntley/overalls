defmodule Marshall.AdminAccountFixture do
  @moduledoc "Disposable administrative account actions and actual audit-write gates."
  alias Marshall.Accounts.{AdminEvent, User}
  alias Marshall.Compute.Ledger
  alias Marshall.JobHistoryFixture

  @type operation :: :role | :sessions | :reset | :retire | :invite | :lock | :signout
  @type action_name ::
          :set_administrator
          | :revoke_sessions_for_admin
          | :reset_mfa
          | :delete_user
          | :invite_user
  @type arguments ::
          %{user_id: String.t(), administrator: boolean()}
          | %{user_id: String.t()}
          | %{user_id: String.t(), confirmation: String.t()}
          | %{email: String.t()}
  @type summary ::
          %{user_id: String.t(), administrator: boolean()}
          | %{user_id: String.t(), revoked: non_neg_integer()}
          | %{reset: true}
          | %{id: String.t(), deleting: true}
          | %{invited: true}
          | %{locked: true}
          | %{status: pos_integer()}
  @type outcome :: JobHistoryFixture.outcome()
  @type inventory :: [{String.t(), String.t()}]
  @type user_projection :: %{
          id: String.t(),
          administrator: boolean(),
          mfa_enabled: boolean(),
          mfa_reset_required: boolean(),
          mfa_generation: non_neg_integer(),
          deleted_at: DateTime.t() | nil,
          email: String.t()
        }
  @type audit_kind ::
          :passkey_add
          | :mfa_verify
          | :grant
          | :revoke
          | :sessions_revoke
          | :mfa_reset
          | :user_delete
          | :user_invite
          | :team_create
          | :team_membership_change
  @type audit_projection :: %{
          id: String.t(),
          actor_id: String.t(),
          target_id: String.t(),
          kind: audit_kind(),
          inserted_at: DateTime.t()
        }
  @type snapshot :: %{
          user: user_projection(),
          audits: [audit_projection()],
          users: inventory(),
          passkeys: inventory(),
          challenges: inventory(),
          verifications: inventory(),
          tokens: inventory(),
          deletions: inventory(),
          emails: inventory(),
          jobs: inventory()
        }

  # @cc [owner:ghuntley,label:verification] admin-account-remote-completion
  # A peer-side completion envelope MUST precede fixture deletion; transport
  # failures require stopping the uncertain peer before cleanup.
  @spec invoke(module(), atom(), [term()]) :: {:completed, outcome()}
  defdelegate invoke(module, function, arguments), to: JobHistoryFixture

  @spec act(operation(), User.t(), User.t()) :: {:ok, summary()} | {:error, term()}
  def act(:role, actor, target),
    do: command(:set_administrator, %{user_id: target.id, administrator: true}, actor)

  def act(:sessions, actor, target),
    do: command(:revoke_sessions_for_admin, %{user_id: target.id}, actor)

  def act(:reset, actor, target), do: command(:reset_mfa, %{user_id: target.id}, actor)

  def act(:retire, actor, target),
    do: command(:delete_user, %{user_id: target.id, confirmation: to_string(target.email)}, actor)

  def act(:invite, actor, target),
    do: command(:invite_user, %{email: to_string(target.email)}, actor)

  def act(:lock, actor, _target), do: Marshall.PasskeyFixture.action(actor, :lock)

  def act(:signout, actor, target),
    do: JobHistoryFixture.act(:signout, 1, actor, target, "unused")

  @spec command(action_name(), arguments(), User.t()) :: {:ok, summary()} | {:error, term()}
  defp command(action, arguments, actor),
    do: User |> Ash.ActionInput.for_action(action, arguments, actor: actor) |> Ash.run_action()

  @spec add_member(User.t(), User.t(), String.t()) ::
          {:ok, %{team_id: String.t(), user_id: String.t(), role: :member}} | {:error, term()}
  def add_member(actor, target, team_id),
    do:
      Marshall.Teams.set_team_member(
        %{
          team_id: team_id,
          email: to_string(target.email),
          role: :member,
          idempotency_key: Ash.UUID.generate()
        },
        actor: actor
      )

  @spec hold_user(String.t(), pos_integer()) :: {:ok, :held} | {:error, term()}
  def hold_user(id, gate),
    do:
      Ledger.transaction(fn ->
        Marshall.Accounts.Security.lock_user!(id)
        query("SELECT pg_advisory_xact_lock($1)", [gate])
        :held
      end)

  @spec hold_admission(String.t(), pos_integer()) :: {:ok, :held} | {:error, term()}
  def hold_admission(id, gate),
    do:
      Ledger.transaction(fn ->
        Marshall.Accounts.AccountLifecycle.admit!(id)
        query("SELECT pg_advisory_xact_lock($1)", [gate])
        :held
      end)

  @spec ordered_consumer(:guest | :mixed_signout, User.t(), User.t()) ::
          {:ok, [Marshall.Accounts.GuestAccount.t()] | %{status: pos_integer()}}
          | {:error, term()}
  def ordered_consumer(:guest, actor, target),
    do:
      Ledger.transaction(fn ->
        Marshall.Accounts.GuestAccounts.ensure_all!([actor.id, target.id])
      end)

  def ordered_consumer(:mixed_signout, actor, target) do
    {:ok, remembered, _} =
      AshAuthentication.Jwt.token_for_user(target, %{}, purpose: :remember_me)

    strategy = AshAuthentication.Info.strategy!(User, :remember_me)

    conn =
      Plug.Test.conn(:get, "/sign-out")
      |> Plug.Conn.put_req_header("cookie", "#{strategy.cookie_name}=#{remembered}")
      |> Plug.Test.init_test_session(%{"user_token" => actor.__metadata__.token})
      |> Plug.Conn.assign(:current_user, actor)
      |> Phoenix.Controller.fetch_flash()
      |> MarshallWeb.AuthController.sign_out(%{})

    {:ok, %{status: conn.status}}
  end

  @spec snapshot(User.t(), User.t()) :: snapshot()
  def snapshot(actor, target) do
    ids = Enum.map([actor.id, target.id], &Ecto.UUID.dump!/1)
    subjects = Enum.map([actor.id, target.id], &("user?id=" <> &1))
    fingerprint = fingerprint(target)
    user = Marshall.Accounts.Security.current(target.id)

    %{
      user: %{
        id: user.id,
        administrator: user.administrator,
        mfa_enabled: user.mfa_enabled,
        mfa_reset_required: user.mfa_reset_required,
        mfa_generation: user.mfa_generation,
        deleted_at: user.deleted_at,
        email: to_string(user.email)
      },
      audits:
        Ledger.read!(AdminEvent, actor_id: actor.id)
        |> Enum.map(fn row ->
          %{
            id: row.id,
            actor_id: row.actor_id,
            target_id: row.target_id,
            kind: row.kind,
            inserted_at: row.inserted_at
          }
        end)
        |> Enum.sort_by(& &1.id),
      users: digest("users", "id = ANY($1)", [ids]),
      passkeys: digest("account_passkeys", "user_id = ANY($1)", [ids]),
      challenges: digest("account_passkey_challenges", "user_id = ANY($1)", [ids]),
      verifications: digest("account_verifications", "user_id = ANY($1)", [ids]),
      tokens: digest("tokens", "subject = ANY($1) OR subject = 'user'", [subjects], "jti"),
      deletions: digest("account_user_deletions", "user_id = ANY($1)", [ids]),
      emails: digest("account_auth_emails", "recipient_fingerprint = $1", [fingerprint]),
      jobs:
        digest(
          "oban_jobs",
          "args->'primary_key'->>'id' IN (SELECT id::text FROM account_user_deletions WHERE user_id = ANY($1)) OR args->'primary_key'->>'id' IN (SELECT id::text FROM account_auth_emails WHERE recipient_fingerprint = $2)",
          [ids, fingerprint]
        )
    }
  end

  @spec digest(String.t(), String.t(), [term()], String.t()) :: inventory()
  defp digest(table, predicate, parameters, key \\ "id") do
    query(
      "SELECT md5(#{key}::text), md5(row_to_json(t)::text) FROM #{table} t WHERE #{predicate} ORDER BY #{key}",
      parameters
    ).rows
    |> Enum.map(fn [identity, value] when is_binary(identity) and is_binary(value) ->
      {identity, value}
    end)
  end

  @spec fingerprint(User.t()) :: String.t()
  defp fingerprint(target),
    do:
      :crypto.mac(
        :hmac,
        :sha256,
        Application.fetch_env!(:marshall, :token_signing_secret),
        String.downcase(to_string(target.email))
      )
      |> Base.encode16(case: :lower)

  # @cc [owner:ghuntley,label:verification] admin-account-audit-gate
  # The trigger MUST pause the real audit write after admission checks and MUST
  # supply no account or authority locks to the production operation.
  @spec install_gate(operation() | :team_member, User.t(), pos_integer()) :: :ok
  def install_gate(operation, actor, gate) do
    actor_id = Ecto.UUID.cast!(actor.id)

    {table, event, condition} =
      case operation do
        :team_member ->
          {"team_members", "INSERT", "NEW.user_id = '#{actor_id}'::uuid"}

        :lock ->
          {"account_verifications", "UPDATE",
           "NEW.user_id = '#{actor_id}'::uuid AND NEW.elevated_until IS NULL"}

        :signout ->
          {"tokens", "UPDATE",
           "NEW.subject = 'user?id=#{actor_id}' AND NEW.purpose = 'revocation'"}

        _ ->
          {"account_admin_events", "INSERT", "NEW.actor_id = '#{actor_id}'::uuid"}
      end

    query(
      "CREATE FUNCTION #{name(gate)}() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF #{condition} THEN PERFORM pg_advisory_xact_lock(#{gate}); END IF; RETURN NEW; END; $$"
    )

    query(
      "CREATE TRIGGER #{name(gate)} BEFORE #{event} ON #{table} FOR EACH ROW EXECUTE FUNCTION #{name(gate)}()"
    )

    :ok
  end

  @spec remove_gate(operation() | :team_member, pos_integer()) :: :ok
  def remove_gate(operation, gate) do
    table =
      case operation do
        :team_member -> "team_members"
        :lock -> "account_verifications"
        :signout -> "tokens"
        _ -> "account_admin_events"
      end

    query("DROP TRIGGER IF EXISTS #{name(gate)} ON #{table}")
    query("DROP FUNCTION IF EXISTS #{name(gate)}()")
    :ok
  end

  @spec cleanup([User.t()]) :: :ok
  def cleanup(users) do
    for user <- users do
      id = Ecto.UUID.dump!(user.id)

      query(
        "DELETE FROM account_guest_accounts_versions WHERE version_source_id IN (SELECT id FROM account_guest_accounts WHERE user_id=$1)",
        [id]
      )

      query("DELETE FROM account_guest_accounts WHERE user_id=$1", [id])
      mails = Ledger.read!(Marshall.Accounts.AuthEmail, recipient_fingerprint: fingerprint(user))

      for mail <- mails do
        %{payload: %{"token" => token}} =
          Ash.load!(mail, :payload, actor: Marshall.Authorization.SystemActor.compute())

        {:ok, %{"jti" => jti}} = AshAuthentication.Jwt.peek(token)
        query("DELETE FROM tokens WHERE jti=$1", [jti])
        remove_jobs(mail.id)
        query("DELETE FROM account_auth_emails WHERE id=$1", [Ecto.UUID.dump!(mail.id)])
      end

      Marshall.CommittedFixtureCleanup.subscription_reviews!([user.id])

      for deletion <- Ledger.read!(Marshall.Accounts.UserDeletion, user_id: user.id),
          do: remove_jobs(deletion.id)

      query("DELETE FROM account_user_deletions WHERE user_id=$1", [id])
    end

    JobHistoryFixture.cleanup([], users)
  end

  @spec remove_jobs(String.t()) :: :ok
  defp remove_jobs(id) do
    %{rows: rows} =
      query("DELETE FROM oban_jobs WHERE args->'primary_key'->>'id'=$1 RETURNING id", [id])

    for [job_id] <- rows do
      query("DELETE FROM admin_job_events WHERE job_id=$1", [job_id])
      query("DELETE FROM admin_job_snapshots WHERE id=$1", [job_id])
    end

    :ok
  end

  @spec query(String.t(), [term()]) :: Postgrex.Result.t()
  defdelegate query(sql, params \\ []), to: JobHistoryFixture
  @spec name(pos_integer()) :: String.t()
  defp name(id) when id > 0, do: "admin_account_gate_#{id}"
end
