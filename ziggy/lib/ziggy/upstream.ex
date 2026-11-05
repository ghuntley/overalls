defmodule Ziggy.Upstream do
  @moduledoc "Native, single-attempt provider streaming with synchronous backpressure."
  require Ziggy.Events

  @type result :: %{
          status: integer() | nil,
          provider_request_id: binary() | nil,
          retry_safe: boolean(),
          trusted_proxy: boolean(),
          headers_received: boolean(),
          response_bytes: non_neg_integer(),
          usage: map(),
          outcome: atom()
        }

  # @cc [owner:ghuntley,label:security] upstream-fixed-origin-single-attempt
  # The caller MUST already hold durable admission and live request authority.
  # Production requests MUST use the configured fixed provider origin or the
  # configured Underclass loopback or exact Panterloons HTTPS origin, never
  # follow redirects or retry inference. Guest authorization and forwarding
  # headers MUST NOT be sent upstream. Consumer failure MUST cancel streaming.
  # Only the route's validated query enum may add an upstream query; native paths
  # MUST remain query-free for operation accounting.
  # Underclass may hold each pool attempt before output, so its receive timeout
  # MUST allow the model call's ten-minute authority window. The independent
  # lease MUST still cancel a blocked read when authority expires or is revoked.
  @spec stream(
          Ziggy.Route.route(),
          binary(),
          [{binary(), binary()}],
          (term() -> :ok | :halt),
          keyword()
        ) :: result()
  def stream(route, key, headers, consume, options) do
    request_id = Keyword.fetch!(options, :request_id)
    true = Ziggy.RequestId.valid?(request_id)
    origin = origin(route.provider, options)

    request =
      Finch.build(
        :post,
        origin <> route.path <> query_suffix(route.query),
        [{"x-request-id", request_id} | headers(route.provider, key, headers)],
        route.body
      )

    initial = %{
      status: nil,
      provider_request_id: nil,
      retry_safe: false,
      trusted_proxy: route.provider == :openai and underclass_origin?(origin),
      headers_received: false,
      response_bytes: 0,
      usage: Ziggy.Usage.new(route.provider, :json),
      outcome: :completed
    }

    finch = Keyword.fetch!(options, :finch)
    callback = fn event, state -> receive_event(event, state, route.provider, consume) end

    finch_module = Keyword.get(options, :finch_module, Finch)
    started = System.monotonic_time(:millisecond)
    Ziggy.Events.emit("ziggy.upstream_started", request_id: request_id)

    state =
      case finch_module.stream_while(request, finch, initial, callback,
             pool_timeout: 5000,
             receive_timeout: if(initial.trusted_proxy, do: 600_000, else: 30_000),
             request_timeout: :infinity
           ) do
        {:ok, state} -> state
        {:error, _reason, state} -> %{state | outcome: :transport_error, retry_safe: false}
      end

    Ziggy.Events.emit("ziggy.upstream_outcome",
      request_id: request_id,
      reason: state.outcome,
      status: state.status,
      duration_ms: System.monotonic_time(:millisecond) - started
    )

    %{state | usage: Ziggy.Usage.finish(state.usage)}
  end

  @spec underclass_origin?(binary()) :: boolean()
  defp underclass_origin?(origin),
    do: origin in ["http://127.0.0.1:8080", "https://panterloons.lorikeet-bangus.ts.net"]

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

    safe = Enum.filter(headers, fn {name, _} -> name in ~w(content-type retry-after) end)

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
        provider_request_id: request_id,
        retry_safe:
          state.trusted_proxy and not state.headers_received and retry_safe_header?(headers),
        headers_received: true
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

  # @cc [owner:ghuntley,label:security;recovery] proxy-retry-evidence-is-private
  # Only one exact proxy-owned safety header from a configured Underclass origin
  # may establish evidence. It MUST NOT be forwarded to guests or inferred from
  # provider status, arbitrary values or guest headers. Response identities MUST
  # NOT overwrite Ziggy's admitted x-request-id.
  @spec retry_safe_header?([{binary(), binary()}]) :: boolean()
  defp retry_safe_header?(headers) do
    for({name, value} <- headers, String.downcase(name) == "x-underclass-retry-safe", do: value) ==
      ["pre-output-overload"]
  end

  defp deliver(consume, event, state) do
    case consume.(event) do
      :ok -> {:cont, state}
      :halt -> {:halt, %{state | outcome: :cancelled, retry_safe: false}}
    end
  end
end
