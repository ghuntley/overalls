defmodule Marshall.Compute.AdminViews do
  @moduledoc "Bounded administrator workload projections."
  use Ash.Resource.Actions.Implementation

  alias Marshall.Accounts.User
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.{Ledger, VirtualMachine}
  require Ash.Query

  @fields ~w(id name profile architecture image_id vcpu memory_bytes disk_bytes desired_state observed_state failure_reason generation inserted_at current_placement_id)a

  @impl true
  def run(input, _options, %{actor: %User{} = actor}) do
    Ledger.transaction(fn ->
      unless Marshall.Authorization.control_plane?(actor, "admin_read"),
        do: Ledger.rollback(:forbidden)

      list(input.arguments)
    end)
  end

  def run(_, _, _), do: {:error, Ash.Error.Forbidden.exception([])}

  # @cc [owner:ghuntley,label:security] admin-workload-projection
  # Fleet workload inventory MUST be bounded, current and explicitly projected;
  # it MUST not expose credentials, terminal content, placement internals or
  # archived identity history.
  defp list(args) do
    limit = args[:limit] || 100

    rows =
      VirtualMachine
      |> Ash.Query.filter(is_nil(archived_at))
      |> after_id(args[:after])
      |> Ash.Query.sort(id: :asc)
      |> Ash.Query.limit(limit + 1)
      |> Ash.read!(actor: SystemActor.compute())

    owner_ids = rows |> Enum.map(& &1.owner_id) |> Enum.uniq()

    owners =
      User
      |> Ash.Query.for_read(:internal_lookup)
      |> Ash.Query.filter(id in ^owner_ids)
      |> Ash.read!(actor: SystemActor.compute())
      |> Map.new(&{&1.id, &1})

    items =
      rows
      |> Enum.take(limit)
      |> Enum.map(fn vm ->
        Map.take(vm, @fields)
        |> Map.put(:owner_id, vm.owner_id)
        |> Map.put(:owner_email, owners[vm.owner_id].email)
        |> Map.put(:owner_time_zone, owners[vm.owner_id].time_zone)
        |> Map.put(:host_id, vm.host_id)
      end)

    %{items: items, next_cursor: if(length(rows) > limit, do: List.last(items).id)}
  end

  defp after_id(query, nil), do: query
  defp after_id(query, id), do: Ash.Query.filter(query, id > ^id)
end
