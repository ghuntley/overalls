defmodule Brady.Cache.Recovery do
  @moduledoc "Rate-limited cache recovery, outside the proxy's availability boundary."
  use GenServer
  require Brady.Events

  # Native proofs expire three seconds after their sample began (ADR-0069). The
  # sampler starts one per second; re-reading twice a second keeps the store's
  # copy within half a second of the newest publication instead of a full one.
  @check_interval_ms 500

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    send(self(), :retry)

    {:ok,
     %{
       workers: Keyword.fetch!(opts, :workers),
       store: Keyword.fetch!(opts, :store),
       ready: Keyword.get(opts, :ready, fn -> {:ok, :fixture, nil} end),
       ref: nil,
       pid: nil,
       binding: nil,
       pressure_stale: false
     }}
  end

  # @cc [owner:ghuntley,label:recovery] brady-cache-start-failure-isolated
  # Store initialization/crash failures MUST remain inside the optional cache
  # subtree. Retry at most once per five seconds. Production readiness MUST prove
  # fresh native mount custody; lost or changed custody MUST stop the cache before
  # further housekeeping, without stopping proxy listeners.
  @impl true
  def handle_info(:retry, %{ref: nil} = state) do
    spec = Supervisor.child_spec({Brady.Cache.Store, state.store}, restart: :temporary)

    with {:ok, binding, _pressure} <- state.ready.(),
         {:ok, pid} <- DynamicSupervisor.start_child(state.workers, spec) do
      Brady.Events.emit("brady.cache_store_started", [])
      # Revalidate after potentially slow disk recovery before enabling writes.
      send(self(), :check)
      {:noreply, %{state | ref: Process.monitor(pid), pid: pid, binding: binding}}
    else
      _ ->
        Brady.Events.emit("brady.cache_store_lost", reason: :unavailable)
        Process.send_after(self(), :retry, 5_000)
        {:noreply, state}
    end
  end

  def handle_info(:check, %{pid: pid, binding: binding} = state) when is_pid(pid) do
    case state.ready.() do
      {:ok, ^binding, pressure} ->
        observe(pid, pressure)
        if state.pressure_stale, do: Brady.Events.emit("brady.cache_pressure_resumed", [])
        Process.send_after(self(), :check, @check_interval_ms)
        {:noreply, %{state | pressure_stale: false}}

      {:stale, ^binding} ->
        pause(pid)

        if not state.pressure_stale,
          do: Brady.Events.emit("brady.cache_pressure_paused", reason: :stale)

        Process.send_after(self(), :check, @check_interval_ms)
        {:noreply, %{state | pressure_stale: true}}

      _ ->
        Brady.Events.emit("brady.cache_custody_lost", [])
        DynamicSupervisor.terminate_child(state.workers, pid)
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{ref: ref} = state) do
    Brady.Events.emit("brady.cache_store_lost", reason: store_loss(reason))
    Process.send_after(self(), :retry, 5_000)
    {:noreply, %{state | ref: nil, pid: nil, binding: nil, pressure_stale: false}}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def format_status(status),
    do: Map.new(status, fn {key, _} -> {key, if(key == :log, do: [], else: :redacted)} end)

  defp store_loss(:normal), do: :normal
  defp store_loss(:shutdown), do: :shutdown
  defp store_loss(:killed), do: :killed
  defp store_loss(_), do: :crashed

  @spec pause(pid()) :: :ok
  defp pause(pid) do
    Brady.Cache.Store.pause_writes(pid)
  catch
    :exit, _ -> :ok
  end

  defp observe(_, nil), do: :ok

  defp observe(pid, pressure) do
    Brady.Cache.Store.observe_native(pid, pressure)
  catch
    :exit, _ -> :ok
  end
end
