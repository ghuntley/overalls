defmodule Galileo.Upstream do
  @moduledoc "Native, single-attempt upstream streaming with synchronous backpressure."

  @type body_state :: term()
  @type pull_result ::
          {:more, binary(), body_state()} | {:ok, binary(), body_state()} | {:error, atom()}
  @type source :: (body_state() -> pull_result()) | {:owner, (body_state() -> pull_result())}
  @type result :: %{
          status: integer() | nil,
          response_bytes: non_neg_integer(),
          outcome: atom(),
          body_state: body_state()
        }
  @type option ::
          {:method, binary()}
          | {:path, binary()}
          | {:query, binary()}
          | {:body_state, body_state()}
          | {:pull, (body_state() -> pull_result())}
          | {:body_updated, (body_state() -> :ok)}
          | {:pull_in_owner, boolean()}
          | {:cancel_frontend, (-> :ok)}
          | {:headers, [{binary(), binary()}]}
          | {:consume, (tuple() -> :ok | :halt)}
          | {:response_headers, ([{binary(), binary()}] -> [{binary(), binary()}])}
          | {:renew,
             (-> {:ok, %{required(:ttl) => pos_integer(), optional(:expires_at) => integer()}}
                 | {:error, term()})}
          | {:lease_expires_at, integer()}
          | {:transport_opts, keyword()}
          | {:request_content, request_content()}
  @type request_content :: :none | :stream
  @type lease :: {pid(), reference()}

  @hop_by_hop ~w(connection keep-alive proxy-connection proxy-authenticate proxy-authorization te trailer transfer-encoding upgrade)
  @receive_poll_interval 500

  # @cc [owner:ghuntley,label:security] galileo-upstream-single-attempt
  # The caller MUST already hold a current Marshall authorization. Requests
  # MUST use the fixed TLS-verified target origin from that authorization,
  # never follow redirects and never retry. Injected headers override
  # guest-supplied duplicates; hop-by-hop, host, content-length and
  # forwarding headers are stripped. Consumer failure MUST cancel streaming.
  # Peer requests carry only the platform token and canonical host. The
  # bounded renewable lease MUST cover connection setup, request upload and
  # response receipt; refusal, invalid renewal or expiry closes that attempt.
  # Response waiting MUST check the lease at least every 500 milliseconds;
  # an interval with no response bytes MUST NOT close a still-authorized attempt.
  # Owner-bound sources MUST supply a nonblocking frontend cancellation callback;
  # missing callbacks MUST fail before connecting or reading the source body.
  # Requests whose guest framing declares no content (`request_content: :none`)
  # and whose source is empty MUST be forwarded without chunked framing.
  @spec stream(map(), [option()]) :: result()
  def stream(authorization, options) do
    method = Keyword.fetch!(options, :method)
    path = Keyword.fetch!(options, :path)
    query = Keyword.fetch!(options, :query)
    body_state = Keyword.fetch!(options, :body_state)
    pull = Keyword.fetch!(options, :pull)
    owner_bound = Keyword.get(options, :pull_in_owner, false)
    pull = if owner_bound, do: {:owner, pull}, else: pull

    cancel_frontend =
      case Keyword.fetch(options, :cancel_frontend) do
        {:ok, callback} when is_function(callback, 0) -> callback
        :error when not owner_bound -> fn -> :ok end
        _ -> raise ArgumentError, "owner-bound source requires frontend cancellation"
      end

    body_updated = Keyword.get(options, :body_updated, fn _state -> :ok end)
    guest = Keyword.fetch!(options, :headers)
    consumer = Keyword.fetch!(options, :consume)
    project = Keyword.get(options, :response_headers, &default_response_headers/1)

    consume = fn
      {:headers, headers} -> consumer.({:headers, project.(headers)})
      event -> consumer.(event)
    end

    renew = options |> Keyword.fetch!(:renew) |> Overalls.Diagnostics.Context.wrap()
    transport_opts = Keyword.get(options, :transport_opts, [])
    request_content = Keyword.get(options, :request_content, :stream)

    unless request_content in [:none, :stream],
      do: raise(ArgumentError, "request content must be :none or :stream")

    uri = authorization |> origin() |> URI.parse()

    initial = %{status: nil, response_bytes: 0, outcome: :transport_error, body_state: body_state}

    with %URI{scheme: "https", host: host} when is_binary(host) <- uri,
         true <- valid_ttl?(authorization.ttl),
         port = uri.port || 443,
         transport_opts =
           Keyword.merge(
             transport_opts,
             verify: :verify_peer,
             server_name_indication: String.to_charlist(host),
             customize_hostname_check: [
               match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
             ]
           ),
         expires_at =
           Keyword.get(
             options,
             :lease_expires_at,
             System.monotonic_time(:millisecond) + authorization.ttl
           ),
         true <- is_integer(expires_at) and System.monotonic_time(:millisecond) < expires_at,
         expires_at = min(expires_at, System.monotonic_time(:millisecond) + authorization.ttl),
         lease = start_lease(authorization.ttl, expires_at, renew, cancel_frontend) do
      try do
        case connect_upstream(host, port, transport_opts, lease) do
          {:ok, upstream} ->
            stream_connected(
              upstream,
              lease,
              initial,
              authorization,
              method,
              path <> query,
              body_state,
              pull,
              body_updated,
              guest,
              consume,
              request_content
            )

          {:error, _reason} ->
            cancelled_if_closed(initial, lease)
        end
      after
        stop_lease(lease)
      end
    else
      _ -> initial
    end
  end

  @spec headers(map(), [{binary(), binary()}]) :: [{binary(), binary()}]
  def headers(%{peer: %{endpoint: endpoint, token: token}} = _authorization, _guest) do
    host = endpoint |> URI.parse() |> Map.get(:host)
    [{"host", host}, {"authorization", "galileo-peer " <> token}]
  end

  def headers(%{headers: injected} = _authorization, guest) do
    injected_names = MapSet.new(injected, fn {name, _} -> String.downcase(name) end)

    kept =
      Enum.filter(guest, fn {name, _} ->
        downcased = String.downcase(name)

        downcased not in @hop_by_hop and downcased not in ["host", "content-length"] and
          not String.starts_with?(downcased, "x-forwarded") and
          not MapSet.member?(injected_names, downcased)
      end)

    injected ++ kept
  end

  # @cc [owner:ghuntley,label:reliability] galileo-request-content-framing
  # An HTTP/1.1 guest request declares content only through its own framing: a
  # transfer-encoding or a nonzero content-length (RFC 9112 section 6.3).
  # Requests without content MUST NOT gain chunked framing upstream; an origin
  # that answers without draining an unexpected terminating chunk can otherwise
  # reset the connection before Galileo reads the response. Undeclared framing
  # is a hint, not authority: the one source pull still decides.
  @spec request_content([{binary(), binary()}]) :: request_content()
  def request_content(headers) do
    framing =
      for {name, value} <- headers,
          downcased = String.downcase(name),
          downcased in ["content-length", "transfer-encoding"],
          do: {downcased, String.trim(value)}

    if Enum.all?(framing, &(&1 == {"content-length", "0"})), do: :none, else: :stream
  end

  @spec origin(map()) :: binary()
  def origin(%{peer: %{endpoint: endpoint}}), do: endpoint
  def origin(%{target: target}), do: target

  defp stream_connected(
         upstream,
         lease,
         initial,
         authorization,
         method,
         request_path,
         body_state,
         pull,
         body_updated,
         guest,
         consume,
         request_content
       ) do
    attach_lease(lease, upstream)

    try do
      if lease_open?(lease) do
        request_headers = headers(authorization, guest) ++ [{"connection", "close"}]

        with {:ok, upstream, ref, body_state} <-
               send_request(
                 request_content,
                 upstream,
                 method,
                 request_path,
                 request_headers,
                 body_state,
                 pull,
                 body_updated,
                 lease
               ) do
          receive_response(%{initial | body_state: body_state}, upstream, ref, consume, lease)
        else
          {:error, _reason, _upstream} ->
            cancelled_if_closed(initial, lease)

          {:source_error, _reason, _upstream, body_state} ->
            %{initial | outcome: :source_error, body_state: body_state}

          {:transport_error, _reason, _upstream, body_state} ->
            cancelled_if_closed(%{initial | body_state: body_state}, lease)

          {:lease_closed, _upstream, body_state} ->
            %{initial | outcome: :cancelled, body_state: body_state}
        end
      else
        %{initial | outcome: :cancelled}
      end
    after
      close(upstream)
    end
  end

  defp send_request(:stream, upstream, method, path, headers, body_state, pull, updated, lease) do
    with {:ok, upstream, ref} <- Mint.HTTP.request(upstream, method, path, headers, :stream),
         {:ok, upstream, body_state} <- upload(upstream, ref, body_state, pull, updated, lease),
         do: {:ok, upstream, ref, body_state}
  end

  # A source whose guest framing declares no content is pulled once before the
  # request is written, so a source failure still leaves no request upstream.
  # An empty complete source is sent without chunked framing: methods that
  # anticipate content carry an explicit zero length, others no framing at
  # all. A source that yields bytes anyway (an HTTP/2 or test frontend need not
  # send framing headers) is streamed exactly as `:stream` would, starting with
  # the chunk already pulled.
  defp send_request(:none, upstream, method, path, headers, body_state, pull, updated, lease) do
    case interruptible_pull(body_state, pull, lease) do
      {:ok, "", body_state} ->
        :ok = updated.(body_state)
        body = if method in ~w(POST PUT PATCH), do: "", else: nil

        if lease_open?(lease) do
          case Mint.HTTP.request(upstream, method, path, headers, body) do
            {:ok, upstream, ref} -> {:ok, upstream, ref, body_state}
            {:error, upstream, reason} -> upload_error(reason, upstream, body_state, lease)
          end
        else
          {:lease_closed, upstream, body_state}
        end

      {kind, _bytes, _state} = pulled when kind in [:ok, :more] ->
        if lease_open?(lease) do
          with {:ok, upstream, ref} <- Mint.HTTP.request(upstream, method, path, headers, :stream),
               {:ok, upstream, body_state} <-
                 forward_pulled(pulled, upstream, ref, body_state, pull, updated, lease),
               do: {:ok, upstream, ref, body_state}
        else
          {:lease_closed, upstream, body_state}
        end

      {:error, reason} ->
        {:source_error, reason, upstream, body_state}

      :lease_closed ->
        {:lease_closed, upstream, body_state}
    end
  end

  defp connect_upstream(host, port, transport_opts, {_, token}) do
    owner = self()

    {worker, monitor} =
      spawn_monitor(fn ->
        result =
          case Mint.HTTP.connect(:https, host, port,
                 mode: :passive,
                 transport_opts: transport_opts,
                 protocols: [:http1]
               ) do
            {:ok, upstream} -> Mint.HTTP.controlling_process(upstream, owner)
            {:error, _reason} = error -> error
          end

        send(owner, {:upstream_connected, self(), result})
      end)

    receive do
      {:upstream_connected, ^worker, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:lease_closed, ^token} ->
        Process.exit(worker, :kill)

        receive do
          {:DOWN, ^monitor, :process, ^worker, _reason} -> :ok
        end

        receive do
          {:upstream_connected, ^worker, {:ok, upstream}} -> close(upstream)
          {:upstream_connected, ^worker, {:error, _reason}} -> :ok
        after
          0 -> :ok
        end

        {:error, :lease_closed}

      {:DOWN, ^monitor, :process, ^worker, _reason} ->
        {:error, :connection_failed}
    end
  end

  # @cc [owner:ghuntley,label:security] galileo-upload-backpressure
  # Galileo MUST pull no more than one source chunk before synchronously sending
  # it on the single authorized TLS request. Source truncation or destination
  # failure MUST close that request without retrying or sending request EOF.
  defp upload(upstream, ref, body_state, pull, body_updated, lease) do
    if lease_open?(lease),
      do: pull_upload(upstream, ref, body_state, pull, body_updated, lease),
      else: {:lease_closed, upstream, body_state}
  end

  defp pull_upload(upstream, ref, body_state, pull, body_updated, lease) do
    body_state
    |> interruptible_pull(pull, lease)
    |> forward_pulled(upstream, ref, body_state, pull, body_updated, lease)
  end

  defp forward_pulled(pulled, upstream, ref, body_state, pull, body_updated, lease) do
    case pulled do
      {:more, bytes, body_state} ->
        :ok = body_updated.(body_state)
        send_upload(upstream, ref, bytes, body_state, pull, body_updated, lease)

      {:ok, bytes, body_state} ->
        :ok = body_updated.(body_state)

        if lease_open?(lease) do
          with {:ok, upstream} <- Mint.HTTP.stream_request_body(upstream, ref, bytes),
               true <- lease_open?(lease),
               {:ok, upstream} <- Mint.HTTP.stream_request_body(upstream, ref, :eof),
               do: {:ok, upstream, body_state},
               else: (
                 false ->
                   {:lease_closed, upstream, body_state}

                 {:error, upstream, reason} ->
                   upload_error(reason, upstream, body_state, lease)
               )
        else
          {:lease_closed, upstream, body_state}
        end

      {:error, reason} ->
        {:source_error, reason, upstream, body_state}

      :lease_closed ->
        {:lease_closed, upstream, body_state}
    end
  end

  defp send_upload(upstream, ref, bytes, body_state, pull, body_updated, lease) do
    if lease_open?(lease) do
      case Mint.HTTP.stream_request_body(upstream, ref, bytes) do
        {:ok, upstream} -> upload(upstream, ref, body_state, pull, body_updated, lease)
        {:error, upstream, reason} -> upload_error(reason, upstream, body_state, lease)
      end
    else
      {:lease_closed, upstream, body_state}
    end
  end

  # @cc [owner:ghuntley,label:security;concurrency] upload-reader-lease-lifetime
  # Only one source reader MAY run at a time. Lease cancellation MUST terminate
  # a blocked reader and return control without forwarding its late bytes. The
  # reader MUST share abnormal caller lifetime and report only closed failures;
  # connection-state updates run in the request owner after successful reads.
  # An owner-bound source MUST supply frontend cancellation that interrupts its
  # blocked I/O when the guardian closes the lease.
  @spec interruptible_pull(body_state(), source(), lease()) ::
          pull_result() | :lease_closed
  defp interruptible_pull(body_state, {:owner, pull}, lease) do
    result =
      try do
        pull.(body_state)
      rescue
        _ -> {:error, :invalid_body}
      catch
        _, _ -> {:error, :invalid_body}
      end

    if lease_open?(lease), do: result, else: :lease_closed
  end

  defp interruptible_pull(body_state, pull, {_pid, token} = lease) do
    owner = self()
    call = make_ref()

    {reader, monitor} =
      :erlang.spawn_opt(
        fn ->
          result =
            try do
              pull.(body_state)
            rescue
              _ -> {:error, :invalid_body}
            catch
              _, _ -> {:error, :invalid_body}
            end

          send(owner, {:source_read, call, result})
        end,
        [:link, :monitor]
      )

    try do
      receive do
        {:source_read, ^call, result} ->
          if lease_open?(lease), do: result, else: :lease_closed

        {:lease_closed, ^token} ->
          :lease_closed

        {:DOWN, ^monitor, :process, ^reader, _reason} ->
          {:error, :invalid_body}
      end
    after
      Process.unlink(reader)
      cleanup_monitor = Process.monitor(reader)
      if Process.alive?(reader), do: Process.exit(reader, :kill)

      receive do
        {:DOWN, ^cleanup_monitor, :process, ^reader, _reason} -> :ok
      end

      Process.demonitor(monitor, [:flush])

      receive do
        {:source_read, ^call, _result} -> :ok
      after
        0 -> :ok
      end
    end
  end

  defp upload_error(reason, upstream, body_state, lease) do
    if lease_open?(lease),
      do: {:transport_error, reason, upstream, body_state},
      else: {:lease_closed, upstream, body_state}
  end

  defp receive_response(state, upstream, ref, consume, lease) do
    case Mint.HTTP.set_mode(upstream, :active) do
      {:ok, upstream} -> receive_response_message(state, upstream, ref, consume, lease)
      {:error, _reason} -> cancelled_if_closed(%{state | outcome: :transport_error}, lease)
    end
  end

  defp receive_response_message(state, upstream, ref, consume, {_, token} = lease) do
    socket = Mint.HTTP.get_socket(upstream)

    receive do
      {:ssl, ^socket, _data} = message ->
        stream_response(message, state, upstream, ref, consume, lease)

      {:ssl_closed, ^socket} = message ->
        stream_response(message, state, upstream, ref, consume, lease)

      {:ssl_error, ^socket, _reason} = message ->
        stream_response(message, state, upstream, ref, consume, lease)

      {:lease_closed, ^token} ->
        %{state | outcome: :cancelled}
    after
      @receive_poll_interval ->
        if lease_open?(lease),
          do: receive_response_message(state, upstream, ref, consume, lease),
          else: %{state | outcome: :cancelled}
    end
  end

  defp stream_response(message, state, upstream, ref, consume, lease) do
    case Mint.HTTP.stream(upstream, message) do
      {:ok, upstream, events} ->
        case events(events, state, ref, consume, lease) do
          {:cont, state} -> receive_response_message(state, upstream, ref, consume, lease)
          {:done, state} -> state
          {:halt, state} -> %{state | outcome: :cancelled}
        end

      {:error, upstream, _reason, _events} ->
        close(upstream)
        cancelled_if_closed(%{state | outcome: :transport_error}, lease)

      :unknown ->
        receive_response_message(state, upstream, ref, consume, lease)
    end
  end

  defp cancelled_if_closed(state, lease) do
    if lease_open?(lease), do: state, else: %{state | outcome: :cancelled}
  end

  # @cc [owner:ghuntley,label:security] galileo-authority-delay-consumes-lifetime
  # Supplied absolute admission deadlines and renewal-call start times MUST
  # bound the lease even if responses or process messages arrive late. Status
  # polling MUST NOT keep an expired lease open by delaying its timeout.
  defp start_lease(ttl, expires_at, renew, cancel_frontend) do
    owner = self()
    token = make_ref()

    pid =
      spawn(fn ->
        lease_loop(owner, Process.monitor(owner), token, renew, deadline(ttl, expires_at), %{
          connection: nil,
          cancel_frontend: cancel_frontend
        })
      end)

    {pid, token}
  end

  defp deadline(ttl, expires_at),
    do: %{renew_at: expires_at - div(ttl, 2), expires_at: expires_at}

  defp lease_loop(owner, owner_monitor, token, renew, deadline, upstream) do
    timeout = max(deadline.renew_at - System.monotonic_time(:millisecond), 0)

    receive do
      {:attach, ^token, value} ->
        lease_loop(owner, owner_monitor, token, renew, deadline, %{upstream | connection: value})

      {:status, ^token, caller, query} ->
        open? = System.monotonic_time(:millisecond) < deadline.expires_at
        send(caller, {:lease_status, query, open?})

        if open?,
          do: lease_loop(owner, owner_monitor, token, renew, deadline, upstream),
          else: close_lease(owner, owner_monitor, token, upstream)

      {:stop, ^token} ->
        :ok

      {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
        close(upstream)
    after
      timeout -> renew_lease(owner, owner_monitor, token, renew, deadline, upstream)
    end
  end

  defp renew_lease(owner, owner_monitor, token, renew, deadline, upstream) do
    parent = self()

    {worker, worker_monitor} =
      spawn_monitor(fn ->
        started = System.monotonic_time(:millisecond)

        result =
          try do
            renew.()
          rescue
            _ -> {:error, :authority_unavailable}
          catch
            _, _ -> {:error, :authority_unavailable}
          end

        send(parent, {:renewed, token, self(), result, started})
      end)

    await_renewal(
      owner,
      owner_monitor,
      token,
      renew,
      deadline,
      upstream,
      worker,
      worker_monitor
    )
  end

  defp await_renewal(
         owner,
         owner_monitor,
         token,
         renew,
         deadline,
         upstream,
         worker,
         worker_monitor
       ) do
    timeout = max(deadline.expires_at - System.monotonic_time(:millisecond), 0)

    receive do
      {:attach, ^token, value} ->
        await_renewal(
          owner,
          owner_monitor,
          token,
          renew,
          deadline,
          %{upstream | connection: value},
          worker,
          worker_monitor
        )

      {:status, ^token, caller, query} ->
        open? = System.monotonic_time(:millisecond) < deadline.expires_at
        send(caller, {:lease_status, query, open?})

        if open? do
          await_renewal(
            owner,
            owner_monitor,
            token,
            renew,
            deadline,
            upstream,
            worker,
            worker_monitor
          )
        else
          Process.exit(worker, :kill)
          close_lease(owner, owner_monitor, token, upstream)
        end

      {:renewed, ^token, ^worker, {:ok, %{ttl: ttl} = renewal}, started} ->
        Process.demonitor(worker_monitor, [:flush])

        expires_at =
          if valid_ttl?(ttl), do: Map.get(renewal, :expires_at, started + ttl), else: nil

        expires_at = if is_integer(expires_at), do: min(expires_at, started + ttl), else: nil

        now = System.monotonic_time(:millisecond)

        if valid_ttl?(ttl) and is_integer(expires_at) and now < deadline.expires_at and
             now < expires_at,
           do:
             lease_loop(owner, owner_monitor, token, renew, deadline(ttl, expires_at), upstream),
           else: close_lease(owner, owner_monitor, token, upstream)

      {:renewed, ^token, ^worker, _result, _started} ->
        Process.demonitor(worker_monitor, [:flush])
        close_lease(owner, owner_monitor, token, upstream)

      {:DOWN, ^worker_monitor, :process, ^worker, _reason} ->
        close_lease(owner, owner_monitor, token, upstream)

      {:stop, ^token} ->
        Process.exit(worker, :kill)

      {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
        Process.exit(worker, :kill)
        close(upstream)
    after
      timeout ->
        Process.exit(worker, :kill)
        close_lease(owner, owner_monitor, token, upstream)
    end
  end

  defp close_lease(owner, owner_monitor, token, upstream) do
    close(upstream)
    send(owner, {:lease_closed, token})
    upstream.cancel_frontend.()
    closed_lease_loop(owner, owner_monitor, token)
  end

  defp closed_lease_loop(owner, owner_monitor, token) do
    receive do
      {:attach, ^token, upstream} ->
        close(upstream)
        closed_lease_loop(owner, owner_monitor, token)

      {:status, ^token, caller, query} ->
        send(caller, {:lease_status, query, false})
        closed_lease_loop(owner, owner_monitor, token)

      {:stop, ^token} ->
        :ok

      {:DOWN, ^owner_monitor, :process, ^owner, _reason} ->
        :ok
    end
  end

  defp attach_lease({pid, token}, upstream), do: send(pid, {:attach, token, upstream})
  defp stop_lease({pid, token}), do: send(pid, {:stop, token})

  defp lease_open?({pid, token}) do
    query = make_ref()
    send(pid, {:status, token, self(), query})

    receive do
      {:lease_status, ^query, open?} -> open?
    after
      1000 -> false
    end
  end

  defp valid_ttl?(ttl), do: is_integer(ttl) and ttl in 500..5000

  defp events(events, state, ref, consume, lease) do
    if lease_open?(lease),
      do: handle_events(events, state, ref, consume, lease),
      else: {:halt, state}
  end

  defp handle_events([], state, _ref, _consume, _lease), do: {:cont, state}

  defp handle_events([{:status, ref, status} | rest], state, ref, consume, lease)
       when status in 100..199,
       do: events(rest, state, ref, consume, lease)

  defp handle_events([{:status, ref, status} | rest], state, ref, consume, lease)
       when status in 200..599,
       do: deliver(rest, {:status, status}, %{state | status: status}, ref, consume, lease)

  defp handle_events(
         [{:headers, ref, _headers} | rest],
         %{status: nil} = state,
         ref,
         consume,
         lease
       ),
       do: events(rest, state, ref, consume, lease)

  defp handle_events([{:headers, ref, headers} | rest], state, ref, consume, lease) do
    deliver(rest, {:headers, headers}, state, ref, consume, lease)
  end

  defp handle_events([{:data, ref, bytes} | rest], state, ref, consume, lease) do
    deliver(
      rest,
      {:data, bytes},
      %{state | response_bytes: state.response_bytes + byte_size(bytes)},
      ref,
      consume,
      lease
    )
  end

  defp handle_events([{:done, ref}], state, ref, _consume, _lease),
    do: {:done, %{state | outcome: :completed}}

  defp handle_events([_event | rest], state, ref, consume, lease),
    do: events(rest, state, ref, consume, lease)

  @spec default_response_headers([{binary(), binary()}]) :: [{binary(), binary()}]
  defp default_response_headers(headers),
    do: Enum.filter(headers, fn {name, _} -> name in ~w(content-type retry-after) end)

  defp deliver(rest, event, state, ref, consume, lease) do
    case consume.(event) do
      :ok -> events(rest, state, ref, consume, lease)
      :halt -> {:halt, state}
    end
  end

  defp close(nil), do: :ok
  defp close(%{connection: connection}), do: close(connection)

  defp close(upstream) do
    Mint.HTTP.close(upstream)
    :ok
  rescue
    _ -> :ok
  end
end
