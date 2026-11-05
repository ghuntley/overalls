defmodule Ziggy.AgentStream do
  @moduledoc "Bounded collector for a single streamed Responses model call."

  @limit 1_048_576
  @max_items 256

  defstruct buffer: "", items: %{}, completed: nil, error: nil

  @type error :: Ziggy.AgentError.reason() | :invalid_response | :too_large

  @type t :: %__MODULE__{
          buffer: binary(),
          items: %{optional(non_neg_integer()) => map()},
          completed: map() | nil,
          error: error() | nil
        }

  # @cc [owner:ghuntley,label:security;recovery] agent-stream-final-only
  # Only completed output items and the final response may cross to Marshall.
  # Partial deltas, contradictory terminal frames and oversized responses MUST
  # fail without tool dispatch. Native compaction items remain opaque maps.
  @spec feed(t(), binary()) :: {:ok, t()} | {:error, :too_large}
  def feed(%__MODULE__{} = state, bytes) when is_binary(bytes) do
    buffer = String.replace(state.buffer <> bytes, "\r\n", "\n")

    if byte_size(buffer) > @limit * 2 do
      {:error, :too_large}
    else
      frames = String.split(buffer, "\n\n")
      pending = List.last(frames) || ""

      frames
      |> Enum.drop(-1)
      |> Enum.reduce_while({:ok, %{state | buffer: pending}}, fn frame, {:ok, current} ->
        case accept(current, frame) do
          {:ok, next} -> {:cont, {:ok, next}}
          error -> {:halt, error}
        end
      end)
    end
  end

  @spec finish(t()) :: {:ok, map()} | {:error, error()}
  def finish(%__MODULE__{error: error}) when not is_nil(error), do: {:error, error}

  def finish(%__MODULE__{completed: %{"status" => "completed"} = response, items: items}) do
    with {:ok, output} <- output(response, items),
         complete = Map.put(response, "output", output),
         true <- byte_size(Jason.encode!(complete)) <= @limit do
      {:ok, complete}
    else
      false -> {:error, :too_large}
      {:error, _} = error -> error
    end
  end

  def finish(_), do: {:error, :invalid_response}

  @spec output(map(), %{optional(non_neg_integer()) => map()}) ::
          {:ok, [map()]} | {:error, :invalid_response}
  defp output(%{"output" => output}, _items) when is_list(output) and output != [] do
    if length(output) <= @max_items and Enum.all?(output, &is_map/1),
      do: {:ok, output},
      else: {:error, :invalid_response}
  end

  defp output(%{"output" => []}, items) when map_size(items) == 0, do: {:ok, []}

  defp output(response, items) when map_size(items) in 1..@max_items do
    indices = Enum.sort(Map.keys(items))

    if Map.get(response, "output", []) == [] and indices == Enum.to_list(0..(length(indices) - 1)),
      do: {:ok, Enum.map(indices, &Map.fetch!(items, &1))},
      else: {:error, :invalid_response}
  end

  defp output(_, _), do: {:error, :invalid_response}

  @spec accept(t(), binary()) :: {:ok, t()} | {:error, :too_large}
  defp accept(%{error: error} = state, _) when not is_nil(error), do: {:ok, state}

  defp accept(state, frame) do
    data =
      frame
      |> String.split("\n")
      |> Enum.filter(&String.starts_with?(&1, "data:"))
      |> Enum.map_join("\n", fn line ->
        line |> String.replace_prefix("data:", "") |> String.replace_prefix(" ", "")
      end)

    case Jason.decode(data) do
      {:ok, %{"type" => "response.output_item.done", "output_index" => index, "item" => item}}
      when is_integer(index) and index >= 0 and index < @max_items and is_map(item) ->
        items = Map.put(state.items, index, item)

        encoded_bytes =
          Enum.reduce(items, 0, fn {_, value}, count ->
            count + byte_size(Jason.encode!(value))
          end)

        if encoded_bytes <= @limit,
          do: {:ok, %{state | items: items}},
          else: {:error, :too_large}

      {:ok, %{"type" => "response.completed", "response" => response}}
      when is_map(response) ->
        complete(state, response)

      {:ok, %{"type" => type} = event}
      when type in [
             "error",
             "response.failed",
             "response.incomplete",
             "response.cancelled",
             "response.canceled"
           ] ->
        reason =
          case type do
            "response.incomplete" -> :incomplete
            cancelled when cancelled in ["response.cancelled", "response.canceled"] -> :cancelled
            _ -> Ziggy.AgentError.classify(Map.get(event, "response", event))
          end

        {:ok, %{state | completed: nil, items: %{}, error: reason}}

      {:ok, %{"type" => "response.output_item.done"}} ->
        {:error, :too_large}

      _ ->
        {:ok, state}
    end
  end

  @spec complete(t(), map()) :: {:ok, t()} | {:error, :too_large}
  defp complete(%{completed: completed} = state, _) when not is_nil(completed),
    do: {:ok, %{state | completed: nil, items: %{}, error: :invalid_response}}

  defp complete(state, response) do
    cond do
      byte_size(Jason.encode!(response)) > @limit ->
        {:error, :too_large}

      reason = Ziggy.AgentError.terminal(response) ->
        {:ok, %{state | completed: nil, items: %{}, error: reason}}

      response["status"] == "completed" ->
        {:ok, %{state | completed: response}}

      true ->
        {:ok, %{state | completed: nil, items: %{}, error: :invalid_response}}
    end
  end
end
