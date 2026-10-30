defmodule Lilly.Host.PoolObserver do
  @moduledoc """
  Background pool observation, off the host report path (ADR-0140).

  One observer per configured pool reads its snapshot on its own single-flight
  `OverallsProtocol.Cadence` and publishes the latest result, stamped with the
  time the read began, to an `OverallsProtocol.View`. Capacity collection reads
  that view without waiting, so a slow pool read (the pool lock held for
  seconds) no longer delays every host report.
  """
  use Supervisor
  require Lilly.Events
  alias Lilly.Host.Pool
  alias OverallsProtocol.View

  @view Lilly.Host.PoolObserver.View

  @type read :: (Pool.t() -> OverallsProtocol.pool())
  @type observation :: %{observed_at: DateTime.t(), entry: OverallsProtocol.pool()}
  @type option ::
          {:view, View.view()}
          | {:read, read()}
          | {:interval_ms, pos_integer()}

  @doc "The read-model name used by default."
  @spec view() :: View.view()
  def view, do: @view

  @spec start_link({[Pool.t()], [option()]}) :: Supervisor.on_start()
  def start_link({pools, options}), do: Supervisor.start_link(__MODULE__, {pools, options})

  @impl true
  def init({pools, options}) do
    view = Keyword.get(options, :view, @view)

    children =
      [{View, name: view}, {Task.Supervisor, name: tasks(view)}] ++
        Enum.map(pools, fn pool ->
          Supervisor.child_spec({__MODULE__.Worker, {pool, Keyword.put(options, :view, view)}},
            id: {__MODULE__.Worker, pool.id}
          )
        end)

    # The view outlives worker restarts; a view restart starts them unproven.
    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc false
  @spec tasks(View.view()) :: atom()
  def tasks(view), do: Module.concat(view, Tasks)

  # @cc [owner:ghuntley,label:capacity;concurrency] pool-observer-report-never-waits
  # report/2 MUST NOT read the pool or wait for an observer. With an observer
  # view running it MUST return the latest published entry for the pool with
  # observed entries stamped observed_at, or a busy entry (no counters or credit)
  # when no observation has been published yet. When no observer view runs it
  # MUST report the pool busy, never read it inline, and emit
  # lilly.pool_observer_absent once per transition (lilly.pool_observer_present
  # on return), so a missing observer is visible and ages capacity out.
  @spec report(Pool.t(), View.view()) :: OverallsProtocol.pool()
  def report(pool, view \\ @view) do
    if Process.whereis(view) do
      presence(view, :present)

      case View.fetch(view, pool.id) do
        {:ok, {_version, %{observed_at: observed, entry: entry}}} -> stamp(entry, observed)
        :error -> %{id: pool.id, busy: true, storage: pool.storage}
      end
    else
      presence(view, :absent)
      %{id: pool.id, busy: true, storage: pool.storage}
    end
  end

  @spec presence(View.view(), :present | :absent) :: :ok
  defp presence(view, state) do
    key = {__MODULE__, :presence, view}

    cond do
      :persistent_term.get(key, :present) == state ->
        :ok

      state == :absent ->
        :persistent_term.put(key, state)
        Lilly.Events.emit("lilly.pool_observer_absent", [])

      true ->
        :persistent_term.put(key, state)
        Lilly.Events.emit("lilly.pool_observer_present", [])
    end
  end

  defp stamp(%{busy: true} = entry, _observed), do: entry
  defp stamp(%{unavailable: true} = entry, _observed), do: entry
  defp stamp(entry, observed), do: Map.put(entry, :observed_at, observed)

  defmodule Worker do
    @moduledoc false
    use GenServer
    require Lilly.Events
    alias Lilly.Host.PoolObserver
    alias OverallsProtocol.{Cadence, View}

    @typep state :: %{
             pool: Lilly.Host.Pool.t(),
             view: View.view(),
             read: PoolObserver.read(),
             interval: pos_integer(),
             cadence: Cadence.t(),
             task: {Task.t(), DateTime.t()} | nil
           }

    @spec start_link({Lilly.Host.Pool.t(), [PoolObserver.option()]}) :: GenServer.on_start()
    def start_link({pool, options}), do: GenServer.start_link(__MODULE__, {pool, options})

    @impl true
    def init({pool, options}) do
      view = Keyword.fetch!(options, :view)
      :ok = View.claim(view, pool.id)
      send(self(), :tick)

      {:ok,
       %{
         pool: pool,
         view: view,
         read: Keyword.get(options, :read, &Lilly.Host.Pool.report/1),
         interval: Keyword.get(options, :interval_ms, 1000),
         cadence: Cadence.new(),
         task: nil
       }}
    end

    # @cc [owner:ghuntley,label:capacity;concurrency] pool-observer-single-flight
    # Each pool MUST have at most one read in flight, and a tick during a read
    # MUST be dropped (Cadence), so reads rest between runs and never hold the
    # pool lock back to back. observed_at MUST be taken before the read starts,
    # so it never claims a later time than the data. A crashed read MUST leave
    # the previous observation published and MUST NOT stop later reads.
    @impl true
    def handle_info(:tick, state) do
      Process.send_after(self(), :tick, state.interval)
      {:noreply, step(state, :tick)}
    end

    def handle_info({ref, entry}, %{task: {%Task{ref: ref}, observed}} = state) do
      Process.demonitor(ref, [:flush])

      {:ok, _version} =
        View.put(state.view, state.pool.id, %{observed_at: observed, entry: entry})

      {:noreply, step(%{state | task: nil}, :done)}
    end

    def handle_info({:DOWN, ref, :process, _pid, _reason}, %{task: {%Task{ref: ref}, _}} = state) do
      Lilly.Events.emit("lilly.pool_observation_failed", pool_id: state.pool.id)
      {:noreply, step(%{state | task: nil}, :done)}
    end

    def handle_info(_message, state), do: {:noreply, state}

    @spec step(state(), Cadence.event()) :: state()
    defp step(state, event) do
      case Cadence.step(state.cadence, event) do
        {:ok, cadence, [:start]} ->
          observed = DateTime.utc_now()
          read = state.read
          pool = state.pool

          task =
            Task.Supervisor.async_nolink(PoolObserver.tasks(state.view), fn -> read.(pool) end)

          %{state | cadence: cadence, task: {task, observed}}

        {:ok, cadence, []} ->
          %{state | cadence: cadence}

        {:error, :invalid_transition} ->
          state
      end
    end
  end
end
