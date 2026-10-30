defmodule Marshall.Accounts.AccountLifecycle do
  @moduledoc "Audited invitations, MFA resets and permanent account retirement."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Accounts.{AdminBootstrap, GuestAccount, Passkey, Security, User, UserDeletion}
  alias Marshall.Compute.{Ledger, VirtualMachine}
  alias Marshall.Authorization.SystemActor
  require Ash.Query
  require Marshall.Events

  # @cc [owner:ghuntley,label:concurrency;security] account-admission-fence
  # Creating owned work MUST hold this shared account fence through commit and
  # recheck active identity. Retirement takes its exclusive counterpart before
  # disabling the account, preventing work from appearing after cleanup completes.
  @spec admit!(String.t()) :: :ok
  def admit!(id) do
    admit_all!([id])
    :ok
  end

  @doc "Takes the exclusive account fence that retirement holds against owned-work admission."
  @spec retirement_fence!(String.t()) :: :ok
  def retirement_fence!(id) do
    fence!(id, :exclusive)
    :ok
  end

  # @cc [owner:ghuntley,label:concurrency;security] ordered-account-admission-fences
  # Multi-account team mutations MUST acquire shared account fences in sorted
  # account-ID order and recheck every identity before locking team rows.
  @spec admit_all!([String.t()]) :: :ok
  def admit_all!(ids) do
    ids
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.each(fn id ->
      fence!(id, :shared)

      unless match?(%User{deleted_at: nil, active: true}, Security.current(id)),
        do: Ledger.rollback(:forbidden)
    end)

    :ok
  end

  @impl true
  def run(input, _, %{actor: %User{} = actor}) do
    result =
      Ledger.transaction(fn ->
        Ledger.lock!(AdminBootstrap, "installation") || Ledger.rollback(:forbidden)
        Security.require_admin!(actor)
        perform(input.action.name, input.arguments, actor)
      end)

    case result do
      {:ok, {outcome, event}} ->
        unless Marshall.Repo.in_transaction?(), do: emit_event(event)
        {:ok, outcome}

      {:error, reason} when is_atom(reason) ->
        {:error, Marshall.Compute.Error.exception(reason: reason)}

      other ->
        other
    end
  end

  def run(_, _, _), do: {:error, Ash.Error.Forbidden.exception([])}

  # @cc [owner:ghuntley,label:security;concurrency] invitation-current-authority
  # Invitation MUST retain actor User authority through its outbox and audit
  # commit. Recipient lookup does not grant recipient account mutation authority.
  defp perform(:invite_user, %{email: email}, actor) do
    Security.lock_user!(actor.id)
    Security.require_admin!(actor)

    User
    |> Ash.ActionInput.for_action(:request_magic_link, %{email: email},
      actor: Marshall.Authorization.SystemActor.service(:ash_authentication)
    )
    |> Ash.run_action!()

    Security.require_admin!(actor)
    Security.audit!(actor.id, actor.id, :user_invite)
    {%{invited: true}, {:account_invited, actor.id, actor.id}}
  end

  # @cc [owner:ghuntley,label:security;concurrency] reset-current-authority
  # MFA reset MUST lock the complete actor/target User set in sorted order and
  # recheck actor authority before changing credentials, sessions or audit state.
  defp perform(:reset_mfa, %{user_id: id}, actor) do
    if id == actor.id, do: Ledger.rollback(:self_reset)
    user = Map.fetch!(Security.lock_admin_participants!(actor.id, id), id)
    unless user && is_nil(user.deleted_at), do: Ledger.rollback(:unauthorized)
    Security.require_admin!(actor)

    Ledger.update!(user, :security_state, %{
      mfa_enabled: true,
      mfa_reset_required: true,
      mfa_generation: user.mfa_generation + 1
    })

    Enum.each(Ledger.read!(Passkey, user_id: id), &Ledger.archive!(&1, :destroy))
    revoke_tokens!(id)
    Security.audit!(actor.id, id, :mfa_reset)
    {%{reset: true}, {:account_mfa_reset, id, actor.id}}
  end

  # @cc [owner:ghuntley,label:security;concurrency] retirement-current-authority
  # Retirement MUST take its exclusive target admission fence before sorted
  # actor/target User locks. Fresh authority MUST hold through audit commit,
  # including retries returning a previously recorded deletion receipt.
  # Its current GuestAccount MUST retire in the same transaction after User
  # locking, while UUID and UID tombstones remain permanently reserved.
  defp perform(:delete_user, %{user_id: id, confirmation: confirmation}, actor) do
    if id == actor.id, do: Ledger.rollback(:self_deletion)
    fence!(id, :exclusive)
    users = Security.lock_admin_participants!(actor.id, id)
    Security.require_admin!(actor)

    case Ledger.read!(UserDeletion, user_id: id) do
      [%UserDeletion{} = deletion]
      when deletion.kind == :administrator or deletion.state in [:finalizing, :completed] ->
        {%{id: deletion.id, deleting: true}, nil}

      # No deletion, or a SCIM retirement still scheduled or cancelled, which
      # an administrator retirement supersedes immediately.
      existing ->
        user = Map.fetch!(users, id)
        unless user && is_nil(user.deleted_at), do: Ledger.rollback(:unauthorized)

        unless String.downcase(confirmation) == String.downcase(to_string(user.email)),
          do: Ledger.rollback(:confirmation_mismatch)

        retire_attachments!(id, actor.id)

        if user.administrator do
          remaining =
            User
            |> Ash.Query.for_read(:internal_lookup, %{}, actor: SystemActor.compute())
            |> Ash.Query.filter(administrator == true and is_nil(deleted_at) and id != ^id)
            |> Ash.count!()

          if remaining == 0, do: Ledger.rollback(:last_administrator)
        end

        email = user.email
        # Retain the UUID for foreign keys while releasing the public email identity.
        Ledger.update!(user, :security_state, %{
          deleted_at: Ledger.now(),
          administrator: false,
          email: "deleted-#{user.id}@deleted.invalid",
          mfa_generation: user.mfa_generation + 1
        })

        revoke_tokens!(id)

        deletion =
          case existing do
            [] ->
              Ledger.create!(UserDeletion, :record, %{
                user_id: id,
                requested_by_id: actor.id,
                email: email
              })

            [scim] ->
              Ledger.update!(scim, :escalate, %{requested_by_id: actor.id, email: email})
          end

        Security.audit!(actor.id, id, :user_delete)
        {%{id: deletion.id, deleting: true}, {:account_deleted, id, actor.id}}
    end
  end

  # @cc [owner:ghuntley,label:security;recovery] account-retirement-attachments
  # Administrator retirement and SCIM finalization MUST retire the same
  # attached state in the identity-retiring transaction: the guest account,
  # team memberships and transfers, user-owned integrations, GitHub and
  # notification subscriptions, and MUST enqueue revocation of thread subscriptions.
  @doc "Retires every identity attachment; the caller holds the retirement fence and user lock."
  @spec retire_attachments!(String.t(), String.t()) :: :ok
  def retire_attachments!(id, actor_id) do
    retire_guest_account!(id)
    Marshall.Teams.Coordinator.retire_user!(id, actor_id)
    retire_integrations!(id)
    Marshall.GitHub.retire_locked!(id)
    _ = Marshall.Notifications.revoke_for_user!(id, :account_retired)
    Marshall.Threads.SubscriptionRevokeJob.enqueue_owner!(id)
  end

  @spec owned_count(String.t()) :: non_neg_integer()
  def owned_count(id),
    do:
      VirtualMachine
      |> Ash.Query.filter(owner_id == ^id)
      |> Ash.count!(actor: SystemActor.compute())

  @spec retire_guest_account!(String.t()) :: :ok
  defp retire_guest_account!(id) do
    account =
      GuestAccount
      |> Ash.Query.filter(user_id == ^id and is_nil(retired_at))
      |> Ash.Query.lock(:for_update)
      |> Ash.read_one!(actor: SystemActor.compute())

    if account, do: Ledger.update!(account, :retire, %{retired_at: Ledger.now()})
    :ok
  end

  @spec revoke_tokens!(String.t()) :: :ok
  def revoke_tokens!(id) do
    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      "UPDATE tokens SET purpose = 'revocation', updated_at = (clock_timestamp() AT TIME ZONE 'utc') WHERE subject = $1 AND purpose != 'revocation'",
      ["user?id=#{id}"],
      log: false
    )

    Marshall.Control.Hints.notify_user(id)
  end

  defp emit_event({:account_invited, user_id, actor_id}),
    do: Marshall.Events.emit("account.invited", user_id: user_id, actor_id: actor_id)

  defp emit_event({:account_mfa_reset, user_id, actor_id}),
    do: Marshall.Events.emit("account.mfa_reset", user_id: user_id, actor_id: actor_id)

  defp emit_event({:account_deleted, user_id, actor_id}),
    do: Marshall.Events.emit("account.deleted", user_id: user_id, actor_id: actor_id)

  defp emit_event(nil), do: :ok

  # @cc [owner:ghuntley,label:security;recovery] account-retirement-integrations
  # Retirement MUST archive every active user-owned integration in the same
  # transaction that disables the account. Team-owned integrations survive;
  # retirement separately refuses active team owners.
  defp retire_integrations!(user_id) do
    Marshall.Galileo.Integration
    |> Ash.Query.filter(owner_id == ^user_id)
    |> Ash.Query.sort(:id)
    |> Ash.read!(actor: SystemActor.compute())
    |> Enum.each(fn integration ->
      integration = Ledger.lock!(Marshall.Galileo.Integration, integration.id)

      if integration && integration.owner_id == user_id,
        do: Ledger.archive!(integration, :archive)
    end)
  end

  defp fence!(id, kind) do
    function =
      if kind == :shared, do: "pg_advisory_xact_lock_shared", else: "pg_advisory_xact_lock"

    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      "SELECT #{function}(hashtextextended($1, 0))",
      ["account:" <> id],
      log: false
    )
  end
end
