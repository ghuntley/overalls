defmodule Galileo.HTTP do
  @moduledoc "Audi-only Unix-socket frontend for named edge integrations."
  @behaviour Plug
  import Plug.Conn
  require Galileo.Events
  alias Galileo.Strip
  alias OverallsProtocol.Integration
  @chunk_size 65_536

  @impl true
  def init(opts), do: opts

  @impl true
  @spec call(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def call(conn, config) do
    Overalls.Diagnostics.Tracing.with_span("galileo.http", [], fn -> call_traced(conn, config) end)
  end

  # @cc [owner:ghuntley,label:security] galileo-private-frontend-only
  # This Plug MUST only be mounted on the private Audi Unix socket. Audi MUST
  # supply the binding from Lilly's pre-NAT execution lookup. Galileo MUST
  # revalidate the binding and integration name with Marshall before any
  # upstream effect, and MUST never retry an authorized request.
  defp call_traced(
         %{method: "GET", request_path: "/health/ready", query_string: ""} = conn,
         config
       ) do
    ready =
      with {:ok, %{"host_id" => host}} <- Galileo.Control.request(config.control, "identity", %{}),
           do: host == config.host_id,
           else: (_ -> false)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      if(ready, do: 200, else: 503),
      Jason.encode!(%{version: 1, ready: ready, role: "galileo", host_id: config.host_id})
    )
  end

  # @cc [owner:ghuntley,label:security] galileo-monitor-numeric-projection
  # The host-only Unix socket MUST expose only bounded numeric operational
  # measurements, never request identities, content, credentials or raw errors.
  defp call_traced(%{method: "GET", request_path: "/metrics", query_string: ""} = conn, config) do
    gauges = %{
      "galileo_active_requests" => :counters.get(Galileo.Counter.counters(), 1),
      "galileo_total_requests" => :counters.get(Galileo.Counter.counters(), 2)
    }

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{version: 1, host_id: config.host_id, gauges: gauges}))
  end

  # @cc [owner:ghuntley,label:security] galileo-slo-private-projection
  # Only the local Unix frontend may return this fixed numeric snapshot;
  # request identity, upstream targets, headers and payloads MUST stay absent.
  defp call_traced(
         %{method: "GET", host: "localhost", request_path: "/slo", query_string: ""} = conn,
         _config
       ) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(Galileo.SLO.snapshot()))
  end

  defp call_traced(conn, config) do
    zone = "." <> OverallsProtocol.PrivateServices.integration_zone()

    with [host] <- get_req_header(conn, "host"),
         {:ok, name} <- integration_label(host),
         true <- host == name <> zone,
         [encoded] when byte_size(encoded) <= 2048 <- get_req_header(conn, "x-overalls-binding"),
         {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, wire} <- Jason.decode(json),
         {:ok, %{host_id: host_id}} <- OverallsProtocol.PrivateServices.binding(wire),
         true <- host_id == config.host_id do
      if name == OverallsProtocol.GitHub.name(),
        do: Galileo.GitHub.HTTP.call(conn, config, wire),
        else: proxy(conn, config, wire, name)
    else
      _ ->
        Galileo.Events.emit("galileo.request_denied",
          host_id: config.host_id,
          reason: :unauthorized
        )

        error(conn, 403, "unauthorized")
    end
  rescue
    _ ->
      Galileo.Events.emit("galileo.request_denied", host_id: config.host_id, reason: :unavailable)
      error(conn, 503, "unavailable")
  end

  @spec integration_label(String.t()) :: {:ok, String.t()} | {:error, :invalid_hostname}
  defp integration_label("com-github.integration.internal"), do: {:ok, "com-github"}
  defp integration_label(host), do: Integration.label(host)

  # @cc [owner:ghuntley,label:reliability;security] galileo-request-cleanup
  # After incrementing the active-request counter, this request MUST decrement
  # it exactly once and delete its process-local connection state before every
  # normal return, exception, throw or exit, without retrying the upstream attempt.
  defp proxy(conn, config, wire, name) do
    with {:ok, authorization} <- authorize(config, wire, name) do
      :counters.add(Galileo.Counter.counters(), 1, 1)
      started_us = System.monotonic_time(:microsecond)
      ticket = Overalls.RequestAccounting.Producer.admit(Galileo.RequestRecorder)
      Process.put({__MODULE__, :slo_recorded}, false)

      {result, final} =
        try do
          :counters.add(Galileo.Counter.counters(), 2, 1)
          Galileo.Events.emit("galileo.request_authorized", host_id: config.host_id)

          path = Strip.apply(authorization.strip_prefix, conn.request_path)
          query = if conn.query_string == "", do: "", else: "?" <> conn.query_string
          Process.put({__MODULE__, :conn}, conn)
          stream = Map.get(config, :upstream_stream, &Galileo.Upstream.stream/2)

          result =
            stream.(
              authorization,
              method: conn.method,
              path: path,
              query: query,
              body_state: conn,
              pull: &pull/1,
              request_content: Galileo.Upstream.request_content(conn.req_headers),
              pull_in_owner: true,
              cancel_frontend:
                Map.get_lazy(config, :cancel_frontend, fn -> frontend_cancel(conn) end),
              body_updated: fn next ->
                Process.put({__MODULE__, :conn}, next)
                :ok
              end,
              headers: conn.req_headers,
              consume: &consume/1,
              renew: fn -> renew(config, wire, name) end
            )

          final = Process.get({__MODULE__, :conn})

          success =
            result.outcome == :completed and is_integer(result.status) and result.status < 500 and
              final.state in [:chunked, :sent]

          Overalls.RequestAccounting.Producer.complete(
            Galileo.RequestRecorder,
            ticket,
            if(success, do: :success, else: :failure),
            max(System.monotonic_time(:microsecond) - started_us, 0)
          )

          Galileo.SLO.record(
            result.outcome == :completed and is_integer(result.status) and result.status < 500 and
              final.state in [:chunked, :sent],
            max(System.monotonic_time(:microsecond) - started_us, 0)
          )

          Process.put({__MODULE__, :slo_recorded}, true)
          {result, final}
        after
          unless Process.get({__MODULE__, :slo_recorded}) do
            Overalls.RequestAccounting.Producer.complete(
              Galileo.RequestRecorder,
              ticket,
              :failure,
              max(System.monotonic_time(:microsecond) - started_us, 0)
            )

            Galileo.SLO.record(false, max(System.monotonic_time(:microsecond) - started_us, 0))
          end

          :counters.add(Galileo.Counter.counters(), 1, -1)
          Process.delete({__MODULE__, :slo_recorded})
          Process.delete({__MODULE__, :conn})
        end

      Galileo.Events.emit("galileo.upstream_outcome",
        host_id: config.host_id,
        reason: result.outcome
      )

      if final.state in [:chunked, :sent],
        do: final,
        else: error(final, 502, "upstream_unavailable")
    else
      {:error, :unauthorized} ->
        error(conn, 403, "unauthorized")

      {:error, reason} when reason in [:authority_unavailable, :unsupported_version] ->
        error(conn, 503, "admission_unavailable")
    end
  end

  # @cc [owner:ghuntley,label:security] galileo-authorize-before-upload
  # Marshall authorization MUST complete before Galileo pulls the first request
  # body chunk or opens the upstream connection. Each pull is bounded and updates
  # connection state in Bandit's stream owner. The lease guardian MUST close
  # the frontend transport on cancellation to interrupt blocked reads or writes.
  defp pull(conn) do
    case read_body(conn, length: @chunk_size, read_length: @chunk_size, read_timeout: 10_000) do
      {:more, bytes, conn} ->
        {:more, bytes, conn}

      {:ok, bytes, conn} ->
        {:ok, bytes, conn}

      _ ->
        {:error, :invalid_body}
    end
  end

  # @cc [owner:ghuntley,label:security;reliability] galileo-native-frontend-cancellation
  # The pinned HTTP/1 Bandit adapter exposes its ThousandIsland socket. Native
  # cancellation MUST close that socket through the transport API, without
  # modifying adapter ownership or killing the owner before cleanup executes.
  @spec frontend_cancel(Plug.Conn.t()) :: (-> :ok)
  def frontend_cancel(%Plug.Conn{
        adapter:
          {Bandit.Adapter, %Bandit.Adapter{transport: %Bandit.HTTP1.Socket{socket: socket}}}
      }) do
    fn ->
      _ = ThousandIsland.Socket.close(socket)
      :ok
    end
  end

  def frontend_cancel(%Plug.Conn{adapter: {Plug.Adapters.Test.Conn, _}}), do: fn -> :ok end

  defp authorize(config, wire, name) do
    case Galileo.Control.request(config.control, "authorize", %{"binding" => wire, "name" => name}) do
      {:ok, response} ->
        case OverallsProtocol.Integration.authorization(response) do
          {:ok, authorization} -> {:ok, authorization}
          _ -> {:error, :authority_unavailable}
        end

      {:error, :unauthorized} = refusal ->
        Galileo.Events.emit("galileo.request_denied",
          host_id: config.host_id,
          reason: :unauthorized
        )

        refusal

      {:error, :unsupported_version} = refusal ->
        refusal

      _ ->
        Galileo.Events.emit("galileo.control_exchange_failed",
          host_id: config.host_id,
          reason: :unavailable
        )

        {:error, :authority_unavailable}
    end
  end

  # @cc [owner:ghuntley,label:observability] galileo-lease-renewal-outcome
  # Every renewal attempt MUST emit exactly one closed outcome (granted,
  # refused, invalid or unavailable) with no binding, name or credential.
  defp renew(config, wire, name) do
    result =
      case Galileo.Control.request(config.control, "renew", %{"binding" => wire, "name" => name}) do
        {:ok, response} -> OverallsProtocol.Integration.renewal(response)
        {:error, :unauthorized} = refusal -> refusal
        {:error, :unsupported_version} = refusal -> refusal
        _ -> {:error, :authority_unavailable}
      end

    Galileo.Events.emit("galileo.lease_renewal",
      host_id: Map.get(config, :host_id),
      reason: renewal_outcome(result)
    )

    result
  end

  @spec renewal_outcome(term()) :: :granted | :refused | :invalid | :unavailable
  defp renewal_outcome({:ok, _ttl}), do: :granted
  defp renewal_outcome({:error, :unauthorized}), do: :refused
  defp renewal_outcome({:error, :authority_unavailable}), do: :unavailable
  defp renewal_outcome(_other), do: :invalid

  defp consume({:status, status}) do
    update_conn(&%{&1 | status: status})
    :ok
  end

  defp consume({:headers, headers}) do
    update_conn(fn conn ->
      conn =
        Enum.reduce(headers, conn, fn {name, value}, acc -> put_resp_header(acc, name, value) end)

      send_chunked(conn, conn.status)
    end)

    :ok
  end

  defp consume({:data, bytes}) do
    case chunk(Process.get({__MODULE__, :conn}), bytes) do
      {:ok, conn} ->
        Process.put({__MODULE__, :conn}, conn)
        :ok

      {:error, _} ->
        :halt
    end
  end

  defp update_conn(fun),
    do: Process.put({__MODULE__, :conn}, fun.(Process.get({__MODULE__, :conn})))

  defp error(%{state: state} = conn, _, _) when state in [:chunked, :sent], do: conn

  defp error(conn, status, reason),
    do:
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(%{error: reason}))
      |> halt()
end
