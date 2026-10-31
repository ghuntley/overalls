defmodule Galileo.GitHub.HTTP do
  @moduledoc "Provider-specific GitHub edge adapter; no provider credential enters a guest."
  import Plug.Conn
  alias OverallsProtocol.GitHub
  alias Galileo.GitHub.{Capabilities, Response}
  require Galileo.Events
  @json_limit 8_388_608
  @redirect_limit 3
  @state_key {__MODULE__, :response}
  @success_key {__MODULE__, :success}
  @upload_key {__MODULE__, :upload}
  @type config :: %{required(:control) => Galileo.Control.t(), optional(atom()) => term()}

  @spec call(Plug.Conn.t(), config(), map()) :: Plug.Conn.t()
  def call(conn, config, binding) do
    started = System.monotonic_time(:millisecond)

    with {:ok, route} <- GitHub.request(conn.method, conn.request_path, conn.query_string),
         {:ok, wire} <-
           Galileo.Control.request(config.control, "github.authorize", %{
             "binding" => binding,
             "route" => GitHub.encode_route(route)
           }),
         {:ok, authorization} <- GitHub.authorization(wire),
         true <- authorization.target == GitHub.origin(route.kind),
         expires_at = started + authorization.ttl,
         true <- System.monotonic_time(:millisecond) < expires_at do
      counted(
        conn,
        Map.put(config, :github_lease_expires_at, expires_at),
        binding,
        route,
        authorization
      )
    else
      {:error, :unauthorized} ->
        Galileo.Events.emit("galileo.request_denied",
          host_id: Map.get(config, :host_id),
          reason: :unauthorized
        )

        error(conn, 403, "unauthorized")

      {:error, :invalid_route} ->
        error(conn, 403, "unsupported_route")

      _ ->
        Galileo.Events.emit("galileo.control_exchange_failed",
          host_id: Map.get(config, :host_id),
          reason: :unavailable
        )

        error(conn, 503, "admission_unavailable")
    end
  end

  # @cc [owner:ghuntley,label:security;reliability] github-single-attempt-mutations
  # Admission MUST precede upload and every upstream effect. Mutating requests
  # MUST never retry or follow redirects. GET/HEAD may follow at most three
  # approved GitHub/download redirects, renewing the same lease before each
  # next effect. Signed download targets MUST receive no provider credentials.
  @spec counted(Plug.Conn.t(), config(), map(), GitHub.route(), GitHub.authorization()) ::
          Plug.Conn.t()
  defp counted(conn, config, binding, route, authorization) do
    :counters.add(Galileo.Counter.counters(), 1, 1)
    :counters.add(Galileo.Counter.counters(), 2, 1)
    started = System.monotonic_time(:microsecond)
    ticket = Overalls.RequestAccounting.Producer.admit(Galileo.RequestRecorder)

    Process.put(@state_key, %{
      conn: conn,
      status: nil,
      mode: :pending,
      headers: [],
      bytes: [],
      size: 0
    })

    Process.put(@success_key, false)

    try do
      Galileo.Events.emit("galileo.request_authorized", host_id: Map.get(config, :host_id))
      run(conn, config, binding, route, authorization, @redirect_limit)
    after
      duration = max(0, System.monotonic_time(:microsecond) - started)
      success = Process.get(@success_key, false)

      Overalls.RequestAccounting.Producer.complete(
        Galileo.RequestRecorder,
        ticket,
        if(success, do: :success, else: :failure),
        duration
      )

      Galileo.SLO.record(success, duration)
      Process.delete(@success_key)
      Process.delete(@upload_key)
      Process.delete(@state_key)
      :counters.add(Galileo.Counter.counters(), 1, -1)

      _ =
        Galileo.Control.request(config.control, "github.close", %{
          "binding" => binding,
          "lease" => GitHub.encode_lease(authorization.lease)
        })
    end
  end

  @spec run(
          Plug.Conn.t(),
          config(),
          map(),
          GitHub.route(),
          GitHub.authorization(),
          non_neg_integer()
        ) :: Plug.Conn.t()
  defp run(conn, config, binding, route, authorization, remaining) do
    context = %{
      binding: binding,
      lease: authorization.lease,
      capabilities: Map.get(config, :capabilities, Capabilities),
      route: route
    }

    Process.delete(@upload_key)

    with true <- System.monotonic_time(:millisecond) < config.github_lease_expires_at,
         {:ok, authorization, route} <- destination(authorization, route, context) do
      context = %{context | route: route}

      Process.put(@state_key, %{
        conn: conn,
        status: nil,
        mode: :pending,
        headers: [],
        bytes: [],
        size: 0
      })

      stream = Map.get(config, :github_upstream_stream, &Galileo.Upstream.stream/2)

      result =
        stream.(authorization,
          method: route.method,
          path: route.path,
          query: if(route.query == "", do: "", else: "?" <> route.query),
          body_state: conn,
          pull: if(remaining == @redirect_limit, do: &pull/1, else: &empty_pull/1),
          request_content:
            if(remaining == @redirect_limit,
              do: Galileo.Upstream.request_content(conn.req_headers),
              else: :none
            ),
          pull_in_owner: true,
          cancel_frontend:
            Map.get_lazy(config, :cancel_frontend, fn -> Galileo.HTTP.frontend_cancel(conn) end),
          headers: GitHub.request_headers(conn.req_headers),
          response_headers: fn headers -> headers end,
          lease_expires_at: config.github_lease_expires_at,
          consume: &consume(&1, route, context),
          body_updated: fn next ->
            update(&Map.put(&1, :conn, next))
            :ok
          end,
          renew: fn -> renew(config, binding, authorization.lease) end
        )

      state = Process.get(@state_key)

      Galileo.Events.emit("galileo.upstream_outcome",
        host_id: Map.get(config, :host_id),
        reason: result.outcome
      )

      if result.outcome == :completed do
        finish(state, config, binding, route, authorization, context, remaining)
      else
        error(state.conn, 502, "upstream_unavailable")
      end
    else
      _ -> error(conn, 403, "unavailable_download")
    end
  end

  @spec destination(GitHub.authorization(), GitHub.route(), Response.context()) ::
          {:ok, GitHub.authorization(), GitHub.route()} | {:error, :unavailable}
  defp destination(authorization, %{kind: :capability} = route, context) do
    with {:ok, transfer} <-
           Capabilities.resolve(
             String.replace_prefix(route.path, "/", ""),
             context.binding,
             context.lease,
             route.method,
             context.capabilities
           ),
         {:ok, uri} <- GitHub.transfer_url(transfer.url) do
      headers = transfer.headers

      headers =
        cond do
          route.method == "PUT" and transfer.object != nil ->
            Process.put(@upload_key, %{
              remaining: transfer.object.size,
              oid: transfer.object.oid,
              hash: :crypto.hash_init(:sha256)
            })

            [{"content-length", Integer.to_string(transfer.object.size)} | headers]

          route.method == "POST" and transfer.object != nil ->
            Process.put(@upload_key, %{verify: transfer.object})
            headers

          true ->
            headers
        end

      {:ok, %{authorization | target: "https://" <> uri.host, headers: headers},
       %{route | path: uri.path, query: uri.query || ""}}
    else
      _ -> {:error, :unavailable}
    end
  end

  defp destination(authorization, route, _), do: {:ok, authorization, route}

  @spec consume(tuple(), GitHub.route(), Response.context()) :: :ok | :halt
  defp consume({:status, status}, _route, _context), do: update(&Map.put(&1, :status, status))

  defp consume({:headers, headers}, route, context) do
    state = Process.get(@state_key)

    case if(state.mode == :pending, do: Response.headers(headers, context), else: :trailers) do
      {:ok, safe} ->
        redirect? = state.status in [301, 302, 303, 307, 308]

        json? =
          route.method != "HEAD" and state.status not in [204, 304] and
            Enum.any?(safe, fn {name, value} ->
              name == "content-type" and String.contains?(String.downcase(value), "json")
            end)

        mode =
          cond do
            redirect? and GitHub.read_method?(route.method) ->
              :redirect

            redirect? ->
              :refuse

            json? ->
              :json

            true ->
              :stream
          end

        conn =
          if mode == :stream,
            do: state.conn |> put_headers(safe) |> send_chunked(state.status),
            else: state.conn

        update(&Map.merge(&1, %{headers: safe, mode: mode, conn: conn}))

      :trailers ->
        :ok

      _ ->
        update(&Map.put(&1, :mode, :refuse))
        :halt
    end
  end

  defp consume({:data, bytes}, _route, _context) do
    state = Process.get(@state_key)

    case state.mode do
      :stream ->
        case chunk(state.conn, bytes) do
          {:ok, conn} -> update(&Map.put(&1, :conn, conn))
          _ -> :halt
        end

      :json when state.size + byte_size(bytes) <= @json_limit ->
        update(
          &Map.merge(&1, %{bytes: [bytes | state.bytes], size: state.size + byte_size(bytes)})
        )

      :redirect when state.size + byte_size(bytes) <= 65_536 ->
        update(&Map.put(&1, :size, state.size + byte_size(bytes)))

      _ ->
        :halt
    end
  end

  @spec finish(
          map(),
          config(),
          map(),
          GitHub.route(),
          GitHub.authorization(),
          Response.context(),
          non_neg_integer()
        ) :: Plug.Conn.t()
  defp finish(
         %{mode: :json} = state,
         _config,
         _binding,
         _route,
         _authorization,
         context,
         _remaining
       ) do
    bytes = state.bytes |> Enum.reverse() |> IO.iodata_to_binary()

    case Response.json(bytes, context) do
      {:ok, safe} ->
        Process.put(@success_key, state.status < 500)
        state.conn |> put_headers(state.headers) |> send_resp(state.status, safe)

      _ ->
        error(state.conn, 502, "invalid_upstream_response")
    end
  end

  defp finish(%{mode: :stream, conn: conn}, _, _, _, _, _, _) do
    Process.put(@success_key, conn.status < 500)

    # Plug's chunked responses need an explicit terminal empty chunk. Closing
    # the upstream socket alone leaves clients such as git-lfs with an
    # incomplete object and an unexpected EOF.
    case chunk(conn, "") do
      {:ok, conn} -> conn
      {:error, _} -> conn
    end
  end

  defp finish(
         %{mode: :redirect} = state,
         config,
         binding,
         route,
         authorization,
         _context,
         remaining
       )
       when remaining > 0 do
    with {"location", internal} <- List.keyfind(state.headers, "location", 0),
         %URI{host: host, path: path, query: query} <- URI.parse(internal),
         true <- host == GitHub.hostname(),
         {:ok, redirected} <- GitHub.request(route.method, path, query || ""),
         {:ok, %{ttl: ttl, expires_at: expires_at}} <- renew(config, binding, authorization.lease) do
      redirected_authorization = %{
        authorization
        | target: GitHub.origin(redirected.kind),
          ttl: ttl
      }

      # A download never reacquires provider credentials through another redirect.
      redirected_authorization =
        if route.kind == :capability,
          do: %{redirected_authorization | headers: []},
          else: redirected_authorization

      run(
        state.conn,
        Map.put(config, :github_lease_expires_at, expires_at),
        binding,
        redirected,
        redirected_authorization,
        remaining - 1
      )
    else
      _ -> error(state.conn, 502, "unsupported_redirect")
    end
  end

  defp finish(state, _, _, _, _, _, _), do: error(state.conn, 502, "unsupported_redirect")

  # @cc [owner:ghuntley,label:security] github-control-latency-consumes-lease
  # Authorization and renewal lifetimes MUST start before their authority call.
  # Network or scheduling delay MUST consume that lifetime, never extend the
  # durable request pin that the refresh barrier waits to expire.
  @spec renew(config(), map(), GitHub.lease()) ::
          {:ok, %{ttl: 500..5000, expires_at: integer()}} | {:error, term()}
  defp renew(config, binding, lease) do
    started = System.monotonic_time(:millisecond)

    result =
      case Galileo.Control.request(config.control, "github.renew", %{
             "binding" => binding,
             "lease" => GitHub.encode_lease(lease)
           }) do
        {:ok, wire} ->
          with {:ok, renewal} <- OverallsProtocol.Integration.renewal(wire),
               expires_at = started + renewal.ttl,
               true <- System.monotonic_time(:millisecond) < expires_at do
            {:ok, Map.put(renewal, :expires_at, expires_at)}
          else
            _ -> {:error, :invalid_renewal}
          end

        error ->
          error
      end

    outcome =
      case result do
        {:ok, _} -> :granted
        {:error, :unauthorized} -> :refused
        {:error, :invalid_renewal} -> :invalid
        _ -> :unavailable
      end

    Galileo.Events.emit("galileo.lease_renewal",
      host_id: Map.get(config, :host_id),
      reason: outcome
    )

    result
  end

  @spec pull(Plug.Conn.t()) :: Galileo.Upstream.pull_result()
  defp pull(conn) do
    case read_body(conn, length: 65_536, read_length: 65_536, read_timeout: 10_000) do
      {kind, bytes, conn} when kind in [:ok, :more] ->
        update(&Map.put(&1, :conn, conn))
        validate_upload(kind, bytes, conn, Process.get(@upload_key))

      _ ->
        {:error, :invalid_body}
    end
  end

  @spec empty_pull(Plug.Conn.t()) :: Galileo.Upstream.pull_result()
  defp empty_pull(conn), do: {:ok, "", conn}

  @spec validate_upload(:ok | :more, binary(), Plug.Conn.t(), map() | nil) ::
          Galileo.Upstream.pull_result()
  defp validate_upload(kind, bytes, conn, nil), do: {kind, bytes, conn}

  # @cc [owner:ghuntley,label:security] github-lfs-verify-object-binding
  # Verify actions MUST accept only bounded complete JSON naming the exact
  # capability object and size. Forward only its canonical representation so
  # duplicate fields or parser differences cannot select another object.
  defp validate_upload(:ok, bytes, conn, %{verify: %{oid: oid, size: size}})
       when byte_size(bytes) <= 4096 do
    case Jason.decode(bytes) do
      {:ok, %{"oid" => ^oid, "size" => ^size} = object} when map_size(object) == 2 ->
        canonical = Jason.encode!(%{"oid" => oid, "size" => size})

        if bytes == canonical,
          do: {:ok, canonical, conn},
          else: {:error, :invalid_body}

      _ ->
        {:error, :invalid_body}
    end
  end

  defp validate_upload(_, _, _, %{verify: _}), do: {:error, :invalid_body}

  defp validate_upload(kind, bytes, conn, upload) when byte_size(bytes) <= upload.remaining do
    next = %{
      upload
      | remaining: upload.remaining - byte_size(bytes),
        hash: :crypto.hash_update(upload.hash, bytes)
    }

    Process.put(@upload_key, next)

    cond do
      next.remaining > 0 and kind == :more ->
        {:more, bytes, conn}

      next.remaining == 0 and
          Base.encode16(:crypto.hash_final(next.hash), case: :lower) == next.oid ->
        if kind == :ok, do: {:ok, bytes, conn}, else: upload_eof(bytes, conn)

      true ->
        {:error, :invalid_body}
    end
  end

  defp validate_upload(_, _, _, _), do: {:error, :invalid_body}

  # @cc [owner:ghuntley,label:security] github-lfs-final-byte-fencing
  # The final object bytes MUST remain withheld until digest, exact size and
  # frontend EOF are verified, including chunked bodies whose :more chunk
  # reaches the declared size. No extra body may complete the provider upload.
  @spec upload_eof(binary(), Plug.Conn.t()) :: Galileo.Upstream.pull_result()
  defp upload_eof(bytes, conn) do
    case read_body(conn, length: 1, read_length: 1, read_timeout: 10_000) do
      {:ok, "", conn} ->
        update(&Map.put(&1, :conn, conn))
        {:ok, bytes, conn}

      _ ->
        {:error, :invalid_body}
    end
  end

  @spec update((map() -> map())) :: :ok
  defp update(callback),
    do:
      (
        Process.put(@state_key, callback.(Process.get(@state_key)))
        :ok
      )

  @spec put_headers(Plug.Conn.t(), [{String.t(), String.t()}]) :: Plug.Conn.t()
  defp put_headers(conn, headers),
    do:
      Enum.reduce(headers, conn, fn {name, value}, conn -> put_resp_header(conn, name, value) end)

  @spec error(Plug.Conn.t(), pos_integer(), String.t()) :: Plug.Conn.t()
  defp error(%{state: state}, _, _) when state in [:sent, :chunked], do: exit(:shutdown)

  defp error(conn, status, code),
    do:
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(status, Jason.encode!(%{error: code}))
end
