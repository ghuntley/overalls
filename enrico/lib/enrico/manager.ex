defmodule Enrico.Manager do
  @moduledoc "Single-flight mirror ownership and idempotent refresh attempts."
  use GenServer
  require Enrico.Events
  alias Enrico.{Config, Git, SLO}
  @max_completed 1_024
  @max_active 8

  @type status :: :running | :failed | :missing | %{state: :succeeded, head: binary()}
  @type attempt_key :: {binary(), binary()}
  @type state :: %{
          config: Config.t(),
          attempts: %{attempt_key() => status()},
          active: %{binary() => binary()},
          started: %{attempt_key() => integer()},
          generations: %{attempt_key() => reference()},
          slo: SLO.t(),
          monitors: %{reference() => {binary(), binary(), reference(), pid()}},
          completed: :queue.queue(attempt_key()),
          completed_count: non_neg_integer()
        }

  @spec refresh_limit() :: pos_integer()
  def refresh_limit, do: @max_active

  @spec start_link(Config.t()) :: GenServer.on_start()
  def start_link(config), do: GenServer.start_link(__MODULE__, config, name: __MODULE__)

  @spec refresh(binary(), binary(), binary(), binary()) :: {:ok, status()} | {:error, atom()}
  def refresh(id, attempt, owner, repo),
    do: GenServer.call(__MODULE__, {:refresh, id, attempt, owner, repo})

  @spec status(binary(), binary()) :: status()
  def status(id, attempt), do: GenServer.call(__MODULE__, {:status, id, attempt})

  @spec slo_snapshot() :: SLO.snapshot()
  def slo_snapshot, do: GenServer.call(__MODULE__, :slo_snapshot)

  @spec remove(binary()) :: :ok | {:error, atom()}
  def remove(id), do: GenServer.call(__MODULE__, {:remove, id}, 60_000)

  @impl true
  def init(config),
    do:
      {:ok,
       %{
         config: config,
         attempts: %{},
         active: %{},
         started: %{},
         generations: %{},
         slo: SLO.new(),
         monitors: %{},
         completed: :queue.new(),
         completed_count: 0
       }}

  # @cc [owner:ghuntley,label:recovery] mirror-attempt-single-flight
  # One repository MUST have at most one executing refresh. Repeating its
  # active attempt ID or a retained completed receipt MUST return its current
  # or final status without another fetch. Removal ends that repository's
  # receipt namespace; capped receipt eviction and service restart end local
  # replay retention. Marshall retains the durable audit and retry intent.

  # @cc [owner:ghuntley,label:recovery] mirror-refresh-retiring-owner
  # An admitted refresh MUST wait a bounded time for native owners retiring
  # from an earlier worker lifetime instead of failing before Git runs.
  # Single flight means any repository-lock holder is such a retiring owner
  # or an escaped descendant, never a live refresh of this Manager lifetime;
  # admission-slot holders may also be bounded reads.

  # @cc [owner:ghuntley,label:capacity] mirror-refresh-admission
  # At most eight repositories MUST own active refreshes. At saturation, new
  # attempts MUST refuse without task, receipt or measurement admission; replay
  # and same-repository busy checks MUST preserve their existing meaning.
  @impl true
  def handle_call({:refresh, id, attempt, owner, repo}, _from, state) do
    cond do
      not uuid?(id) or not uuid?(attempt) or not Git.valid_source?(owner, repo) ->
        {:reply, {:error, :invalid_request}, state}

      Map.has_key?(state.attempts, {id, attempt}) ->
        {:reply, {:ok, Map.fetch!(state.attempts, {id, attempt})}, state}

      Map.has_key?(state.active, id) ->
        {:reply, {:error, :busy}, state}

      map_size(state.active) >= @max_active ->
        {:reply, {:error, :unavailable}, state}

      true ->
        root = Path.join(state.config.state_dir, id <> ".git")
        manager = self()
        generation = make_ref()

        work =
          Overalls.Diagnostics.Context.wrap(fn ->
            receive do
              {:slo_ticket, ticket} ->
                started = System.monotonic_time(:microsecond)
                result = Git.refresh(root, owner, repo, Git.retiring_owner_wait())

                Overalls.RequestAccounting.Producer.complete(
                  Enrico.RequestRecorder,
                  ticket,
                  if(match?({:ok, _}, result), do: :success, else: :failure),
                  max(0, System.monotonic_time(:microsecond) - started)
                )

                send(manager, {:finished, id, attempt, generation, result})
            after
              8_000 -> exit(:measurement_admission_timeout)
            end
          end)

        case Task.Supervisor.start_child(Enrico.Tasks, work) do
          {:ok, pid} ->
            ticket = Overalls.RequestAccounting.Producer.admit(Enrico.RequestRecorder, pid)
            send(pid, {:slo_ticket, ticket})
            ref = Process.monitor(pid)
            Enrico.Events.emit("enrico.refresh_started", repository_id: id, attempt_id: attempt)

            next = %{
              state
              | attempts: Map.put(state.attempts, {id, attempt}, :running),
                active: Map.put(state.active, id, attempt),
                started:
                  Map.put(state.started, {id, attempt}, System.monotonic_time(:microsecond)),
                generations: Map.put(state.generations, {id, attempt}, generation),
                monitors: Map.put(state.monitors, ref, {id, attempt, generation, pid})
            }

            {:reply, {:ok, :running}, next}

          _ ->
            {:reply, {:error, :unavailable}, state}
        end
    end
  end

  def handle_call({:status, id, attempt}, _from, state) do
    {:reply, Map.get(state.attempts, {id, attempt}, :missing), state}
  end

  def handle_call(:slo_snapshot, _from, state),
    do: {:reply, SLO.snapshot(state.slo), state}

  def handle_call({:remove, id}, _from, state) do
    cond do
      not uuid?(id) ->
        {:reply, {:error, :invalid_request}, state}

      Map.has_key?(state.active, id) ->
        {:reply, {:error, :busy}, state}

      true ->
        root = Path.join(state.config.state_dir, id <> ".git")

        case Git.remove(root) do
          :ok ->
            Enrico.Events.emit("enrico.remove_succeeded", repository_id: id)

            completed = :queue.filter(fn {repo, _} -> repo != id end, state.completed)

            next = %{
              state
              | attempts: Map.reject(state.attempts, fn {{repo, _}, _} -> repo == id end),
                completed: completed,
                completed_count: :queue.len(completed)
            }

            {:reply, :ok, next}

          error ->
            {:reply, error, state}
        end
    end
  end

  @impl true
  # @cc [owner:ghuntley,label:recovery] mirror-generation-completion
  # Only the current refresh generation MUST settle its attempt. Completion
  # MUST retire its monitor before the same repository and attempt can be reused.
  def handle_info({:finished, id, attempt, generation, result}, state) do
    if is_reference(generation) and Map.get(state.active, id) == attempt and
         Map.get(state.generations, {id, attempt}) == generation do
      status =
        case result do
          {:ok, head} -> %{state: :succeeded, head: head}
          _ -> :failed
        end

      if is_map(status) do
        Enrico.Events.emit("enrico.refresh_succeeded", repository_id: id, attempt_id: attempt)
      else
        Enrico.Events.emit("enrico.refresh_failed",
          repository_id: id,
          attempt_id: attempt,
          reason: :git_failed
        )
      end

      {:noreply,
       state
       |> retire_generation(id, attempt, generation)
       |> Map.put(:active, Map.delete(state.active, id))
       |> complete(id, attempt, status)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _} ->
        {:noreply, state}

      {{id, attempt, generation, ^pid}, monitors} ->
        if reason != :normal and Map.get(state.active, id) == attempt and
             Map.get(state.generations, {id, attempt}) == generation do
          Enrico.Events.emit("enrico.refresh_failed",
            repository_id: id,
            attempt_id: attempt,
            reason: :task_exit
          )

          {:noreply,
           state
           |> Map.put(:monitors, monitors)
           |> Map.put(:generations, Map.delete(state.generations, {id, attempt}))
           |> Map.put(:active, Map.delete(state.active, id))
           |> complete(id, attempt, :failed)}
        else
          {:noreply, %{state | monitors: monitors}}
        end

      {_other, _monitors} ->
        {:noreply, state}
    end
  end

  @spec retire_generation(state(), binary(), binary(), reference()) :: state()
  defp retire_generation(state, id, attempt, generation) do
    monitors =
      Map.reject(state.monitors, fn {ref, entry} ->
        case entry do
          {^id, ^attempt, ^generation, _pid} ->
            Process.demonitor(ref, [:flush])
            true

          _ ->
            false
        end
      end)

    %{state | monitors: monitors, generations: Map.delete(state.generations, {id, attempt})}
  end

  defp uuid?(value),
    do:
      is_binary(value) and
        Regex.match?(
          ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
          value
        )

  # @cc [owner:ghuntley,label:capacity] mirror-attempt-retention
  # Completed attempt receipts MUST have a fixed in-memory cap; Marshall keeps
  # the durable audit and schedules retries after Enrico restarts.
  defp complete(state, id, attempt, status) do
    {started, remaining_started} = Map.pop(state.started, {id, attempt})
    duration_us = max(System.monotonic_time(:microsecond) - started, 0)
    slo = SLO.record(state.slo, is_map(status), duration_us)
    completed = :queue.in({id, attempt}, state.completed)
    attempts = Map.put(state.attempts, {id, attempt}, status)
    count = state.completed_count + 1

    if count > @max_completed do
      {{:value, oldest}, rest} = :queue.out(completed)

      %{
        state
        | attempts: Map.delete(attempts, oldest),
          started: remaining_started,
          slo: slo,
          completed: rest,
          completed_count: @max_completed
      }
    else
      %{
        state
        | attempts: attempts,
          started: remaining_started,
          slo: slo,
          completed: completed,
          completed_count: count
      }
    end
  end
end
