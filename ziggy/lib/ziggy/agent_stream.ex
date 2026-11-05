defmodule Ziggy.AgentStream do
  @moduledoc "Bounded collector for a single streamed Responses model call."

  @limit 1_048_576
  @max_items 256

  defstruct buffer: "", items: %{}, completed: nil, error: nil, pre_output?: true

  @type error :: Ziggy.AgentError.reason() | :invalid_response | :too_large

  @type t :: %__MODULE__{
          buffer: binary(),
          items: %{optional(non_neg_integer()) => map()},
          completed: map() | nil,
          error: error() | nil,
          pre_output?: boolean()
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

  # @cc [owner:ghuntley,label:recovery] agent-overload-positive-no-output-proof
  # Retry evidence MUST require an exact terminal overload and a complete stream
  # containing only recognized pre-output events. Output, unknown or malformed
  # events, conflicting terminals and a trailing partial frame permanently
  # disqualify it, even when failure handling discards collected output items.
  @spec overload_before_output?(t()) :: boolean()
  def overload_before_output?(%__MODULE__{
        error: :server_is_overloaded,
        pre_output?: true,
        completed: nil,
        buffer: buffer
      }),
      do: String.trim(buffer) == ""

  def overload_before_output?(_), do: false

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
  defp accept(state, frame) do
    lines = String.split(frame, "\n")

    data =
      lines
      |> Enum.filter(&String.starts_with?(&1, "data:"))
      |> Enum.map_join("\n", fn line ->
        line |> String.replace_prefix("data:", "") |> String.replace_prefix(" ", "")
      end)

    decoded = Jason.decode(data)
    state = %{state | pre_output?: state.pre_output? and pre_output_frame?(state, lines, decoded)}
    accept_event(state, decoded)
  end

  @spec accept_event(t(), {:ok, term()} | {:error, Jason.DecodeError.t()}) ::
          {:ok, t()} | {:error, :too_large}
  defp accept_event(%{error: error} = state, _) when not is_nil(error), do: {:ok, state}

  defp accept_event(state, decoded) do
    case decoded do
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

  @spec pre_output_frame?(t(), [binary()], {:ok, term()} | {:error, Jason.DecodeError.t()}) ::
          boolean()
  defp pre_output_frame?(state, lines, decoded) do
    comment? = Enum.all?(lines, &(&1 == "" or String.starts_with?(&1, ":")))

    cond do
      comment? -> true
      state.error != nil or state.completed != nil -> false
      true -> recognized_pre_output?(lines, decoded)
    end
  end

  @spec recognized_pre_output?([binary()], {:ok, term()} | {:error, Jason.DecodeError.t()}) ::
          boolean()
  defp recognized_pre_output?(lines, {:ok, %{"type" => type} = event}) when is_binary(type) do
    valid_lines? =
      Enum.all?(lines, fn line ->
        line == "" or String.starts_with?(line, [":", "data:"]) or
          line in ["event:" <> type, "event: " <> type]
      end)

    valid_lines? and no_output?(event) and
      case type do
        preamble when preamble in ["response.created", "response.in_progress"] ->
          case event do
            %{"response" => response} when is_map(response) ->
              Map.get(response, "status", "in_progress") in ["queued", "in_progress"] and
                Ziggy.AgentError.terminal(response) == nil and no_output?(response)

            _ ->
              false
          end

        "response.failed" ->
          case event do
            %{"response" => response} when is_map(response) ->
              Map.get(response, "status", "failed") == "failed" and no_output?(response) and
                Ziggy.AgentError.classify(response) == :server_is_overloaded

            _ ->
              false
          end

        "error" ->
          Map.keys(event) -- ~w(type code error message param sequence_number) == [] and
            error_without_output?(Map.get(event, "error")) and
            Ziggy.AgentError.classify(event) == :server_is_overloaded

        _ ->
          false
      end
  end

  defp recognized_pre_output?(_, _), do: false

  @spec no_output?(map()) :: boolean()
  defp no_output?(value) do
    Map.get(value, "output", []) == [] and Map.get(value, "choices", []) == [] and
      not Enum.any?(~w(item delta content), &Map.has_key?(value, &1)) and
      no_output_usage?(Map.get(value, "usage"))
  end

  @spec no_output_usage?(term()) :: boolean()
  defp no_output_usage?(nil), do: true

  defp no_output_usage?(usage) when is_map(usage) do
    Enum.all?(~w(output_tokens completion_tokens reasoning_tokens), &(Map.get(usage, &1, 0) == 0)) and
      case Map.get(usage, "output_tokens_details") do
        nil -> true
        details when is_map(details) -> Map.get(details, "reasoning_tokens", 0) == 0
        _ -> false
      end
  end

  defp no_output_usage?(_), do: false

  @spec error_without_output?(term()) :: boolean()
  defp error_without_output?(error) when is_map(error), do: no_output?(error)
  defp error_without_output?(error), do: is_nil(error) or is_binary(error)

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
