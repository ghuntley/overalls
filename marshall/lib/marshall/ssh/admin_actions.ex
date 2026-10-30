defmodule Marshall.SSH.AdminActions do
  @moduledoc "Bounded administrator inventory and revocation for SSH authority."
  use Ash.Resource.Actions.Implementation

  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  alias Marshall.Accounts.{AdminEvent, User}
  alias Marshall.SSH.{Gateway, Key, Session}
  require Ash.Query
  require Marshall.Events

  # @cc [owner:ghuntley,label:security] admin-ssh-inventory-redaction
  # Administrator inventory MUST be bounded and MUST never expose public-key
  # material, token hashes, session tokens or gateway credentials.
  @impl true
  def run(input, options, %{actor: %User{} = actor}) do
    result =
      Ledger.transaction(
        fn ->
          action =
            if options[:operation] in [:list_keys, :list_sessions],
              do: "admin_read",
              else: "admin_accounts"

          unless Marshall.Authorization.control_plane?(actor, action),
            do: Ledger.rollback(:forbidden)

          perform(options[:operation], input.arguments, actor)
        end,
        actor
      )

    with {:ok, {value, event}} <- result do
      unless Marshall.Repo.in_transaction?(), do: emit_event(event)
      {:ok, value}
    end
  end

  def run(_, _, _), do: {:error, Ash.Error.Forbidden.exception([])}

  defp perform(:list_keys, args, _actor) do
    keys =
      Key
      |> Ash.Query.filter(is_nil(archived_at))
      |> after_id(args[:after])
      |> Ash.Query.sort(id: :asc)
      |> Ash.Query.limit(args[:limit] || 100)
      |> Ash.read!(actor: SystemActor.compute())

    user_ids = Enum.map(keys, & &1.user_id)

    users =
      User
      |> Ash.Query.for_read(:internal_lookup)
      |> Ash.Query.filter(id in ^user_ids)
      |> Ash.read!(actor: SystemActor.compute())
      |> Map.new(&{&1.id, &1})

    entries =
      Enum.map(keys, fn key ->
        %{
          id: key.id,
          user_id: key.user_id,
          email: users[key.user_id].email,
          time_zone: users[key.user_id].time_zone,
          label: key.label,
          algorithm: key.algorithm,
          fingerprint: key.fingerprint,
          inserted_at: key.inserted_at
        }
      end)

    {entries, nil}
  end

  defp perform(:revoke_key, %{id: id}, actor) do
    case Ledger.lock!(Key, id) do
      nil ->
        Ledger.rollback(:key_not_found)

      key ->
        Marshall.Accounts.Security.require_admin!(actor)
        :ok = Ledger.archive!(key, :revoke)
        _ = Marshall.Notifications.revoke_for_key!(key.id, :key_revoked)

        Ledger.create!(AdminEvent, :record, %{
          actor_id: actor.id,
          target_id: key.id,
          kind: :ssh_key_revoke
        })

        {%{id: key.id, user_id: key.user_id, revoked: true, revoked_by_id: actor.id},
         {:admin_key_revoked, key.id, actor.id}}
    end
  end

  defp perform(:list_sessions, args, _actor) do
    now = Ledger.now()

    sessions =
      Session
      |> Ash.Query.filter(is_nil(closed_at) and expires_at > ^now)
      |> after_id(args[:after])
      |> Ash.Query.sort(id: :asc)
      |> Ash.Query.limit(args[:limit] || 100)
      |> Ash.read!(actor: SystemActor.compute())

    gateway_ids = Enum.map(sessions, & &1.gateway_id)

    gateways =
      Gateway
      |> Ash.Query.filter(id in ^gateway_ids)
      |> Ash.read!(actor: SystemActor.compute())
      |> Map.new(&{&1.id, &1})

    key_ids = Enum.reject(Enum.map(sessions, & &1.key_id), &is_nil/1)

    keys =
      Key
      |> Ash.Query.filter(id in ^key_ids)
      |> Ash.read!(actor: SystemActor.compute())
      |> Map.new(&{&1.id, &1})

    entries =
      Enum.map(sessions, fn session ->
        %{
          id: session.id,
          gateway_id: session.gateway_id,
          gateway_name: gateways[session.gateway_id].name,
          key_id: session.key_id,
          fingerprint: session.key_id && keys[session.key_id].fingerprint,
          inserted_at: session.inserted_at,
          expires_at: session.expires_at
        }
      end)

    {entries, nil}
  end

  defp perform(:revoke_session, %{id: id}, actor) do
    case Ledger.lock!(Session, id) do
      nil ->
        Ledger.rollback(:session_not_found)

      %{closed_at: nil} = session ->
        Marshall.Accounts.Security.require_admin!(actor)
        Ledger.update!(session, :close, %{closed_at: Ledger.now()})

        Ledger.create!(AdminEvent, :record, %{
          actor_id: actor.id,
          target_id: session.id,
          kind: :ssh_session_revoke
        })

        {%{id: session.id, revoked: true}, {:admin_session_revoked, session.id, actor.id}}

      session ->
        {%{id: session.id, revoked: true}, nil}
    end
  end

  defp after_id(query, nil), do: query
  defp after_id(query, id), do: Ash.Query.filter(query, id > ^id)

  defp emit_event({:admin_key_revoked, key_id, actor_id}),
    do: Marshall.Events.emit("ssh.admin_key_revoked", key_id: key_id, actor_id: actor_id)

  defp emit_event({:admin_session_revoked, session_id, actor_id}),
    do:
      Marshall.Events.emit("ssh.admin_session_revoked",
        session_id: session_id,
        actor_id: actor_id
      )

  defp emit_event(nil), do: :ok
end
