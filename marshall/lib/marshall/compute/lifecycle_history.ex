defmodule Marshall.Compute.LifecycleHistory do
  @moduledoc "Bounded authenticated lifecycle history with immediate expiry."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.LifecycleEvent
  require Ash.Query

  # @cc [owner:ghuntley,label:security;capacity] lifecycle-history-authority
  # Reads MUST recheck current admin_read authority, return at most 100 projected
  # events and exclude expired history even before retention cleanup executes.
  @impl true
  def run(input, _, %{actor: actor}) do
    if Marshall.Authorization.control_plane?(actor, "admin_read") do
      args = input.arguments
      query = LifecycleEvent |> Ash.Query.sort(id: :desc) |> Ash.Query.limit(args.limit + 1)

      query =
        Enum.reduce([:vm_id, :workflow_id, :host_id, :action], query, fn key, query ->
          if args[key], do: Ash.Query.filter(query, ^[{key, args[key]}]), else: query
        end)

      query = if args[:before], do: Ash.Query.filter(query, id < ^args.before), else: query

      query =
        if args[:since], do: Ash.Query.filter(query, inserted_at >= ^args.since), else: query

      query = if args[:until], do: Ash.Query.filter(query, inserted_at < ^args.until), else: query
      rows = Ash.read!(query, actor: SystemActor.compute())

      fields = [
        :id,
        :actor_kind,
        :actor_id,
        :resource_type,
        :resource_id,
        :action,
        :previous_state,
        :next_state,
        :vm_id,
        :host_id,
        :workflow_id,
        :operation_id,
        :occurred_at,
        :inserted_at
      ]

      {:ok,
       %{
         items: rows |> Enum.take(args.limit) |> Enum.map(&Map.take(&1, fields)),
         next_cursor: if(length(rows) > args.limit, do: Enum.at(rows, args.limit - 1).id)
       }}
    else
      {:error, Ash.Error.Forbidden.exception([])}
    end
  end
end
