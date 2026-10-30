defmodule Marshall.Teams.Coordinator do
  @moduledoc "Transactional team creation, membership management and ownership transfer."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  alias Marshall.Teams.{Fence, ServiceOwner, Team, TeamMember, Transfer}
  require Marshall.Events
  require Ash.Query

  @typep creation_arguments :: %{name: String.t(), idempotency_key: String.t()}
  @typep creation_event ::
           {:membership, Ash.UUID.t(), Ash.UUID.t(), Ash.UUID.t(), :created}

  @typep membership_role :: :admin | :member | :removed
  @typep membership_arguments :: %{
           team_id: Ash.UUID.t(),
           email: Ash.CiString.t(),
           role: membership_role(),
           idempotency_key: String.t()
         }
  @typep membership_result :: %{
           team_id: Ash.UUID.t(),
           user_id: Ash.UUID.t(),
           role: membership_role()
         }
  @typep membership_event ::
           {:membership, Ash.UUID.t(), Ash.UUID.t(), Ash.UUID.t(), membership_role()}

  @impl true
  def run(input, options, context) do
    result =
      Ledger.transaction(
        fn ->
          {value, event} =
            case options[:operation] do
              :list -> {list(context.actor, input.arguments), nil}
              :list_all -> {list_all(input.arguments), nil}
              :set_member -> set_member(input.arguments, context.actor)
              :list_members -> {list_members(input.arguments, context.actor), nil}
              :list_transfers -> {list_transfers(input.arguments, context.actor), nil}
              _ -> create(input.arguments, context.actor)
            end

          schedule_event(event)
          value
        end,
        context.actor
      )

    case result do
      {:ok, value} ->
        {:ok, value}

      {:error, reason} when is_atom(reason) ->
        {:error, Marshall.Compute.Error.exception(reason: reason)}

      other ->
        other
    end
  end

  # @cc [owner:ghuntley,label:product] team-creation-owner-membership
  # Creating a team MUST create exactly one owner membership for the creator
  # in the same transaction and MUST NOT grant any other account membership.

  # @cc [owner:ghuntley,label:security;concurrency] team-creation-name-retry
  # Creation MUST serialize by active name across actors. An existing team may
  # be returned only to its original creator who remains its current owner;
  # every other active-name collision MUST refuse without writes or events.
  # Archived rows MUST NOT satisfy creation or prevent a fresh team identity.
  @spec create(creation_arguments(), Marshall.Accounts.User.t()) ::
          {Team.t(), creation_event() | nil}
  defp create(arguments, actor) do
    Fence.require_creation_open!()
    Marshall.Accounts.AccountLifecycle.admit!(actor.id)

    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
      ["team-name:" <> arguments.name],
      log: false
    )

    case Ledger.read!(Team, name: arguments.name) do
      [existing] ->
        team = lock_team!(existing.id)

        unless team.created_by_id == actor.id and roles(team.id).owner == actor.id,
          do: Ledger.rollback(:team_name_taken)

        {team, nil}

      [] ->
        team = new_team(arguments, actor)
        receipt!(actor.id, team.id, :team_create)
        receipt!(actor.id, team.id, :team_membership_change)
        {team, {:membership, team.id, actor.id, actor.id, :created}}
    end
  end

  defp new_team(arguments, actor) do
    team = Ledger.create!(Team, :register, %{name: arguments.name, created_by_id: actor.id})

    Ledger.create!(TeamMember, :record, %{
      team_id: team.id,
      user_id: actor.id,
      role: :owner,
      recorded_by_id: actor.id
    })

    team
  end

  # @cc [owner:ghuntley,label:security] team-membership-authorized-replacement
  # Only the team owner or an admin may change memberships, and only the
  # owner may remove an admin or appoint admins. The owner role itself is
  # only ever changed through the Transfer consent workflow. Memberships
  # MUST resolve existing accounts by exact case-insensitive email and never
  # create accounts or invitations.
  @spec set_member(membership_arguments(), Marshall.Accounts.User.t()) ::
          {membership_result(), membership_event() | nil}
  defp set_member(arguments, actor) do
    Fence.require_creation_open!()

    user =
      Marshall.Accounts.User
      |> Ash.Query.for_read(:internal_lookup)
      |> Ash.Query.filter(email == ^arguments.email)
      |> Ash.read_one!(actor: SystemActor.compute())

    if user == nil, do: Ledger.rollback(:recipient_not_registered)
    Marshall.Accounts.AccountLifecycle.admit_all!([actor.id, user.id])
    team = lock_team!(arguments.team_id)
    Fence.require_native!(team)
    member = current_member!(team.id, actor.id)

    unless Marshall.Authorization.allowed?(
             actor,
             "team_manage_members",
             Marshall.Teams.Team.Cedar,
             team.id
           ),
           do: Ledger.rollback(:forbidden)

    if user.id == actor.id, do: Ledger.rollback(:owner_protected)
    if member.role != :owner and arguments.role == :admin, do: Ledger.rollback(:forbidden)

    existing = Ledger.read!(TeamMember, team_id: team.id, user_id: user.id)

    if Enum.any?(existing, &(&1.role == :owner)), do: Ledger.rollback(:owner_protected)

    if member.role != :owner and Enum.any?(existing, &(&1.role == :admin)),
      do: Ledger.rollback(:forbidden)

    if arguments.role == :removed do
      Enum.each(existing, &Ledger.archive!(&1, :remove))
    else
      case existing do
        [membership] ->
          Ledger.update!(membership, :replace_role, %{
            role: arguments.role,
            recorded_by_id: actor.id
          })

        [] ->
          Ledger.create!(TeamMember, :record, %{
            team_id: team.id,
            user_id: user.id,
            role: arguments.role,
            recorded_by_id: actor.id
          })
      end
    end

    result = %{team_id: team.id, user_id: user.id, role: arguments.role}
    event = {:membership, team.id, user.id, actor.id, arguments.role}
    changed = not (arguments.role == :removed and existing == [])
    if changed, do: receipt!(actor.id, team.id, :team_membership_change)
    if changed, do: Marshall.Threads.SubscriptionRevokeJob.enqueue_owner!(user.id)
    {result, if(changed, do: event)}
  end

  defp list(actor, arguments) do
    require Ash.Query

    memberships =
      TeamMember
      |> Ash.Query.filter(user_id == ^actor.id)
      |> Ash.Query.sort(inserted_at: :desc, id: :desc)
      |> Ash.read!(actor: SystemActor.compute())

    teams =
      Team
      |> Ash.Query.filter(id in ^Enum.map(memberships, & &1.team_id))
      |> Ash.Query.sort(inserted_at: :desc, id: :desc)
      |> Ash.read!(actor: SystemActor.compute())
      |> Enum.map(fn team ->
        membership = Enum.find(memberships, &(&1.team_id == team.id))

        %{
          id: team.id,
          name: team.name,
          role: membership.role,
          management_mode: team.management_mode,
          inserted_at: team.inserted_at
        }
      end)
      |> paginate(arguments)

    teams
  end

  # Active teams for every signed-in account: names, mode and visible member
  # counts only. The hidden service owner is never counted.
  defp list_all(arguments) do
    hidden = ServiceOwner.id()

    teams =
      Team
      |> Ash.Query.sort(name: :asc, id: :asc)
      |> Ash.read!(actor: SystemActor.compute())

    counts =
      TeamMember
      |> Ash.Query.filter(team_id in ^Enum.map(teams, & &1.id))
      |> Ash.read!(actor: SystemActor.compute())
      |> Enum.reject(&(&1.user_id == hidden))
      |> Enum.frequencies_by(& &1.team_id)

    teams
    |> Enum.map(fn team ->
      %{
        id: team.id,
        name: team.name,
        management_mode: team.management_mode,
        member_count: Map.get(counts, team.id, 0)
      }
    end)
    |> paginate(arguments)
  end

  defp list_members(arguments, actor) do
    team = live_team!(arguments.team_id)

    unless Marshall.Authorization.allowed?(
             actor,
             "team_read",
             Marshall.Teams.Team.Cedar,
             team.id
           ),
           do: Ledger.rollback(:forbidden)

    hidden = ServiceOwner.id()
    memberships = Enum.reject(Ledger.read!(TeamMember, team_id: team.id), &(&1.user_id == hidden))

    users =
      Marshall.Accounts.User
      |> Ash.Query.for_read(:internal_lookup, %{}, actor: SystemActor.compute())
      |> Ash.Query.filter(id in ^Enum.map(memberships, & &1.user_id))
      |> Ash.read!(actor: SystemActor.compute())
      |> Map.new(&{&1.id, &1})

    Enum.map(memberships, fn membership ->
      user = users[membership.user_id]

      %{
        user_id: membership.user_id,
        role: membership.role,
        email: user && user.email,
        time_zone: user && user.time_zone
      }
    end)
  end

  # @cc [owner:ghuntley,label:security] team-transfer-bounded-current-view
  # The product transfer view MUST expose at most the team's one pending offer,
  # only after a fresh Cedar team-read decision. It MUST contain no authority;
  # every transition rechecks persisted actors, memberships and ownership.
  defp list_transfers(arguments, actor) do
    team = live_team!(arguments.team_id)

    unless Marshall.Authorization.allowed?(
             actor,
             "team_read",
             Marshall.Teams.Team.Cedar,
             team.id
           ),
           do: Ledger.rollback(:forbidden)

    transfers = Ledger.read!(Transfer, team_id: team.id, state: :pending)

    users =
      Marshall.Accounts.User
      |> Ash.Query.for_read(:internal_lookup, %{}, actor: SystemActor.compute())
      |> Ash.Query.filter(id in ^Enum.flat_map(transfers, &[&1.from_user_id, &1.to_user_id]))
      |> Ash.read!(actor: SystemActor.compute())
      |> Map.new(&{&1.id, &1})

    Enum.map(transfers, fn transfer ->
      from = users[transfer.from_user_id]
      to = users[transfer.to_user_id]

      %{
        id: transfer.id,
        state: transfer.state,
        from_user_id: transfer.from_user_id,
        from_email: from && from.email,
        from_time_zone: from && from.time_zone,
        to_user_id: transfer.to_user_id,
        to_email: to && to.email,
        to_time_zone: to && to.time_zone
      }
    end)
  end

  # @cc [owner:ghuntley,label:security] team-transfer-offer-consent
  # Only the owner may offer, only to an existing non-owner member, with at
  # most one pending offer per team. Only the target may accept or decline
  # and only the owner may cancel; every guard MUST hold under the team lock.
  def offer(team_id, email, actor) do
    with {:ok, team, target} <- offer_inputs(team_id, email) do
      Ledger.transaction(
        fn ->
          Marshall.Accounts.AccountLifecycle.admit_all!([actor.id, target.id])
          locked = lock_team!(team.id)
          Fence.require_native!(locked)
          owner = current_member!(locked.id, actor.id)
          target_member = current_member!(locked.id, target.id)

          if owner.role != :owner or target.id == actor.id or target_member.role == :owner,
            do: Ledger.rollback(:forbidden)

          if Ledger.read!(Transfer, team_id: locked.id, state: :pending) != [],
            do: Ledger.rollback(:transfer_pending)

          transfer =
            Ledger.create!(Transfer, :offer, %{
              team_id: locked.id,
              from_user_id: actor.id,
              to_user_id: target.id
            })

          receipt!(actor.id, transfer.id, :team_transfer_offer)
          schedule_transfer(transfer, actor.id)
          transfer
        end,
        actor
      )
    end
  end

  def accept(transfer_id, actor) do
    transition(transfer_id, :accept, actor, fn transfer ->
      owner = current_member!(transfer.team_id, transfer.from_user_id)
      target = current_member!(transfer.team_id, transfer.to_user_id)

      if owner.role != :owner or target.role == :owner, do: Ledger.rollback(:forbidden)
      if transfer.to_user_id != actor.id, do: Ledger.rollback(:forbidden)
      transfer
    end)
  end

  def decline(transfer_id, actor) do
    transition(transfer_id, :decline, actor, fn transfer ->
      owner = current_member!(transfer.team_id, transfer.from_user_id)
      _target = current_member!(transfer.team_id, transfer.to_user_id)

      if owner.role != :owner, do: Ledger.rollback(:forbidden)
      if transfer.to_user_id != actor.id, do: Ledger.rollback(:forbidden)
      transfer
    end)
  end

  def cancel(transfer_id, actor) do
    transition(transfer_id, :cancel, actor, fn transfer ->
      owner = current_member!(transfer.team_id, transfer.from_user_id)

      if owner.role != :owner, do: Ledger.rollback(:forbidden)
      if transfer.from_user_id != actor.id, do: Ledger.rollback(:forbidden)
      transfer
    end)
  end

  # @cc [owner:ghuntley,label:security;recovery] team-transfer-closed-state-refusal
  # Only the state machine's explicit no-matching-transition exception may become
  # invalid_transition. Unexpected storage or application exceptions MUST escape
  # to the transport's opaque unavailable handling, never a permanent conflict.
  defp transition(transfer_id, action, actor, guard) do
    if OverallsProtocol.uuid?(transfer_id) do
      case Ledger.read!(Transfer, id: transfer_id) do
        [candidate] ->
          Ledger.transaction(
            fn ->
              Marshall.Accounts.AccountLifecycle.admit_all!([
                candidate.from_user_id,
                candidate.to_user_id
              ])

              team = lock_team!(candidate.team_id)
              Fence.require_native!(team)
              transfer = Ledger.lock!(Transfer, transfer_id) || Ledger.rollback(:unknown_transfer)
              transfer = guard.(transfer)

              transfer = Ledger.update!(transfer, action, %{})
              receipt!(actor.id, transfer.id, transfer_receipt(action))

              if action == :accept do
                schedule_event(
                  {:membership, transfer.team_id, transfer.from_user_id, actor.id, :admin}
                )

                schedule_event(
                  {:membership, transfer.team_id, transfer.to_user_id, actor.id, :owner}
                )
              end

              schedule_transfer(transfer, actor.id)
              transfer
            end,
            actor
          )

        _ ->
          {:error, :unknown_transfer}
      end
    else
      {:error, :invalid_request}
    end
  catch
    :error, %Ash.Error.Invalid{errors: [%AshStateMachine.Errors.NoMatchingTransition{}]} ->
      {:error, :invalid_transition}
  end

  # @cc [owner:ghuntley,label:security;concurrency] team-account-retirement
  # Retirement MUST fail with :team_owner while the account owns an active
  # team. Otherwise it MUST atomically archive every current non-owner
  # membership and cancel every pending transfer involving the account while
  # holding affected team locks in sorted order. Each authority change MUST
  # retain the initiating actor in its receipt and diagnostic.
  @doc "Resolve team membership and transfer state during trusted account retirement."
  @spec retire_user!(String.t(), String.t()) :: :ok
  def retire_user!(user_id, actor_id) do
    memberships = Ledger.read!(TeamMember, user_id: user_id)

    transfers =
      Transfer
      |> Ash.Query.filter(
        state == :pending and (from_user_id == ^user_id or to_user_id == ^user_id)
      )
      |> Ash.read!(actor: SystemActor.compute())

    team_ids =
      (Enum.map(memberships, & &1.team_id) ++ Enum.map(transfers, & &1.team_id))
      |> Enum.uniq()
      |> Enum.sort()

    active_team_ids =
      Team
      |> Ash.Query.filter(id in ^team_ids)
      |> Ash.read!(actor: SystemActor.compute())
      |> MapSet.new(& &1.id)

    Enum.each(team_ids, fn team_id ->
      Ledger.lock_history!(Team, team_id) || Ledger.rollback(:unknown_team)
    end)

    memberships = Ledger.read!(TeamMember, user_id: user_id)

    if Enum.any?(
         memberships,
         &(&1.role == :owner and MapSet.member?(active_team_ids, &1.team_id))
       ),
       do: Ledger.rollback(:team_owner)

    Enum.each(memberships, fn membership ->
      Ledger.archive!(membership, :remove)
      receipt!(actor_id, membership.team_id, :team_membership_change)
      Marshall.Threads.SubscriptionRevokeJob.enqueue_owner!(membership.user_id)
      schedule_event({:membership, membership.team_id, membership.user_id, actor_id, :removed})
    end)

    Transfer
    |> Ash.Query.filter(
      state == :pending and (from_user_id == ^user_id or to_user_id == ^user_id)
    )
    |> Ash.read!(actor: SystemActor.compute())
    |> Enum.each(fn transfer ->
      transfer = Ledger.update!(transfer, :cancel, %{})
      receipt!(actor_id, transfer.id, :team_transfer_cancel)
      schedule_transfer(transfer, actor_id)
    end)

    :ok
  end

  defp offer_inputs(team_id, email) do
    with true <- OverallsProtocol.uuid?(team_id),
         [team] <- Ledger.read!(Team, id: team_id),
         {:ok, email} <- Ash.Type.CiString.cast_input(email, []),
         [%Marshall.Accounts.User{} = target] <-
           Marshall.Accounts.User
           |> Ash.Query.for_read(:internal_lookup)
           |> Ash.Query.filter(email == ^email)
           |> Ash.read!(actor: SystemActor.compute()) do
      {:ok, team, target}
    else
      _ -> {:error, :invalid_request}
    end
  end

  @doc "Current membership lookup for trusted coordinators."
  @spec member?(binary(), binary()) :: boolean()
  def member?(team_id, user_id) do
    Ledger.read!(TeamMember, team_id: team_id, user_id: user_id) != []
  end

  @doc "Current roles for Cedar entity construction; never authority by itself."
  @spec roles(binary()) :: %{owner: binary() | nil, admins: [binary()], members: [binary()]}
  def roles(team_id) do
    members = Ledger.read!(TeamMember, team_id: team_id)

    %{
      owner: Enum.find_value(members, &(&1.role == :owner && &1.user_id)),
      admins: for(m <- members, m.role in [:owner, :admin], do: m.user_id),
      members: for(m <- members, do: m.user_id)
    }
  end

  @doc "Resolve a team by its unique name; trusted coordinator lookup."
  @spec resolve!(binary()) :: Team.t()
  def resolve!(name) do
    case Ledger.read!(Team, name: name) do
      [team] -> team
      _ -> Ledger.rollback(:unknown_team)
    end
  end

  defp live_team!(id) do
    case Ledger.read!(Team, id: id) do
      [team] -> team
      _ -> Ledger.rollback(:unknown_team)
    end
  end

  defp lock_team!(id) do
    Ledger.lock!(Team, id) || Ledger.rollback(:unknown_team)
  end

  defp current_member!(team_id, user_id) do
    case Ledger.read!(TeamMember, team_id: team_id, user_id: user_id) do
      [member] -> member
      _ -> Ledger.rollback(:not_a_member)
    end
  end

  defp schedule_event(nil), do: :ok

  defp schedule_event({:membership, team_id, user_id, nil, status}) do
    Ledger.after_commit(fn ->
      Marshall.Events.emit("team.membership_changed",
        team_id: team_id,
        user_id: user_id,
        operation_status: status
      )
    end)
  end

  defp schedule_event({:membership, team_id, user_id, actor_id, status}) do
    Ledger.after_commit(fn ->
      Marshall.Events.emit("team.membership_changed",
        team_id: team_id,
        user_id: user_id,
        actor_id: actor_id,
        operation_status: status
      )
    end)
  end

  defp schedule_transfer(%Transfer{} = transfer, actor_id) do
    Ledger.after_commit(fn ->
      Marshall.Events.emit("team.transfer_changed",
        transfer_id: transfer.id,
        team_id: transfer.team_id,
        actor_id: actor_id,
        state: transfer.state
      )
    end)
  end

  # @cc [owner:ghuntley,label:security;durability] team-authority-admin-receipts
  # Authority-changing team writes MUST append a payload-free AdminEvent in the
  # same transaction. A rollback MUST remove both the mutation and its receipt.
  defp receipt!(actor_id, target_id, kind) do
    Ledger.create!(Marshall.Accounts.AdminEvent, :record, %{
      actor_id: actor_id,
      target_id: target_id,
      kind: kind
    })
  end

  defp transfer_receipt(:accept), do: :team_transfer_accept
  defp transfer_receipt(:decline), do: :team_transfer_decline
  defp transfer_receipt(:cancel), do: :team_transfer_cancel

  # @cc [owner:ghuntley,label:product] teams-exclusive-list-cursor
  # A non-nil team cursor MUST exclude the matching row and an unknown cursor
  # MUST return an empty page. A terminal row MUST NOT repeat indefinitely.
  defp paginate(rows, arguments) do
    remaining =
      if is_nil(arguments[:after]) do
        rows
      else
        case Enum.drop_while(rows, &(&1.id != arguments[:after])) do
          [_cursor | rest] -> rest
          [] -> []
        end
      end

    Enum.take(remaining, arguments.limit)
  end
end
