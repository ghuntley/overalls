defmodule Ziggy.Upstream do
  @moduledoc "Native, single-attempt provider streaming with synchronous backpressure."
  require Ziggy.Events

  @type result :: %{
          status: integer() | nil,
          provider_request_id: binary() | nil,
          response_bytes: non_neg_integer(),
          usage: map(),
          outcome: atom()
        }

  # @cc [owner:ghuntley,label:security] upstream-fixed-origin-single-attempt
  # The caller MUST already hold durable admission and live request authority.
  # Production requests MUST use the configured fixed provider origin or the
  # host-local Underclass loopback origin, never
  # follow redirects or retry inference. Guest authorization and forwarding
  # headers MUST NOT be sent upstream. Consumer failure MUST cancel streaming.
  # Only the route's validated query enum may add an upstream query; native paths
  # MUST remain query-free for operation accounting.
  @spec stream(
          Ziggy.Route.route(),
          binary(),
          [{binary(), binary()}],
          (term() -> :ok | :halt),
          keyword()
        ) :: result()
  def stream(route, key, headers, consume, options) do
    request =
      Finch.build(
        :post,
        origin(route.provider, options) <> route.path <> query_suffix(route.query),
        headers(route.provider, key, headers),
        route.body
      )

    initial = %{
      status: nil,
      provider_request_id: nil,
      response_bytes: 0,
      usage: Ziggy.Usage.new(route.provider, :json),
      outcome: :completed
    }

    finch = Keyword.fetch!(options, :finch)
    request_id = Keyword.fetch!(options, :request_id)
    true = is_binary(request_id)
    callback = fn event, state -> receive_event(event, state, route.provider, consume) end

    finch_module = Keyword.get(options, :finch_module, Finch)

    case finch_module.stream_while(request, finch, initial, callback,
           pool_timeout: 5000,
           receive_timeout: 30_000,
           request_timeout: :infinity
         ) do
      {:ok, state} ->
        state = %{state | usage: Ziggy.Usage.finish(state.usage)}
        Ziggy.Events.emit("ziggy.upstream_outcome", request_id: request_id, reason: state.outcome)
        state

      {:error, _reason, state} ->
        state = %{state | usage: Ziggy.Usage.finish(state.usage), outcome: :transport_error}

        Ziggy.Events.emit("ziggy.upstream_outcome", request_id: request_id, reason: state.outcome)
        state
    end
  end

  defp origin(:openai, options),
    do: Keyword.get(options, :openai_origin, Ziggy.Route.origin(:openai))

  defp origin(provider, _options), do: Ziggy.Route.origin(provider)

  @spec query_suffix(Ziggy.Route.query()) :: binary()
  defp query_suffix(:none), do: ""
  defp query_suffix(:anthropic_beta), do: "?beta=true"

  @spec headers(:openai | :anthropic, binary(), [{binary(), binary()}]) :: [{binary(), binary()}]
  def headers(provider, key, guest) do
    allowed = if provider == :anthropic, do: ~w(anthropic-version anthropic-beta), else: []

    native =
      Enum.filter(guest, fn {name, value} ->
        name in allowed and byte_size(value) <= 4096 and not String.contains?(value, ["\r", "\n"])
      end)

    auth =
      case provider do
        :openai -> [{"authorization", "Bearer " <> key}]
        :anthropic -> [{"x-api-key", key}]
      end

    version =
      if provider == :anthropic and not List.keymember?(native, "anthropic-version", 0),
        do: [{"anthropic-version", "2023-06-01"}],
        else: []

    auth ++
      version ++
      native ++
      [{"content-type", "application/json"}, {"accept", "application/json, text/event-stream"}]
  end

  defp receive_event({:status, status}, state, _, consume) do
    outcome = if status in 200..299, do: :completed, else: :upstream_error
    deliver(consume, {:status, status}, %{state | status: status, outcome: outcome})
  end

  defp receive_event({:headers, headers}, state, provider, consume) do
    mode =
      if Enum.any?(headers, fn {name, value} ->
           name == "content-type" and String.starts_with?(value, "text/event-stream")
         end), do: :sse, else: :json

    safe =
      Enum.filter(headers, fn {name, _} ->
        name in ~w(content-type request-id x-request-id retry-after)
      end)

    request_id =
      Enum.find_value(headers, fn {key, value} ->
        if key in ["request-id", "x-request-id"] and is_binary(value) and
             byte_size(value) in 1..256 and
             Regex.match?(~r/\A[a-zA-Z0-9._:\/-]+\z/, value),
           do: value
      end)

    deliver(consume, {:headers, safe}, %{
      state
      | usage: Ziggy.Usage.new(provider, mode),
        provider_request_id: request_id
    })
  end

  defp receive_event({:data, bytes}, state, _, consume) do
    usage =
      if state.status in 200..299, do: Ziggy.Usage.feed(state.usage, bytes), else: state.usage

    deliver(consume, {:data, bytes}, %{
      state
      | response_bytes: state.response_bytes + byte_size(bytes),
        usage: usage
    })
  end

  defp receive_event(_, state, _, _), do: {:cont, state}

  defp deliver(consume, event, state) do
    case consume.(event) do
      :ok -> {:cont, state}
      :halt -> {:halt, %{state | outcome: :cancelled}}
    end
  end
end
