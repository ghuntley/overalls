defmodule Marshall.Accounts.AdminEvents do
  @moduledoc "Bounded redacted administrator audit projection."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Accounts.AdminEvent
  alias Marshall.Authorization.SystemActor
  require Ash.Query

  # @cc [owner:ghuntley,label:security;capacity] admin-audit-bounded-projection
  # Audit reads MUST recheck current Control room read authority, return at most 100
  # rows, and expose only actor/target identifiers, action kind and UTC time.
  # Credentials, tokens, request payloads and terminal bytes MUST never escape.
  @impl true
  def run(input, _, %{actor: actor}) do
    if Marshall.Authorization.control_plane?(actor, "admin_read") do
      query =
        AdminEvent
        |> Ash.Query.sort(inserted_at: :desc, id: :desc)
        |> Ash.Query.limit(input.arguments.limit + 1)

      query = before_cursor(query, input.arguments.before)

      rows = Ash.read!(query, actor: SystemActor.compute())

      {:ok,
       %{
         items:
           rows
           |> Enum.take(input.arguments.limit)
           |> Enum.map(&Map.take(&1, [:id, :actor_id, :target_id, :kind, :inserted_at])),
         next_cursor:
           if(length(rows) > input.arguments.limit,
             do: Enum.at(rows, input.arguments.limit - 1).id,
             else: nil
           )
       }}
    else
      {:error, Ash.Error.Forbidden.exception([])}
    end
  end

  # @cc [owner:ghuntley,label:observability] admin-audit-cursor-order
  # A cursor MUST select rows older in the full timestamp/id ordering, regardless
  # of UUID generation order. An unknown cursor MUST return no rows rather than
  # restart the history or silently select an unrelated portion of the audit.
  @spec before_cursor(Ash.Query.t(), String.t() | nil) :: Ash.Query.t()
  defp before_cursor(query, nil), do: query

  defp before_cursor(query, id) do
    cursor =
      AdminEvent
      |> Ash.Query.filter(id == ^id)
      |> Ash.read_one!(actor: SystemActor.compute())

    case cursor do
      nil ->
        Ash.Query.filter(query, false)

      %{inserted_at: timestamp} ->
        Ash.Query.filter(
          query,
          inserted_at < ^timestamp or (inserted_at == ^timestamp and id < ^id)
        )
    end
  end
end
