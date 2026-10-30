defmodule Marshall.Inference.Views do
  @moduledoc "Bounded owner and authenticated fleet accounting views. Sharing does not change owner projections."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Authorization.SystemActor
  alias Marshall.Inference.{Request, Daily}
  require Ash.Query

  # @cc [owner:ghuntley,label:security] inference-owner-accounting-visibility
  # Owner reads MUST filter on the authenticated persisted user, never a claimed
  # owner or VM sharing membership. Fleet reads MUST recheck current Cedar Control room read
  # authority. Detail pages MUST be bounded and keyset-paginated.
  @impl true
  def run(input, opts, %{actor: %Marshall.Accounts.User{} = user}) do
    admin = opts[:admin] == true

    permitted =
      if admin,
        do: Marshall.Authorization.control_plane?(user, "admin_read"),
        else: Marshall.Authorization.control_plane?(user, "provision")

    with true <- permitted,
         {:ok, filters} <- filters(input.arguments.filters),
         {:ok, query} <- cursor(scope(Request, user, admin, filters), filters["after"]) do
      rows =
        query
        |> Ash.Query.sort(inserted_at: :desc, id: :desc)
        |> Ash.Query.limit(101)
        |> Ash.read!(actor: SystemActor.compute())

      page = Enum.take(rows, 100)
      next = if length(rows) > 100, do: encode_cursor(List.last(page))
      daily = scope(Daily, user, admin, filters)
      totals = totals(daily)
      today = DateTime.to_date(Marshall.Compute.Ledger.now())

      chart =
        for offset <- 29..0//-1 do
          day = Date.add(today, -offset)
          %{day: Date.to_iso8601(day), totals: totals(Ash.Query.filter(daily, day == ^day))}
        end

      {:ok, %{rows: Enum.map(page, &view/1), next: next, totals: totals, chart: chart}}
    else
      _ -> {:error, Ash.Error.Forbidden.exception([])}
    end
  end

  def run(_, _, _), do: {:error, Ash.Error.Forbidden.exception([])}

  defp scope(resource, user, admin, filters) do
    query =
      if admin,
        do: Ash.Query.new(resource),
        else: Ash.Query.filter(resource, owner_id == ^user.id)

    query =
      case filters["provider"] do
        "openai" -> Ash.Query.filter(query, provider == :openai)
        "anthropic" -> Ash.Query.filter(query, provider == :anthropic)
        _ -> query
      end

    if filters["model"], do: Ash.Query.filter(query, model == ^filters["model"]), else: query
  end

  defp filters(value) when is_map(value) do
    if Map.keys(value) -- ~w(provider model after) == [] and
         value["provider"] in [nil, "", "openai", "anthropic"] and
         (is_nil(value["model"]) or value["model"] == "" or
            OverallsProtocol.Inference.model?(value["model"])),
       do: {:ok, Map.reject(value, fn {_, v} -> v == "" end)},
       else: :error
  end

  defp filters(_), do: :error
  defp cursor(query, nil), do: {:ok, query}

  defp cursor(query, text) when is_binary(text) and byte_size(text) <= 256 do
    with {:ok, raw} <- Base.url_decode64(text, padding: false),
         {:ok, [timestamp, id]} <- Jason.decode(raw),
         {:ok, date, 0} <- DateTime.from_iso8601(timestamp),
         true <- OverallsProtocol.uuid?(id) do
      {:ok, Ash.Query.filter(query, inserted_at < ^date or (inserted_at == ^date and id < ^id))}
    else
      _ -> :error
    end
  end

  defp cursor(_, _), do: :error

  defp encode_cursor(row),
    do:
      Jason.encode!([DateTime.to_iso8601(row.inserted_at), row.id])
      |> Base.url_encode64(padding: false)

  defp totals(query) do
    Ash.aggregate!(
      query,
      [
        {:requests, :sum, field: :requests},
        {:unknown_requests, :sum, field: :unknown_requests},
        {:input_tokens, :sum, field: :input_tokens},
        {:output_tokens, :sum, field: :output_tokens}
      ],
      actor: SystemActor.compute()
    )
  end

  defp view(row),
    do:
      Map.take(row, [
        :id,
        :host_id,
        :vm_id,
        :placement_id,
        :execution_epoch,
        :owner_id,
        :provider,
        :model,
        :operation,
        :inserted_at,
        :expires_at,
        :completion
      ])
end
