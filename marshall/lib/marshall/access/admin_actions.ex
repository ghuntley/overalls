defmodule Marshall.Access.AdminActions do
  @moduledoc "Bounded administrator inventory and revocation for VM memberships."
  use Ash.Resource.Actions.Implementation

  alias Marshall.Access.Grant
  alias Marshall.Accounts.{AdminEvent, User}
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.{Ledger, VirtualMachine}
  require Ash.Query

  @impl true
  def run(input, options, %{actor: %User{} = actor}) do
    Ledger.transaction(
      fn ->
        action = if options[:operation] == :revoke, do: "admin_accounts", else: "admin_read"

        unless Marshall.Authorization.control_plane?(actor, action),
          do: Ledger.rollback(:forbidden)

        case options[:operation] do
          :revoke -> revoke(input.arguments.id, actor)
          _ -> list(input.arguments)
        end
      end,
      actor
    )
  end

  def run(_, _, _), do: {:error, Ash.Error.Forbidden.exception([])}

  # @cc [owner:ghuntley,label:security] admin-grant-inventory-redaction
  # The admin membership inventory MUST expose only VM/user identity and role;
  # it MUST not include terminal bytes, credentials or historical grant fields.
  defp list(args) do
    grants =
      Grant
      |> Ash.Query.filter(is_nil(archived_at))
      |> after_id(args[:after])
      |> Ash.Query.sort(id: :asc)
      |> Ash.Query.limit(args[:limit] || 100)
      |> Ash.read!(actor: SystemActor.compute())

    user_ids = Enum.map(grants, & &1.user_id)
    vm_ids = Enum.map(grants, & &1.vm_id)

    users =
      User
      |> Ash.Query.for_read(:internal_lookup)
      |> Ash.Query.filter(id in ^user_ids)
      |> Ash.read!(actor: SystemActor.compute())
      |> Map.new(&{&1.id, &1})

    vms =
      VirtualMachine
      |> Ash.Query.filter(id in ^vm_ids)
      |> Ash.read!(actor: SystemActor.compute())
      |> Map.new(&{&1.id, &1})

    Enum.map(grants, fn grant ->
      %{
        id: grant.id,
        vm_id: grant.vm_id,
        vm_name: vms[grant.vm_id].name,
        user_id: grant.user_id,
        email: users[grant.user_id].email,
        time_zone: users[grant.user_id].time_zone,
        role: grant.role,
        inserted_at: grant.inserted_at
      }
    end)
  end

  defp revoke(id, actor) do
    case Ledger.lock!(Grant, id) do
      nil ->
        Ledger.rollback(:grant_not_found)

      grant ->
        Marshall.Accounts.Security.require_admin!(actor)
        grant = Ledger.update!(grant, :mark_revoked, %{revoked_by_id: actor.id})
        :ok = Ledger.archive!(grant, :revoke)

        Ledger.create!(AdminEvent, :record, %{
          actor_id: actor.id,
          target_id: grant.id,
          kind: :vm_grant_revoke
        })

        %{id: grant.id, revoked: true, vm_id: grant.vm_id, user_id: grant.user_id}
    end
  end

  defp after_id(query, nil), do: query
  defp after_id(query, id), do: Ash.Query.filter(query, id > ^id)
end
