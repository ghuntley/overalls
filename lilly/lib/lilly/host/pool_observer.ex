defmodule Lilly.Host.PoolObserver do
  @moduledoc """
  Background pool observation, off the host report path (ADR-0140).

  One observer per configured pool reads its snapshot on its own single-flight
  `OverallsProtocol.Cadence`, resting after each read in proportion to how
  long it held the pool lock, and publishes the latest result, stamped with the
  time the read began, to an `OverallsProtocol.View`. Capacity collection reads
  that view without waiting, so a slow pool read (the pool lock held for
  seconds) no longer delays every host report.
  """
  use Supervisor
  require Lilly.Events
  alias Lilly.Host.Pool
  alias OverallsProtocol.View

  @view Lilly.Host.PoolObserver.View
  # Two observation cadences: a healthy boot's observer starts well within it.
  @absent_grace_ms 2000

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
  # report/3 MUST NOT read the pool or wait for an observer. With an observer
  # view running it MUST return the latest published entry for the pool with
  # observed entries stamped observed_at, or a busy entry (no counters or credit)
  # when no observation has been published yet. When no observer view runs it
  # MUST report the pool busy and never read it inline.

  # @cc [owner:ghuntley,label:observability] pool-observer-absence-after-grace
  # An absent observer view MUST be announced by lilly.pool_observer_absent
  # once it has been continuously absent for longer than the grace (two
  # observation cadences by default), and lilly.pool_observer_present MUST
  # follow only an announced absence. A shorter absence, such as the first
  # samples of a healthy boot before the observer starts, MUST emit neither.
  @spec report(Pool.t(), View.view(), non_neg_integer()) :: OverallsProtocol.pool()
  def report(pool, view \\ @view, grace_ms \\ @absent_grace_ms) do
    now = System.monotonic_time(:millisecond)

    if Process.whereis(view) do
      presence(view, :present, now, grace_ms)

      case View.fetch(view, pool.id) do
        {:ok, {_version, %{observed_at: observed, entry: entry}}} -> stamp(entry, observed)
        :error -> %{id: pool.id, busy: true, storage: pool.storage}
      end
    else
      presence(view, :absent, now, grace_ms)
      %{id: pool.id, busy: true, storage: pool.storage}
    end
  end

  # Presence per view: :present, {:absent, since_ms} (not yet announced) or
  # :announced. persistent_term is written only on these transitions.
  @spec presence(View.view(), :present | :absent, integer(), non_neg_integer()) :: :ok
  defp presence(view, observed, now, grace_ms) do
    key = {__MODULE__, :presence, view}

    case {:persistent_term.get(key, :present), observed} do
      {:present, :present} ->
        :ok

      {:present, :absent} ->
        :persistent_term.put(key, {:absent, now})

      {{:absent, since}, :absent} when now - since > grace_ms ->
        :persistent_term.put(key, :announced)
        Lilly.Events.emit("lilly.pool_observer_absent", [])

      {{:absent, _since}, :absent} ->
        :ok

      {{:absent, _since}, :present} ->
        :persistent_term.put(key, :present)

      {:announced, :absent} ->
        :ok

      {:announced, :present} ->
        :persistent_term.put(key, :present)
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
             task: {Task.t(), DateTime.t(), integer()} | nil
           }

    # A slow read rests at least as long as it held the pool lock, up to this
    # bound, so observation holds the lock at most half the time while the
    # worst-case observation age stays within Marshall's 15 s pool busy grace.
    @max_rest_ms 3000

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
    # Each pool MUST have at most one read in flight, so reads never hold the
    # pool lock back to back. observed_at MUST be taken before the read starts,
    # so it never claims a later time than the data. A crashed read MUST leave
    # the previous observation published and MUST NOT stop later reads.

    # @cc [owner:ghuntley,label:capacity;concurrency] pool-observer-proportional-rest
    # After a read of duration d finishes or crashes, the next read MUST wait
    # rest(interval, d) = max(interval - d, min(d, 3000 ms)) before starting.
    # Reads of up to 3 s therefore leave the pool lock free at least half the
    # time, and fast reads still start once per interval. The worst-case age
    # of a published observation is d + rest + d of the next read: interval + d
    # for d <= interval / 2, 3d up to 3 s, and 2d + 3 s beyond.
    @impl true
    def handle_info(:tick, state), do: {:noreply, step(state, :tick)}

    def handle_info({ref, entry}, %{task: {%Task{ref: ref}, observed, started}} = state) do
      Process.demonitor(ref, [:flush])

      {:ok, _version} =
        View.put(state.view, state.pool.id, %{observed_at: observed, entry: entry})

      {:noreply, finish(state, started)}
    end

    def handle_info(
          {:DOWN, ref, :process, _pid, _reason},
          %{task: {%Task{ref: ref}, _observed, started}} = state
        ) do
      Lilly.Events.emit("lilly.pool_observation_failed", pool_id: state.pool.id)
      {:noreply, finish(state, started)}
    end

    def handle_info(_message, state), do: {:noreply, state}

    @doc false
    @spec rest(pos_integer(), non_neg_integer()) :: non_neg_integer()
    def rest(interval, duration), do: max(interval - duration, min(duration, @max_rest_ms))

    @spec finish(state(), integer()) :: state()
    defp finish(state, started) do
      duration = System.monotonic_time(:millisecond) - started
      Process.send_after(self(), :tick, rest(state.interval, duration))
      step(%{state | task: nil}, :done)
    end

    @spec step(state(), Cadence.event()) :: state()
    defp step(state, event) do
      case Cadence.step(state.cadence, event) do
        {:ok, cadence, [:start]} ->
          observed = DateTime.utc_now()
          started = System.monotonic_time(:millisecond)
          read = state.read
          pool = state.pool

          task =
            Task.Supervisor.async_nolink(PoolObserver.tasks(state.view), fn -> read.(pool) end)

          %{state | cadence: cadence, task: {task, observed, started}}

        {:ok, cadence, []} ->
          %{state | cadence: cadence}

        {:error, :invalid_transition} ->
          state
      end
    end
  end
end
