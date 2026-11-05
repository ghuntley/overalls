defmodule Marshall.Agents.Loop do
  @moduledoc "Marshall-owned polling scheduler for durable agent turns and tool results."
  use GenServer

  alias Marshall.Agents.{
    CLIAccess,
    Command,
    Compaction,
    Context,
    Event,
    ExecutorSession,
    ModelCall,
    ModelCalls,
    Planning,
    Root,
    Thread,
    Turn,
    TurnCoordinator
  }

  alias Marshall.Compute.{Ledger, VirtualMachine}
  alias Marshall.Authorization.SystemActor
  require Ash.Query
  require Marshall.Events

  @tick_ms 1000
  @claim_batch 16
  @running_batch 128

  @doc false
  @spec context_wait_event?(non_neg_integer()) :: boolean()
  def context_wait_event?(wait_seconds), do: wait_seconds == 0 or rem(wait_seconds, 15) == 0

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @impl true
  def init(_options) do
    Process.send_after(self(), :tick, @tick_ms)
    {:ok, %{ticks: 0, skill_restoration_cursor: nil}}
  end

  @impl true
  def handle_info(:tick, state) do
    state =
      try do
        %{state | skill_restoration_cursor: run_tick(state.skill_restoration_cursor)}
      rescue
        _ ->
          Marshall.Events.emit("agent.loop_failed", reason: :unexpected)
          state
      end

    if rem(state.ticks, 60) == 0, do: CLIAccess.reap()

    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, %{state | ticks: state.ticks + 1}}
  end

  # @cc [owner:ghuntley,label:concurrency;recovery] agent-server-owned-loop
  # Only Marshall claims turns and prepares provider context. Per-thread and
  # model-call PostgreSQL rows serialize every step; a process restart scans
  # durable state rather than trusting an in-memory queue.
  @spec tick() :: :ok
  def tick do
    _ = run_tick(nil)
    :ok
  end

  @spec run_tick(String.t() | nil) :: String.t() | nil
  defp run_tick(skill_restoration_cursor) do
    :ok = ModelCalls.reap()
    :ok = TurnCoordinator.reap_unavailable()
    :ok = ExecutorSession.reap_orphaned()
    {:ok, next_cursor} = Marshall.Agents.SkillMaintenance.tick(skill_restoration_cursor)
    claim_turns(@claim_batch)

    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Marshall.Repo,
        "SELECT id FROM agent_turns WHERE status = 'running' ORDER BY started_at, id LIMIT $1",
        [@running_batch],
        log: false
      )

    Enum.each(rows, fn [raw_id] -> advance(Ecto.UUID.load!(raw_id)) end)
    next_cursor
  end

  defp claim_turns(0), do: :ok

  defp claim_turns(remaining) do
    case TurnCoordinator.claim_next() do
      {:ok, %Turn{} = turn} ->
        schedule(turn.id)
        claim_turns(remaining - 1)

      _ ->
        :ok
    end
  end

  defp advance(turn_id) do
    [candidate] = Ledger.read!(Turn, id: turn_id)

    if candidate.maintenance_kind == :skill_operation do
      advance_skill(turn_id)
    else
      advance_conversation(turn_id)
    end
  end

  @spec advance_skill(String.t()) :: term()
  defp advance_skill(turn_id) do
    case Marshall.Agents.SkillMaintenance.advance(turn_id) do
      :completed -> TurnCoordinator.finish(turn_id, :completed, "Skills updated.")
      {:error, reason} -> TurnCoordinator.finish(turn_id, :failed, reason)
      _ -> :ok
    end
  end

  @spec advance_conversation(String.t()) :: term()
  defp advance_conversation(turn_id) do
    result =
      Ledger.transaction(fn ->
        turn = Ledger.lock!(Turn, turn_id)

        if turn && turn.status == :running do
          thread = Ledger.lock!(Thread, turn.thread_id)
          [root] = Ledger.read!(Root, id: thread.root_id)
          vm = List.first(Ledger.read!(VirtualMachine, id: root.vm_id))
          actor = Marshall.Accounts.Security.current(turn.actor_id)
          calls = Ledger.read!(ModelCall, turn_id: turn.id)

          cond do
            vm != nil and
                (vm.desired_state == :paused or vm.observed_state == :paused or
                   Ledger.read!(Marshall.Compute.WakeRequest,
                     vm_id: vm.id,
                     finished_at: [is_nil: true]
                   ) != []) ->
              :wait

            vm == nil or vm.desired_state != :running or vm.observed_state != :running ->
              :machine_unavailable

            not match?(%Marshall.Accounts.User{deleted_at: nil, active: true}, actor) or
                not Marshall.Access.Authorization.allowed?(vm, actor, "write") ->
              :access_revoked

            stale_model_binding?(calls, vm) ->
              ModelCalls.cancel_queued!(turn, vm, calls)
              :machine_unavailable

            true ->
              next_step(turn, thread, calls)
          end
        else
          :wait
        end
      end)

    case result do
      {:ok, :schedule} ->
        schedule(turn_id)

      {:ok, :tool_uncertain} ->
        TurnCoordinator.finish(turn_id, :failed, :tool_uncertain)

      {:ok, :capability_denied} ->
        TurnCoordinator.finish(turn_id, :failed, :capability_denied)

      {:ok, :provider_failed} ->
        TurnCoordinator.finish(turn_id, :failed, :provider_failed)

      {:ok, :machine_unavailable} ->
        TurnCoordinator.finish(turn_id, :failed, :machine_unavailable)

      {:ok, :access_revoked} ->
        TurnCoordinator.finish(turn_id, :failed, :access_revoked)

      _ ->
        :ok
    end
  end

  defp stale_model_binding?(calls, vm) do
    Enum.any?(calls, fn call ->
      call.status == :queued and
        (call.host_id != vm.host_id or call.placement_id != vm.current_placement_id or
           call.execution_epoch != vm.execution_epoch)
    end)
  end

  defp next_step(turn, thread, calls) do
    case Enum.max_by(calls, & &1.iteration, fn -> nil end) do
      nil ->
        :schedule

      %{status: status} when status in [:queued, :claimed] ->
        :wait

      %{status: :completed, purpose: purpose} when purpose != :inference ->
        :schedule

      %{status: :failed} = call ->
        if Compaction.failure_reason(call.response) in [
             :context_limit_exceeded,
             :native_compaction_unavailable
           ], do: :schedule, else: :provider_failed

      %{status: :completed} ->
        commands =
          Ledger.read!(Command, turn_id: turn.id)
          |> Enum.reject(&(Context.internal_tool?(&1.tool) or &1.tool == :artifact_stage))

        children = Ledger.read!(Event, turn_id: turn.id, kind: :child_spawned)
        answered = Ledger.read!(Event, turn_id: turn.id, kind: :questions_answered)

        cond do
          Planning.awaiting?(thread.id) ->
            :wait

          Enum.any?(commands, &(&1.status == :uncertain)) ->
            :tool_uncertain

          Enum.any?(
            commands,
            &(&1.status == :cancelled and &1.result == %{"reason" => "capability_denied"})
          ) ->
            :capability_denied

          commands == [] and children == [] and answered == [] ->
            :wait

          Enum.any?(commands, &(&1.status in [:queued, :claimed, :started])) or
              Enum.any?(children, &child_pending?/1) ->
            :wait

          true ->
            thread = record_results!(turn, thread, commands)
            record_child_results!(turn, thread, children)
            :schedule
        end

      %{status: :cancelled, response: %{"reason" => "capability_denied"}} ->
        :capability_denied

      _ ->
        :provider_failed
    end
  end

  defp record_results!(turn, thread, commands) do
    recorded =
      Event
      |> Ash.Query.filter(turn_id == ^turn.id and kind == :tool_result)
      |> Ash.read!(actor: SystemActor.compute())
      |> Enum.map(& &1.body["command_id"])
      |> MapSet.new()

    {_, next_sequence} =
      commands
      |> Enum.sort_by(&{&1.inserted_at, &1.id})
      |> Enum.reject(&MapSet.member?(recorded, &1.id))
      |> Enum.reduce({thread, thread.next_event_sequence}, fn command, {locked, sequence} ->
        result = Map.put(command.result || %{}, "status", Atom.to_string(command.status))

        if command.tool == :exec_command and command.status == :completed and
             is_binary(command.arguments["workdir"]) do
          Ledger.update!(locked, :set_context, %{working_directory: command.arguments["workdir"]})
        end

        Ledger.create!(Event, :append, %{
          thread_id: locked.id,
          turn_id: turn.id,
          sequence: sequence,
          kind: :tool_result,
          body: %{
            "command_id" => command.id,
            "call_id" => command.call_id,
            "result" => result
          }
        })

        {locked, sequence + 1}
      end)

    if next_sequence != thread.next_event_sequence,
      do: Ledger.update!(thread, :advance, %{next_event_sequence: next_sequence}),
      else: thread
  end

  defp child_pending?(%{body: %{"child_turn_id" => id}}) do
    case Ledger.read!(Turn, id: id) do
      [%{status: status}] -> status in [:queued, :running]
      _ -> false
    end
  end

  defp child_pending?(_), do: false

  defp record_child_results!(turn, thread, children) do
    recorded =
      Event
      |> Ash.Query.filter(turn_id == ^turn.id and kind == :tool_result)
      |> Ash.read!(actor: SystemActor.compute())
      |> Enum.map(& &1.body["child_turn_id"])
      |> MapSet.new()

    next_sequence =
      children
      |> Enum.sort_by(& &1.sequence)
      |> Enum.reject(&MapSet.member?(recorded, &1.body["child_turn_id"]))
      |> Enum.reduce(thread.next_event_sequence, fn child_event, sequence ->
        %{"call_id" => call_id, "child_turn_id" => child_turn_id} = child_event.body
        [child_turn] = Ledger.read!(Turn, id: child_turn_id)

        result =
          case child_turn.status do
            :completed ->
              case Ledger.read!(Event, turn_id: child_turn_id, kind: :assistant) do
                [%{body: %{"text" => text}}] -> %{"status" => "completed", "text" => text}
                _ -> %{"status" => "completed"}
              end

            _ ->
              %{
                "status" => "failed",
                "reason" => Atom.to_string(child_turn.failure_reason || :provider_failed)
              }
          end

        Ledger.create!(Event, :append, %{
          thread_id: thread.id,
          turn_id: turn.id,
          sequence: sequence,
          kind: :tool_result,
          body: %{
            "child_turn_id" => child_turn_id,
            "call_id" => call_id,
            "result" => result
          }
        })

        sequence + 1
      end)

    if next_sequence != thread.next_event_sequence,
      do: Ledger.update!(thread, :advance, %{next_event_sequence: next_sequence})
  end

  # @cc [owner:ghuntley,label:security;recovery] agent-loop-closed-failure-classes
  # A closed capability refusal from model-call admission MUST terminate the turn
  # with :capability_denied, never the catch-all :provider_failed. Unknown
  # provider-side failures retain :provider_failed.
  defp schedule(turn_id) do
    [turn] = Ledger.read!(Turn, id: turn_id)
    [thread] = Ledger.read!(Thread, id: turn.thread_id)

    if turn.maintenance_kind == :skill_operation do
      advance_skill(turn_id)
    else
      applied = Context.snapshot(turn_id)

      options =
        if applied && thread.working_directory &&
             thread.working_directory != applied.working_directory,
           do: [generation: applied.generation + 1, working_directory: thread.working_directory],
           else: []

      case Context.prepare(turn_id, options) do
        {:ok, _} when turn.maintenance_kind == :reload_context ->
          TurnCoordinator.finish(turn_id, :completed, "Context reloaded.")

        {:ok, _} ->
          queue_model(turn)

        {:pending, _} ->
          :ok

        {:error, reason} when reason in [:executor_unavailable, :stale_execution] ->
          wait_seconds = DateTime.diff(Ledger.now(), turn.started_at, :second)

          if context_wait_event?(wait_seconds) do
            Marshall.Events.emit("agent.context_waiting",
              thread_id: turn.thread_id,
              turn_id: turn.id,
              reason: reason
            )
          end

          if wait_seconds > 120 do
            Marshall.Events.emit("agent.context_timeout",
              thread_id: turn.thread_id,
              turn_id: turn.id,
              reason: reason
            )

            TurnCoordinator.finish(turn_id, :failed, :context_unavailable)
          end

        {:error, reason} ->
          fail_context(turn_id, reason)
      end
    end
  end

  @spec queue_model(Turn.t()) :: term()
  defp queue_model(turn) do
    model = Marshall.Threads.Mode.model(turn.mode)
    turn_id = turn.id

    case ModelCalls.queue(turn_id, model, Marshall.Threads.Mode.reasoning_effort(turn.mode)) do
      {:ok, _} ->
        :ok

      {:error, reason}
      when reason in [:already_queued, :waiting_for_tools, :waiting_for_answers, :stale_turn] ->
        :ok

      {:error, :machine_unavailable} ->
        TurnCoordinator.finish(turn_id, :failed, :machine_unavailable)

      {:error, :capability_denied} ->
        TurnCoordinator.finish(turn_id, :failed, :capability_denied)

      {:error, reason} ->
        fail_context(turn_id, reason)
    end
  end

  @spec fail_context(String.t(), atom()) :: term()
  defp fail_context(turn_id, reason) do
    # Closed reason atoms only; any other term is reported as :unexpected.
    Marshall.Events.emit("agent.turn_preparation_failed",
      turn_id: turn_id,
      reason: if(is_atom(reason), do: reason, else: :unexpected)
    )

    closed =
      cond do
        reason in [
          :context_too_large,
          :context_changed,
          :context_unavailable,
          :context_limit_exceeded,
          :compaction_no_progress,
          :nothing_to_compact,
          :invalid_compaction_response,
          :native_compaction_unavailable,
          :invalid_context,
          :skill_ambiguous,
          :skill_unavailable,
          :machine_unavailable,
          :access_revoked
        ] ->
          reason

        reason in [:context_size_exceeded, :context_history_too_large] ->
          :context_too_large

        reason in [:guest_identity_unavailable, :context_upgrade_required] ->
          :context_unavailable

        true ->
          :provider_failed
      end

    TurnCoordinator.finish(turn_id, :failed, closed)
  end
end
