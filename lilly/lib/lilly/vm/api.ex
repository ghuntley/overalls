defmodule Lilly.VM.API do
  @moduledoc "Bounded private Unix-socket Firecracker requests. Responses never enter logs."
  @limit 16_384
  @type state :: :running | :paused | :unconfigured

  @spec state(Path.t(), String.t()) :: {:ok, state()} | {:error, :vmm_api_unavailable}
  def state(path, id) do
    with {:ok, 200, body} <- request(path, "GET", "/", ""),
         {:ok, %{"id" => ^id, "state" => state, "vmm_version" => "1.16.1"}} <- JSON.decode(body),
         {_, decoded} <-
           Enum.find(
             [{"Running", :running}, {"Paused", :paused}, {"Not started", :unconfigured}],
             fn {wire, _} -> wire == state end
           ) do
      {:ok, decoded}
    else
      _ -> {:error, :vmm_api_unavailable}
    end
  end

  # @cc [owner:ghuntley,label:protocol] vmm-readiness-matches-id-version
  # API.running?/2 MUST require HTTP 200 with the requested VM ID, Running state and supported
  # Firecracker 1.16.1 version. Oversized, ambiguous, truncated or invalid replies must not
  # establish readiness.
  @spec running?(Path.t(), String.t()) :: boolean()
  def running?(path, id) do
    state(path, id) == {:ok, :running}
  end

  # @cc [owner:ghuntley,label:recovery] vmm-pause-is-not-compute-release
  # pause/1 MUST freeze vCPUs without guest shutdown. Acceptance alone MUST NOT
  # authorize compute release; a durable checkpoint and empty cgroup are required.
  @spec pause(Path.t()) :: :ok | {:error, :vmm_api_unavailable}
  def pause(path), do: change_state(path, "Paused")

  @spec resume(Path.t()) :: :ok | {:error, :vmm_api_unavailable}
  def resume(path), do: change_state(path, "Resumed")

  @spec create_checkpoint(Path.t(), :a | :b) :: :ok | {:error, :vmm_api_unavailable}
  def create_checkpoint(path, slot) when slot in [:a, :b] do
    root = "/checkpoint-" <> Atom.to_string(slot)

    accepted(
      path,
      "PUT",
      "/snapshot/create",
      %{
        "snapshot_type" => "Full",
        "snapshot_path" => root <> "/state",
        "mem_file_path" => root <> "/memory"
      },
      300_000
    )
  end

  # @cc [owner:ghuntley,label:security;recovery] checkpoint-load-never-cold-boots
  # load_checkpoint/3 MUST target only fixed jail-local immutable files, load into
  # a fresh API-only VMM with resume_vm false, and override only the validated
  # destination TAP/vsock paths. Failure MUST NOT fall back to InstanceStart.
  # The File backend is only safe with the pinned VMM's anonymous-restore patch
  # (contract snapshot-restore-anonymous-memory, ADR-0266): restored RAM is a copy,
  # so it is charged to the VM cgroup like cold-boot RAM and a later checkpoint
  # cannot fault /restore.memory page cache into the VM's MemoryMax.
  @spec load_checkpoint(Path.t(), Lilly.Network.Guest.t(), boolean()) ::
          :ok | {:error, :vmm_api_unavailable}
  def load_checkpoint(path, network, vsock?) do
    body = %{
      "snapshot_path" => "/restore.state",
      "mem_backend" => %{"backend_type" => "File", "backend_path" => "/restore.memory"},
      "enable_diff_snapshots" => false,
      "resume_vm" => false,
      "network_overrides" => [%{"iface_id" => "eth0", "host_dev_name" => network.tap}]
    }

    body = if vsock?, do: Map.put(body, "vsock_override", %{"uds_path" => "/v.sock"}), else: body
    accepted(path, "PUT", "/snapshot/load", body, 300_000)
  end

  defp change_state(path, state), do: accepted(path, "PATCH", "/vm", %{"state" => state}, 2000)

  defp accepted(path, method, route, body, timeout) do
    case request(path, method, route, JSON.encode!(body), timeout) do
      {:ok, 204, _} -> :ok
      _ -> {:error, :vmm_api_unavailable}
    end
  end

  # @cc [owner:ghuntley,label:assumption;recovery] shutdown-response-is-not-stop-proof
  # shutdown/1 reports only acceptance of SendCtrlAltDel (HTTP 204). Its caller MUST still prove
  # the unit/cgroup stopped before treating compute as empty or removing resources.
  @spec shutdown(Path.t()) :: :ok | {:error, :vmm_api_unavailable}
  def shutdown(path) do
    case request(path, "PUT", "/actions", ~s({"action_type":"SendCtrlAltDel"})) do
      {:ok, 204, _} -> :ok
      _ -> {:error, :vmm_api_unavailable}
    end
  end

  defp request(path, method, route, body, timeout \\ 2000) do
    with {:ok, socket} <-
           Lilly.Host.Sockets.connect_local(
             path,
             [:binary, active: false, packet: :raw, send_timeout: 1000, send_timeout_close: true],
             1000
           ) do
      try do
        with :ok <-
               :gen_tcp.send(socket, [
                 method,
                 " ",
                 route,
                 " HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: ",
                 Integer.to_string(byte_size(body)),
                 "\r\nConnection: close\r\n\r\n",
                 body
               ]),
             do: receive_response(socket, "", System.monotonic_time(:millisecond) + timeout)
      after
        :gen_tcp.close(socket)
      end
    end
  end

  defp receive_response(socket, bytes, deadline) do
    case parse(bytes) do
      :more ->
        with remaining when remaining > 0 <- deadline - System.monotonic_time(:millisecond),
             {:ok, chunk} <- :gen_tcp.recv(socket, 0, remaining),
             true <- byte_size(bytes) + byte_size(chunk) <= @limit,
             do: receive_response(socket, bytes <> chunk, deadline),
             else: (_ -> :error)

      result ->
        result
    end
  end

  defp parse(bytes) do
    case :binary.split(bytes, "\r\n\r\n") do
      [_] ->
        :more

      [head, body] ->
        with [status | lines] <- String.split(head, "\r\n"),
             [_, code, _] <- String.split(status, " ", parts: 3),
             {code, ""} <- Integer.parse(code),
             lengths =
               for(
                 line <- lines,
                 String.starts_with?(String.downcase(line), "content-length:"),
                 do: line |> String.split(":", parts: 2) |> List.last() |> String.trim()
               ),
             {:ok, length} <- content_length(code, lengths),
             true <- length in 0..@limit do
          cond do
            byte_size(body) < length -> :more
            byte_size(body) == length -> {:ok, code, body}
            true -> :error
          end
        else
          _ -> :error
        end
    end
  end

  defp content_length(204, []), do: {:ok, 0}

  defp content_length(_code, [value]) do
    case Integer.parse(value) do
      {length, ""} -> {:ok, length}
      _ -> :error
    end
  end

  defp content_length(_, _), do: :error
end
