defmodule Ziggy.HTTP do
  @moduledoc "Audi-only Unix-socket frontend for native inference."
  @behaviour Plug
  import Plug.Conn
  require Ziggy.Events

  # Largest `artifact_chunk` request body; every other agent route keeps 12_288.
  @artifact_chunk_limit 270_336

  @impl true
  def init(opts), do: opts

  @impl true
  @spec call(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def call(conn, config) do
    Overalls.Diagnostics.Tracing.with_span("ziggy.http", [], fn -> call_traced(conn, config) end)
  end

  # @cc [owner:ghuntley,label:security] ziggy-private-frontend-only
  # This Plug MUST only be mounted on the private Audi Unix socket. Audi MUST
  # replace binding headers using Lilly's pre-NAT execution lookup. Ziggy MUST
  # revalidate that exact binding with Marshall before any provider side effect.
  # An admission timeout or duplicate request MUST NOT trigger inference retry.
  defp call_traced(
         %{method: "GET", request_path: "/health/ready", query_string: ""} = conn,
         config
       ) do
    ready =
      with true <- Ziggy.Spool.ready?(Ziggy.Spool),
           true <- Ziggy.Catalog.ready?(Ziggy.Catalog),
           {:ok, %{"host_id" => host}} <- Ziggy.Control.request(config.control, "identity", %{}),
           do: host == config.host_id,
           else: (_ -> false)

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(
      if(ready, do: 200, else: 503),
      Jason.encode!(%{version: 1, ready: ready, role: "ziggy", host_id: config.host_id})
    )
  end

  # @cc [owner:ghuntley,label:security] ziggy-monitor-numeric-projection
  # The host-only Unix socket MUST expose only bounded numeric operational
  # measurements, never request identities, content, credentials or raw errors.
  defp call_traced(%{method: "GET", request_path: "/metrics", query_string: ""} = conn, config) do
    gauges =
      Ziggy.Spool.metrics(Ziggy.Spool)
      |> Map.put("ziggy_models_openai", length(Ziggy.Catalog.models(Ziggy.Catalog, :openai)))
      |> Map.put(
        "ziggy_models_anthropic",
        length(Ziggy.Catalog.models(Ziggy.Catalog, :anthropic))
      )
      |> Map.put("ziggy_catalog_ready", if(Ziggy.Catalog.ready?(Ziggy.Catalog), do: 1, else: 0))

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(%{version: 1, host_id: config.host_id, gauges: gauges}))
  end

  defp call_traced(conn, config) do
    with true <- conn.host in ["llm.internal", "ssh.integration.internal"],
         [encoded] when byte_size(encoded) <= 2048 <- get_req_header(conn, "x-overalls-binding"),
         {:ok, json} <- Base.url_decode64(encoded, padding: false),
         {:ok, wire} <- Jason.decode(json),
         {:ok, %{host_id: host}} <- request_binding(conn, wire),
         true <- host == config.host_id do
      if conn.host == "ssh.integration.internal",
        do: ssh_dispatch(conn, config, wire),
        else: dispatch(conn, config, wire)
    else
      _ -> error(conn, 403, "unauthorized")
    end
  rescue
    _ -> error(Process.get({__MODULE__, :conn}) || conn, 503, "unavailable")
  after
    Process.delete({__MODULE__, :conn})
  end

  # @cc [owner:ghuntley,label:security] roster-bootstrap-relay-scope
  # The six-field boot binding MUST be accepted only for, and is the only binding
  # accepted by, the exact roster GET or host-certificate POST. All other routes
  # retain the strict ordinary binding decoder.
  defp request_binding(
         %{
           host: "ssh.integration.internal",
           method: "GET",
           request_path: "/ssh/v1/roster",
           query_string: ""
         },
         wire
       ),
       do: OverallsProtocol.PrivateServices.roster_binding(wire)

  defp request_binding(
         %{
           host: "ssh.integration.internal",
           method: "POST",
           request_path: "/ssh/v1/host-certificate",
           query_string: ""
         },
         wire
       ),
       do: OverallsProtocol.PrivateServices.roster_binding(wire)

  defp request_binding(_, wire), do: OverallsProtocol.PrivateServices.binding(wire)

  # @cc [owner:ghuntley,label:security] ssh-private-bound-relay
  # SSH requests use only Audi's physical binding, never a guest-supplied one.
  # This route is distinct from inference and exposes no provider operation.
  defp ssh_dispatch(
         %{method: "POST", request_path: "/ssh/v1/host-certificate", query_string: ""} = conn,
         config,
         wire
       ) do
    with [content_type] <- get_req_header(conn, "content-type"),
         {:ok, "application", "json", _} <- Plug.Conn.Utils.content_type(content_type),
         {:ok, body, conn} <- read_body(conn, length: 8192, read_length: 8192),
         {:ok, %{"public_key" => key} = input} <- Jason.decode(body),
         true <- map_size(input) == 1 and is_binary(key) do
      ssh_result(
        conn,
        Ziggy.Control.request(config.control, "ssh_host_certificate", %{
          "binding" => wire,
          "public_key" => key
        })
      )
    else
      _ -> error(conn, 400, "invalid_request")
    end
  end

  defp ssh_dispatch(
         %{method: "GET", request_path: "/ssh/v1/roster", query_string: ""} = conn,
         config,
         wire
       ) do
    ssh_result(conn, Ziggy.Control.request(config.control, "ssh_roster", %{"binding" => wire}))
  end

  # Guests whose sshd cannot ask per connection (Windows, ADR-0171) pull the
  # current writers' registered keys under the ordinary binding.
  defp ssh_dispatch(
         %{method: "GET", request_path: "/ssh/v1/authorized-keys", query_string: ""} = conn,
         config,
         wire
       ) do
    ssh_result(
      conn,
      Ziggy.Control.request(config.control, "ssh_authorized_keys", %{"binding" => wire})
    )
  end

  defp ssh_dispatch(
         %{method: "POST", request_path: "/ssh/v1/" <> route, query_string: ""} = conn,
         config,
         wire
       )
       when route in ["authorize", "login"] do
    with [content_type] <- get_req_header(conn, "content-type"),
         {:ok, "application", "json", _} <- Plug.Conn.Utils.content_type(content_type),
         {:ok, body, conn} <- read_body(conn, length: 8192, read_length: 8192),
         true <- byte_size(body) <= 8192,
         {:ok, %{"username" => username, "public_key" => key} = input} <- Jason.decode(body),
         true <- map_size(input) == 2 and is_binary(username) and is_binary(key) do
      ssh_result(
        conn,
        Ziggy.Control.request(config.control, "ssh_" <> route, %{
          "binding" => wire,
          "username" => username,
          "public_key" => key
        })
      )
    else
      _ -> error(conn, 400, "invalid_request")
    end
  end

  defp ssh_dispatch(conn, _, _), do: error(conn, 404, "unavailable")

  defp ssh_result(conn, {:ok, result}) do
    conn
    |> put_resp_header("cache-control", "no-store")
    |> put_resp_content_type("application/json")
    |> send_resp(200, Jason.encode!(result))
  end

  defp ssh_result(conn, {:error, :unauthorized}), do: error(conn, 403, "unauthorized")
  defp ssh_result(conn, _), do: error(conn, 503, "unavailable")

  # @cc [owner:ghuntley,label:security] ziggy-bootstrap-current-attempt
  # Executor bootstrap bytes MUST require the exact current VM executor, fence,
  # bootstrap attempt and startup-verified digest/size. Query parameters MUST
  # carry only these three nonsecret selectors; no caller-selected file path.
  defp dispatch(
         %{method: "GET", request_path: "/agent/v1/bootstrap/artifacts/" <> digest} = conn,
         config,
         wire
       ) do
    with true <- OverallsProtocol.GitHubTools.digest?(digest),
         {:ok, input} <- attempt_query(conn.query_string, "bootstrap_id"),
         %{artifacts: artifacts} <- Map.get(config, :bootstrap_release),
         %{path: path, digest: ^digest, size: size} <- Map.get(artifacts, digest),
         {:ok, %{"sha256" => ^digest, "bytes" => ^size}} <-
           Ziggy.Control.request(
             config.control,
             "agent_bootstrap_artifact",
             input |> Map.put("digest", digest) |> Map.put("binding", wire)
           ) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_content_type("application/octet-stream")
      |> send_file(200, path)
    else
      _ -> error(conn, 503, "unavailable")
    end
  end

  # @cc [owner:ghuntley,label:security] ziggy-maintenance-artifact-bound-attempt
  # A digest selector MUST be authorized against this VM's current executor,
  # fence and maintenance attempt. Marshall's digest, size and generation MUST
  # match the startup-verified local release before any bytes are sent. Query
  # parameters MUST be exactly the nonsecret three-field attempt binding.
  defp dispatch(
         %{method: "GET", request_path: "/agent/v1/maintenance/artifacts/" <> digest} = conn,
         config,
         wire
       ) do
    with true <- OverallsProtocol.GitHubTools.digest?(digest),
         {:ok, input} <- attempt_query(conn.query_string, "maintenance_id"),
         %{generation: generation, artifacts: artifacts} <- Map.get(config, :github_tools),
         %{path: path, digest: ^digest, size: size} <- Map.get(artifacts, digest),
         {:ok, %{"sha256" => ^digest, "bytes" => ^size, "generation" => ^generation}} <-
           Ziggy.Control.request(
             config.control,
             "agent_maintenance_artifact",
             input |> Map.put("digest", digest) |> Map.put("binding", wire)
           ) do
      conn
      |> put_resp_header("cache-control", "no-store")
      |> put_resp_content_type("application/octet-stream")
      |> send_file(200, path)
    else
      _ -> error(conn, 503, "unavailable")
    end
  end

  defp dispatch(%{method: "GET", request_path: path, query_string: ""} = conn, config, wire)
       when path in ["/agent/v1/update/manifest.json", "/agent/v1/update/bin/linux-amd64"] do
    case update_artifact(config, wire) do
      {:ok, path_to_binary, digest, size} ->
        conn = put_resp_header(conn, "cache-control", "no-store")

        case path do
          "/agent/v1/update/manifest.json" ->
            manifest = %{
              version: "0.1.0",
              artifacts: %{
                "linux-amd64" => %{
                  path: "/agent/v1/update/bin/linux-amd64",
                  sha256: digest,
                  bytes: size
                }
              }
            }

            conn
            |> put_resp_content_type("application/json")
            |> send_resp(200, Jason.encode!(manifest))

          _ ->
            conn
            |> put_resp_content_type("application/octet-stream")
            |> send_file(200, path_to_binary)
        end

      {:error, :unauthorized} ->
        error(conn, 403, "unauthorized")

      _ ->
        error(conn, 503, "unavailable")
    end
  end

  defp dispatch(%{method: "GET", request_path: path, query_string: ""} = conn, config, wire)
       when path in ["/v1/models", "/openai/v1/models", "/anthropic/v1/models"] do
    case Ziggy.Control.request(config.control, "authorize", wire) do
      {:ok, %{"authorized" => true}} ->
        provider =
          case path do
            "/openai/v1/models" -> :openai
            "/anthropic/v1/models" -> :anthropic
            _ -> :all
          end

        conn
        |> put_resp_content_type("application/json")
        |> send_resp(
          200,
          Jason.encode!(%{object: "list", data: Ziggy.Catalog.models(Ziggy.Catalog, provider)})
        )

      _ ->
        error(conn, 403, "unauthorized")
    end
  end

  # @cc [owner:ghuntley,label:security] ziggy-agent-binding-relay
  # Guest executor calls MUST use the binding that Audi attached from the
  # pre-NAT peer. Guest-supplied binding fields are rejected before Marshall
  # receives the RPC. Ziggy does not inspect or log tool arguments or results.
  # Only attachment transfers (at most 352 KiB) and artifact chunks (at most
  # 264 KiB, below) MAY exceed 12 KiB.
  defp dispatch(
         %{method: "POST", request_path: "/agent/v1/" <> route, query_string: ""} = conn,
         config,
         wire
       )
       when route in ~w(register heartbeat claim transition maintenance/claim maintenance/transition attachment/transfer) do
    agent_rpc(
      conn,
      config,
      wire,
      route,
      if(route == "attachment/transfer", do: 360_448, else: 12_288)
    )
  end

  # @cc [owner:ghuntley,label:security] ziggy-artifact-chunk-relay
  # `artifact_chunk` MAY carry up to 270_336 bytes (one base64 196_608-byte chunk
  # plus identity fields). It keeps the same Audi binding injection and
  # guest-binding refusal, goes only to control route `agent_artifact_chunk`,
  # and its body is never inspected beyond the JSON object shape or logged.
  defp dispatch(
         %{method: "POST", request_path: "/agent/v1/artifact_chunk", query_string: ""} = conn,
         config,
         wire
       ) do
    agent_rpc(conn, config, wire, "artifact_chunk", @artifact_chunk_limit)
  end

  defp dispatch(conn, config, wire) do
    with [content_type] <- get_req_header(conn, "content-type"),
         {:ok, "application", "json", _} <- Plug.Conn.Utils.content_type(content_type),
         {:ok, body, conn} <-
           read_body(conn, length: 16_777_216, read_length: 65_536, read_timeout: 10_000),
         {:ok, route} <-
           Ziggy.Route.resolve(conn.method, conn.request_path, conn.query_string, body) do
      # @cc [owner:ghuntley,label:security] disabled-provider-no-effects
      # Disabled providers MUST be rejected before admission, spool writes or
      # upstream calls, even when a caller supplies an otherwise valid binding.
      if Map.has_key?(config.credentials, route.provider),
        do: infer(conn, config, wire, route),
        else: error(conn, 503, "provider_unavailable")
    else
      {:more, _, conn} -> error(conn, 413, "request_too_large")
      _ -> error(conn, 400, "invalid_request")
    end
  end

  @spec agent_rpc(Plug.Conn.t(), map(), map(), String.t(), pos_integer()) :: Plug.Conn.t()
  defp agent_rpc(conn, config, wire, route, limit) do
    with [content_type] <- get_req_header(conn, "content-type"),
         {:ok, "application", "json", _} <- Plug.Conn.Utils.content_type(content_type),
         {:ok, body, conn} <- read_body(conn, length: limit, read_length: limit),
         true <- byte_size(body) <= limit,
         {:ok, input} when is_map(input) <- Jason.decode(body),
         false <- Map.has_key?(input, "binding"),
         {:ok, result} <-
           Ziggy.Control.request(
             config.control,
             "agent_" <> String.replace(route, "/", "_"),
             Map.put(input, "binding", wire)
           ) do
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(200, Jason.encode!(result))
    else
      {:more, _, conn} -> error(conn, 413, "request_too_large")
      {:error, :authority_unavailable} -> error(conn, 503, "authority_unavailable")
      {:error, :unsupported_version} -> error(conn, 503, "authority_unavailable")
      _ -> error(conn, 400, "invalid_request")
    end
  end

  @spec attempt_query(String.t(), String.t()) :: {:ok, map()} | {:error, :invalid_request}
  defp attempt_query(query, attempt_key) when byte_size(query) in 1..2048 do
    pairs = Enum.to_list(URI.query_decoder(query))
    input = Map.new(pairs)

    with true <- length(pairs) == 3 and map_size(input) == 3,
         true <-
           Enum.sort(Map.keys(input)) == Enum.sort(["executor_id", "fence_epoch", attempt_key]),
         true <-
           OverallsProtocol.uuid?(input["executor_id"]) and
             OverallsProtocol.uuid?(input[attempt_key]),
         {fence, ""} when fence in 1..9_223_372_036_854_775_807 <-
           Integer.parse(input["fence_epoch"]),
         true <- Integer.to_string(fence) == input["fence_epoch"] do
      {:ok, Map.put(input, "fence_epoch", fence)}
    else
      _ -> {:error, :invalid_request}
    end
  rescue
    _ -> {:error, :invalid_request}
  end

  defp attempt_query(_, _), do: {:error, :invalid_request}

  # @cc [owner:ghuntley,label:security] ziggy-update-artifact-binding
  # Private artifact delivery MUST require current Marshall VM authority and
  # exact local release bytes, digest and size. A guest MUST NOT select a path
  # or source; an authority or package mismatch MUST fail closed.
  defp update_artifact(
         %{update_artifact: %{path: _, digest: _, size: _} = artifact, control: control},
         wire
       ) do
    artifact_decision(Ziggy.Control.request(control, "update_authorize", wire), artifact)
  end

  defp update_artifact(_, _), do: {:error, :unavailable}

  # @cc [owner:ghuntley,label:security] ziggy-update-artifact-decision
  # The packaged artifact is servable only when Marshall's decision carries the
  # exact packaged digest and size. An authority refusal MUST remain the only
  # guest-distinguishable denial (:unauthorized → 403); an authorized decision
  # that disagrees with the packaged digest or size, a malformed decision, and
  # an unavailable authority MUST all deny with :unavailable (→ 503) and MUST
  # NOT reveal the packaged path, digest or size.
  @spec artifact_decision(term(), %{path: binary(), digest: binary(), size: pos_integer()}) ::
          {:ok, binary(), binary(), pos_integer()} | {:error, :unauthorized | :unavailable}
  def artifact_decision(
        {:ok, %{"sha256" => desired, "bytes" => desired_size}},
        %{path: path, digest: digest, size: size}
      )
      when is_binary(desired) and is_integer(desired_size) do
    if desired == digest and desired_size == size,
      do: {:ok, path, digest, size},
      else: {:error, :unavailable}
  end

  def artifact_decision({:error, :unauthorized}, _), do: {:error, :unauthorized}
  def artifact_decision(_, _), do: {:error, :unavailable}

  defp infer(conn, config, wire, route) do
    id = uuid()

    input =
      Map.merge(wire, %{
        "request_id" => id,
        "provider" => Atom.to_string(route.provider),
        "model" => route.model,
        "operation" => operation(route.path)
      })

    started = System.monotonic_time(:millisecond)

    case admission(config, input, id, started) do
      {:ok, lease} ->
        Ziggy.Events.emit("ziggy.inference_admitted",
          request_id: id,
          host_id: Map.get(wire, "host_id"),
          vm_id: Map.get(wire, "vm_id")
        )

        Process.put({__MODULE__, :conn}, put_resp_header(conn, "x-ziggy-request-id", id))

        result =
          Ziggy.Upstream.stream(
            route,
            Map.fetch!(config.credentials, route.provider),
            conn.req_headers,
            &consume/1,
            finch: Ziggy.Finch,
            request_id: id,
            openai_origin: Map.get(config, :openai_origin, Ziggy.Route.origin(:openai))
          )

        Ziggy.Lease.stop(lease)

        completion = %{
          "provider_request_id" => result.provider_request_id,
          "http_status" => result.status,
          "cost_estimate" => Ziggy.Pricing.estimate(route.provider, route.model, result.usage),
          "outcome" => Atom.to_string(result.outcome),
          "tokens" => result.usage.tokens,
          "completeness" => result.usage.completeness,
          "duration_ms" => System.monotonic_time(:millisecond) - started,
          "request_bytes" => byte_size(route.body),
          "response_bytes" => result.response_bytes
        }

        Ziggy.Spool.complete(Ziggy.Spool, id, completion)
        final = Process.get({__MODULE__, :conn})

        Ziggy.Events.emit("ziggy.inference_completed",
          request_id: id,
          host_id: Map.get(wire, "host_id"),
          vm_id: Map.get(wire, "vm_id"),
          reason: result.outcome,
          status: result.status,
          duration_ms: completion["duration_ms"],
          request_bytes: completion["request_bytes"],
          response_bytes: completion["response_bytes"]
        )

        if final.state in [:chunked, :sent],
          do: final,
          else: error(final, 502, "upstream_unavailable")

      {:error, reason} ->
        Ziggy.Spool.complete(Ziggy.Spool, id, %{
          "outcome" => "interrupted",
          "tokens" => %{},
          "completeness" => "unknown",
          "duration_ms" => System.monotonic_time(:millisecond) - started,
          "request_bytes" => byte_size(route.body),
          "response_bytes" => 0
        })

        Ziggy.Events.emit("ziggy.inference_interrupted",
          request_id: id,
          host_id: Map.get(wire, "host_id"),
          vm_id: Map.get(wire, "vm_id"),
          reason: reason
        )

        error(conn, 503, "admission_unavailable")
    end
  end

  defp admission(config, input, id, started) do
    with {:ok, %{"owner_id" => owner, "admitted_at" => admitted_at}} <-
           admitted(config, input, id),
         event = Map.merge(input, %{"owner_id" => owner, "admitted_at" => admitted_at}),
         :ok <- Ziggy.Spool.admit(Ziggy.Spool, event),
         remaining when remaining > 10_000 <-
           30_000 - (System.monotonic_time(:millisecond) - started),
         {:ok, lease} <- start_lease(config, id, remaining) do
      {:ok, lease}
    else
      remaining when is_integer(remaining) ->
        {:error, :ttl_exhausted}

      {:error, reason} when is_atom(reason) ->
        {:error, reason}

      _ ->
        {:error, :admission_rejected}
    end
  end

  defp admitted(config, input, id) do
    case Ziggy.Control.request(config.control, "admit", input) do
      {:ok,
       %{
         "request_id" => ^id,
         "owner_id" => owner,
         "admitted_at" => admitted_at,
         "ttl_ms" => 30_000
       }} ->
        {:ok, %{"owner_id" => owner, "admitted_at" => admitted_at}}

      {:ok, _} ->
        {:error, :admission_rejected}

      {:error, reason} when is_atom(reason) ->
        {:error, reason}
    end
  end

  defp start_lease(config, id, remaining) do
    DynamicSupervisor.start_child(
      Ziggy.Leases,
      {Ziggy.Lease,
       owner: self(),
       tasks: Ziggy.Tasks,
       ttl_ms: remaining,
       renewal_ms: 10_000,
       request_id: id,
       renew: fn ->
         case Ziggy.Control.request(config.control, "renew", %{"request_id" => id}) do
           {:ok, %{"request_id" => ^id, "ttl_ms" => 30_000}} -> :ok
           _ -> :error
         end
       end}
    )
  end

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

  defp operation("/v1/responses"), do: "responses"
  defp operation("/v1/chat/completions"), do: "chat"
  defp operation("/v1/messages"), do: "messages"
  defp operation("/v1/messages/count_tokens"), do: "count_tokens"

  defp uuid do
    <<a::32, b::16, _::4, c::12, _::2, d::14, e::48>> = :crypto.strong_rand_bytes(16)

    Enum.map_join(
      [{a, 8}, {b, 4}, {Bitwise.bor(c, 0x4000), 4}, {Bitwise.bor(d, 0x8000), 4}, {e, 12}],
      "-",
      fn {v, n} -> Integer.to_string(v, 16) |> String.downcase() |> String.pad_leading(n, "0") end
    )
  end
end
