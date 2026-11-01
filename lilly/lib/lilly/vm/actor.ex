defmodule Lilly.VM.Actor do
  @moduledoc "One durable placement actor; systemd owns the VMM independently of this process."
  use GenServer
  require Lilly.Events
  alias Lilly.Control.Store
  alias Lilly.Host.{Lock, PrivateFiles}
  alias Lilly.VM.Journal
  alias Lilly.VM.DeleteRetry
  alias Lilly.Execution.{Liveness, Watch}
  alias OverallsProtocol.Cadence
  # Kinds with a launch commit point: preemptible until commit (ADR-0176).
  @launch_kinds [:provision, :start, :resume]
  # The fallback bound for executors without effect_deadline_ms/2.
  @effect_deadline_ms 120_000

  # Backstops for published proof (ADR-0140 phase 3). With the exit watcher
  # armed on the proven VMM, death revokes within milliseconds, so the deadline
  # only bounds how long inconclusive observations are tolerated. Without it,
  # proof lapses two seconds after the last observation.
  @unwatched_ms 2_000
  @watched_ms 30_000
  @steady_reconcile_ms 10_000
  @steady_after 3

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options)
  @spec reconcile(pid()) :: :ok
  def reconcile(pid), do: GenServer.cast(pid, :reconcile)
  @spec acknowledge(pid(), [OverallsProtocol.uuid()]) :: :ok
  def acknowledge(pid, ids), do: GenServer.cast(pid, {:acknowledge, ids})
  @spec status(pid()) :: map()
  def status(pid), do: GenServer.call(pid, :status)

  @spec terminal_owner(pid(), pid() | nil) :: :ok | {:error, atom()}
  def terminal_owner(pid, owner), do: call(pid, {:terminal_owner, owner})

  # @cc [owner:ghuntley,label:security] terminal-identity-requires-current-running-boot
  # terminal_identity/2 MUST authorize only the assigned stream PID, require the
  # current durable running placement/epoch/generation, and return the vsock
  # path bound to the persisted current boot challenge; superseded intent or a
  # mismatched running outcome MUST deny terminal dialing.
  @spec terminal_identity(pid(), OverallsProtocol.uuid()) :: {:ok, map()} | {:error, atom()}
  def terminal_identity(pid, vm_id), do: call(pid, {:terminal_identity, vm_id})

  # @cc [owner:ghuntley,label:security;recovery] boot-log-assigned-stream-current-command
  # Only the assigned stream MAY read diagnostics for the active actor's exact
  # current runnable VM command. The durable command MUST be unchanged before
  # and after the bounded read. Pending or failed outcomes MAY expose the
  # current boot log, but MUST NOT grant terminal identity or guest dialing.
  @spec boot_log(pid(), OverallsProtocol.uuid(), non_neg_integer()) ::
          {:ok, Lilly.VM.BootLog.page()} | {:error, atom()}
  def boot_log(pid, vm_id, cursor), do: call(pid, {:boot_log, vm_id, cursor})

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)
    store = Keyword.fetch!(options, :store)
    id = Keyword.fetch!(options, :placement_id)
    owner = Keyword.fetch!(options, :owner)
    directory = Path.join([Path.dirname(store.path), "actors", id])

    with true <- store.protocol_version == 3,
         {:ok, command} when not is_nil(command) <- Store.read(store, id),
         :ok <- PrivateFiles.directory(Path.dirname(directory)),
         {:ok, lock} <- Lock.await(directory, 5000) do
      case Journal.open(directory, store.host_id, command.vm_id, id) do
        {:ok, journal}
        when {journal.attempted_epoch, journal.attempted_generation} <=
               {command.execution_epoch, command.generation} ->
          monitor = Process.monitor(owner)
          send(owner, {:vm_actor_ready, id, self(), Journal.pending(journal)})
          maybe_retire(owner, command, journal)

          {:ok,
           %{
             store: store,
             command: command,
             journal: journal,
             lock: lock,
             owner: owner,
             monitor: monitor,
             executor: Keyword.fetch!(options, :executor),
             task: nil,
             task_command: nil,
             task_started_at: nil,
             task_deadline_ms: nil,
             delete_attempts: 0,
             next_delete_attempt_at: nil,
             terminal_owner: Keyword.get(options, :terminal_owner),
             view: Keyword.get(options, :view, Lilly.Execution.view()),
             liveness: Liveness.new(),
             proof_target: nil,
             liveness_timer: nil,
             cadence: Cadence.new(),
             probe: nil,
             watch: Watch.new(),
             watch_port: nil,
             watch_executable:
               Keyword.get_lazy(options, :watch_executable, fn ->
                 System.find_executable("lilly-vm-watch")
               end),
             deferred: nil,
             settled: nil,
             active: false,
             steady: 0,
             last_reconcile_at: nil,
             committed: false,
             effect_deadline_ms: Keyword.get(options, :effect_deadline_ms, @effect_deadline_ms)
           }}

        _ ->
          Lock.release(lock)
          actor_stopped(command.vm_id, command.placement_id, :invalid_execution_journal)
          {:stop, :invalid_execution_journal}
      end
    else
      _ ->
        actor_stopped(Keyword.get(options, :vm_id), id, :vm_actor_unavailable)
        {:stop, :vm_actor_unavailable}
    end
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, public(state), state}

  def handle_call({:terminal_owner, owner}, {caller, _}, %{owner: caller} = state)
      when is_pid(owner) or is_nil(owner),
      do: {:reply, :ok, %{state | terminal_owner: owner}}

  def handle_call({:terminal_identity, vm_id}, {caller, _}, %{terminal_owner: caller} = state) do
    with true <- state.active,
         true <- state.command.vm_id == vm_id,
         {:ok, command} <- Store.read(state.store, state.command.placement_id),
         true <-
           command == state.command and command.placement_id == state.command.placement_id and
             command.execution_epoch == state.command.execution_epoch and
             command.generation == state.command.generation and
             command.kind in [:provision, :start, :resume],
         %{state: :running} = outcome <- state.journal.outcome,
         true <-
           outcome.execution_epoch == command.execution_epoch and
             outcome.placement_id == command.placement_id,
         {executor, context} = state.executor,
         true <- function_exported?(executor, :terminal_options, 2),
         {:ok, options} <- executor.terminal_options(context, command),
         uds_path <- Keyword.get(options, :vsock_path),
         boot_challenge <- Keyword.get(options, :boot_challenge),
         boot_log_path <- Keyword.get(options, :boot_log_path) do
      {:reply,
       {:ok,
        %{
          uds_path: uds_path,
          boot_log_path: boot_log_path,
          placement_id: command.placement_id,
          execution_epoch: command.execution_epoch,
          generation: command.generation,
          guest_identity: Keyword.get(options, :guest_identity),
          profile: command.profile,
          slot: command.slot,
          boot_challenge: boot_challenge
        }}, state}
    else
      _ -> {:reply, {:error, :terminal_unavailable}, state}
    end
  end

  def handle_call({:boot_log, vm_id, cursor}, {caller, _}, %{terminal_owner: caller} = state) do
    with true <- state.active and state.command.vm_id == vm_id,
         {:ok, command} <- Store.read(state.store, state.command.placement_id),
         true <- command == state.command and command.kind in [:provision, :start, :resume],
         {executor, context} = state.executor,
         true <- function_exported?(executor, :boot_log, 3),
         {:ok, page} <- executor.boot_log(context, command, cursor),
         {:ok, ^command} <- Store.read(state.store, command.placement_id) do
      {:reply, {:ok, page}, state}
    else
      _ -> {:reply, {:error, :boot_log_unavailable}, state}
    end
  end

  # @cc [owner:ghuntley,label:recovery;concurrency] launch-commit-single-decision
  # The actor MUST grant a launch commit only to its in-flight task, for that
  # task's command, while that command is still the newest stored command;
  # once granted the task MUST NOT be preempted. Any other request is refused,
  # so launch authority is decided once, by this process (ADR-0176).
  def handle_call({:commit_launch, command}, _from, %{task_command: command} = state) do
    case Store.read(state.store, command.placement_id) do
      {:ok, ^command} -> {:reply, :ok, %{state | committed: true}}
      _ -> {:reply, {:error, :preempted}, state}
    end
  end

  def handle_call({:commit_launch, _command}, _from, state),
    do: {:reply, {:error, :preempted}, state}

  def handle_call(_, _, state), do: {:reply, {:error, :not_terminal_owner}, state}

  @impl true
  # @cc [owner:ghuntley,label:capacity;recovery;concurrency] reconcile-cast-is-request-only-on-change
  # The runtime casts :reconcile to every actor each time it processes its
  # command set (about once per control exchange). Only the first activation
  # or a durable command different from the one held is a Cadence :request
  # (catch up as soon as the current run ends); an unchanged cast is a :tick,
  # dropped during a run. Otherwise every actor reconciles back to back and
  # holds the placement and pool locks continuously, starving relaunches.
  def handle_cast(:reconcile, state) do
    event = if state.active and not command_changed?(state), do: :tick, else: :request
    if not state.active, do: Process.send_after(self(), :tick, 1000)
    state = %{state | active: true}

    cond do
      event == :request and preemptible?(state) -> preempt(state)
      event == :tick and steady?(state) -> {:noreply, state}
      true -> request(state, event)
    end
  end

  def handle_cast({:acknowledge, ids}, state) do
    case Journal.acknowledge(state.journal, ids) do
      {:ok, journal} ->
        state = %{state | journal: journal}
        publish(state)
        maybe_retire(state.owner, state.command, journal)
        {:noreply, state}

      # Contention with another authoritative journal writer: nothing was written;
      # the physical outcome acknowledgement is redelivered with the next exchange.
      {:error, :journal_busy} ->
        {:noreply, state}

      _ ->
        actor_stopped(state.command.vm_id, state.command.placement_id, :journal_write_failed)
        {:stop, :journal_write_failed, state}
    end
  end

  @impl true
  # A lost hostd session ends this lease (ADR-0176 decision 4).
  def handle_info({:DOWN, ref, :process, _, _}, %{lock: %Lilly.Host.Lease{monitor: ref}} = state),
    do: {:stop, :journal_lock_lost, state}

  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, 1000)
    state = probe_boot(state)

    cond do
      # A deferred supersession reaches its effect boundary or its deadline.
      not is_nil(state.task) and preemptible?(state) -> preempt(state)
      steady?(state) -> {:noreply, state}
      true -> request(state, :tick)
    end
  end

  def handle_info({ref, {:boot_probe, command, proof}}, %{probe: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state = %{state | probe: nil}

    if command == state.command,
      do: observed({:noreply, state}, {:booting, proof}),
      else: {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{probe: %Task{ref: ref}} = state),
    do: {:noreply, %{state | probe: nil}}

  def handle_info({:liveness_expired, ref}, %{liveness_timer: {ref, _timer}} = state),
    do: {:noreply, liveness(%{state | liveness_timer: nil}, :expired)}

  def handle_info({:liveness_expired, _stale}, state), do: {:noreply, state}

  def handle_info({port, {:data, {:eol, "armed"}}}, %{watch_port: port} = state) do
    state = watch(state, :armed)

    # An armed watcher extends held proof to the watched backstop.
    if state.liveness.state in [:booting, :live] and
         watched_proof?(state.watch, state.proof_target),
       do: {:noreply, liveness(state, :watched)},
       else: {:noreply, state}
  end

  def handle_info({port, {:data, {:eol, "exited"}}}, %{watch_port: port} = state),
    do: {:noreply, watch(%{state | steady: 0}, :exited)}

  def handle_info({port, {:data, {:eol, _other}}}, %{watch_port: port} = state),
    do: {:noreply, watch(%{state | steady: 0}, :error)}

  def handle_info({port, {:exit_status, _}}, %{watch_port: port} = state),
    do: {:noreply, watch(%{state | watch_port: nil, steady: 0}, :crashed)}

  def handle_info({port, _message}, state) when is_port(port),
    do: {:noreply, state}

  # @cc [owner:ghuntley,label:recovery] async-results-retain-original-generation
  # Actor.handle_info/2 MUST re-read durable intent before accepting an executor result; a result
  # for superseded work must not be published or relabeled as the newer epoch/generation.
  def handle_info({ref, {result, target}}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    command = state.task_command
    state = %{state | task: nil, task_command: nil, task_started_at: nil, task_deadline_ms: nil}

    case Store.read(state.store, command.placement_id) do
      {:ok, ^command} ->
        state |> finish(command, result, target) |> observed(target) |> completed()

      {:ok, latest}
      when latest != nil and
             {latest.execution_epoch, latest.generation} >
               {command.execution_epoch, command.generation} ->
        # Superseded work: start the newer command now rather than next tick.
        {:noreply, state} |> completed() |> requested()

      _ ->
        {:stop, :command_store_failed, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{task: %Task{ref: ref}} = state),
    do:
      {:noreply,
       %{state | task: nil, task_command: nil, task_started_at: nil, task_deadline_ms: nil}}
      |> completed()

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{monitor: ref} = state),
    do: {:stop, :shutdown, state}

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    Lilly.SupervisedStop.emit_actor(reason, state.command.vm_id, state.command.placement_id)
    if state.task, do: Task.shutdown(state.task, :brutal_kill)
    if state.probe, do: Task.shutdown(state.probe, :brutal_kill)
    Lock.release(state.lock)
    :ok
  end

  @impl true
  def format_status(status), do: Lilly.DiagnosticStatus.redact(status, public(status.state))

  # @cc [owner:ghuntley,label:recovery;concurrency] newer-command-preempts-uncommitted
  # A newer stored command MUST stop an in-flight launch task (provision,
  # start, resume) that has not been granted its launch commit, before the
  # newer command starts. Killing the task closes its native lock owners,
  # which kill and reap their utilities before releasing ownership, exactly as
  # on caller death; no launch attempt is persisted for the preempted command
  # (ADR-0176).

  # @cc [owner:ghuntley,label:recovery;concurrency] non-launch-effects-finish-or-deadline
  # A newer stored command MUST NOT kill an in-flight stop, pause, resize or
  # delete task before its effect deadline (from the task's start; the
  # executor's `effect_deadline_ms/2`, derived from that effect's configured
  # inner timeouts plus a margin, else the actor's `effect_deadline_ms`
  # option): the task runs to its own end and the newer command then starts
  # at once. An unreadable command store MUST NOT preempt a non-launch task
  # before its deadline. Two exceptions MUST preempt as before:
  # a newer delete (which removes every partial effect) preempts at once, and
  # any task still running at its deadline is killed by the next tick, so a
  # wedged effect delays the newer command by at most the deadline plus one
  # tick (ADR-0176 amendment of 2026-11-01).
  defp preemptible?(%{task: %Task{}, committed: false, task_command: %{} = command} = state) do
    case Store.read(state.store, state.command.placement_id) do
      {:ok, latest} when latest == state.command ->
        false

      {:ok, latest} ->
        command.kind in @launch_kinds or latest.kind == :delete or past_deadline?(state)

      # An unreadable store proves nothing about a newer command: it must not
      # kill a non-launch effect mid-step before its deadline.
      _ ->
        command.kind in @launch_kinds or past_deadline?(state)
    end
  end

  defp preemptible?(_state), do: false

  defp past_deadline?(%{task_started_at: started, task_deadline_ms: deadline})
       when is_integer(started) and is_integer(deadline),
       do: System.monotonic_time(:millisecond) - started >= deadline

  defp past_deadline?(_state), do: false

  # The executor's per-effect bound (its own configured inner timeouts plus a
  # margin) when it provides one; otherwise the actor's configured default.
  @spec effect_deadline(map(), map()) :: pos_integer()
  defp effect_deadline(%{executor: {executor, context}} = state, command) do
    if Code.ensure_loaded?(executor) and function_exported?(executor, :effect_deadline_ms, 2),
      do: executor.effect_deadline_ms(context, command),
      else: state.effect_deadline_ms
  end

  defp preempt(state) do
    command = state.task_command
    Task.shutdown(state.task, :brutal_kill)

    Lilly.Events.emit("vm.execution_preempted",
      vm_id: command.vm_id,
      placement_id: command.placement_id
    )

    state = %{
      state
      | task: nil,
        task_command: nil,
        task_started_at: nil,
        task_deadline_ms: nil,
        committed: false,
        steady: 0
    }

    case Cadence.step(state.cadence, :done) do
      {:ok, cadence, [:start]} -> start(%{state | cadence: cadence})
      {:ok, cadence, []} -> request(%{state | cadence: cadence}, :request)
      {:error, :invalid_transition} -> request(state, :request)
    end
  end

  defp schedule(%{active: false} = state), do: {:noreply, state}

  # @cc [owner:ghuntley,label:recovery] journal-attempt-before-executor
  # schedule/1 MUST durably record the attempted command epoch/generation before starting asynchronous
  # physical work; it must not run a second executor task while one is already in flight.
  defp schedule(state) do
    with {:ok, command} when not is_nil(command) <-
           Store.read(state.store, state.command.placement_id) do
      state =
        if command != state.command,
          do:
            %{
              state
              | delete_attempts: 0,
                next_delete_attempt_at: nil,
                deferred: nil,
                settled: nil
            }
            |> Map.put(:steady, 0)
            |> watch(:stop)
            |> liveness(:revoke),
          else: state

      if not is_nil(state.task) or settled?(state, command) or
           (command.kind == :delete and is_integer(state.next_delete_attempt_at) and
              System.monotonic_time(:millisecond) < state.next_delete_attempt_at) do
        {:noreply, state}
      else
        case Journal.attempt(state.journal, command) do
          {:ok, journal} ->
            {executor, context} = state.executor

            actor = self()

            history = %{
              running_epoch: journal.running_epoch,
              running_generation: journal.running_generation,
              commit: fn ->
                try do
                  GenServer.call(actor, {:commit_launch, command}, 30_000)
                catch
                  :exit, _ -> {:error, :preempted}
                end
              end
            }

            task =
              Task.async(fn ->
                result = executor.reconcile(context, command, history)
                {result, evidence(executor, context, command, result)}
              end)

            {:noreply,
             %{
               state
               | command: command,
                 journal: journal,
                 task: task,
                 task_command: command,
                 task_started_at: System.monotonic_time(:millisecond),
                 task_deadline_ms: effect_deadline(state, command),
                 committed: false,
                 last_reconcile_at: System.monotonic_time(:millisecond)
             }}

          # Contention: the attempt was not written; the next tick retries.
          {:error, :journal_busy} ->
            {:noreply, state}

          _ ->
            {:stop, :command_store_failed, state}
        end
      end
    else
      _ -> {:stop, :command_store_failed, state}
    end
  end

  # @cc [owner:ghuntley,label:capacity;recovery;concurrency] failed-outcome-settles-command
  # Once this actor process has durably recorded (or identically re-recorded)
  # a failed outcome for the exact newest stored command, schedule/1 MUST NOT
  # start executor work for that command again: no tick, unchanged reconcile
  # cast or completed-run follow-up may re-run the failure fence. A different
  # stored command (newer generation, epoch, start or delete) MUST drive at
  # once. A replacement actor MUST drive the command once before settling, so
  # readiness still rests on an observation made by the current runtime and an
  # actor restart cannot loop. Journal contention, retry results and unknown
  # outcomes MUST NOT settle.

  # @cc [owner:ghuntley,label:recovery;concurrency;capacity] applied-resize-settles-command
  # Once this actor process has durably recorded (or identically re-recorded)
  # a stopped outcome for the exact newest stored resize command (operation
  # ID, placement, epoch and generation) whose applied sizes equal that
  # command's target sizes, schedule/1 MUST NOT start executor work for that command again,
  # exactly as for a settled failure: a re-driven resize repeats disk growth
  # and metadata writes, and a newer command would then preempt it mid-effect.
  # A stopped outcome without applied sizes, or with sizes other than the
  # target, MUST NOT settle. A newer command MUST still drive at once, and a
  # replacement actor MUST drive the resize once before settling.
  @spec settled?(map(), map()) :: boolean()
  defp settled?(%{settled: command, journal: %{outcome: %{state: :failed} = outcome}}, command),
    do: same_operation?(outcome, command)

  defp settled?(
         %{
           settled: %{kind: :resize} = command,
           journal: %{outcome: %{state: :stopped} = outcome}
         },
         command
       ),
       do: applied_target?(command, outcome) and same_operation?(outcome, command)

  defp settled?(_state, _command), do: false

  @spec same_operation?(map(), map()) :: boolean()
  defp same_operation?(outcome, command),
    do:
      outcome.operation_id == command.id and outcome.placement_id == command.placement_id and
        outcome.execution_epoch == command.execution_epoch and
        outcome.generation == command.generation

  @spec settles?(map(), map()) :: boolean()
  defp settles?(_command, %{state: :failed}), do: true

  defp settles?(%{kind: :resize} = command, %{state: :stopped} = observation),
    do: applied_target?(command, observation)

  defp settles?(_command, _observation), do: false

  @spec applied_target?(map(), map()) :: boolean()
  defp applied_target?(command, %{applied_sizes: sizes}),
    do: sizes == OverallsProtocol.Resize.sizes(command)

  defp applied_target?(_command, _observation), do: false

  # @cc [owner:ghuntley,label:recovery;observability] actor-stop-events-precede-otp-report
  # vm.actor_stopped MUST be emitted before {:stop, reason, state} for invalid
  # journals, unavailable actors, invalid executor results and failed journal
  # writes, carrying only VM/placement identifiers and the closed reason atom;
  # OTP crash reporting MUST remain intact and terminal bytes or payloads MUST
  # NOT be attached.
  defp actor_stopped(vm_id, placement_id, reason) do
    if OverallsProtocol.uuid?(vm_id) and OverallsProtocol.uuid?(placement_id) do
      Lilly.Events.emit("vm.actor_stopped",
        vm_id: vm_id,
        placement_id: placement_id,
        reason: reason
      )
    end

    :ok
  end

  defp finish(state, command, {:ok, observation}, evidence) do
    state = %{state | deferred: nil}

    case Journal.record(state.journal, command, observation) do
      {:ok, journal} ->
        steady =
          if journal == state.journal and observation.state == :running,
            do: state.steady + 1,
            else: 0

        settled = if settles?(command, observation), do: command
        state = %{state | steady: steady, settled: settled}

        # An identical observation leaves the journal unchanged: nothing new
        # was recorded, so there is nothing to announce.
        if journal != state.journal do
          Lilly.Events.emit("vm.outcome_recorded",
            vm_id: command.vm_id,
            placement_id: command.placement_id,
            outcome_state: observation.state
          )

          recorded_failure(command, observation)
        end

        state = %{state | journal: journal}

        state =
          if command.kind == :delete and observation.state == :unknown and
               observation.reason == :cleanup_failed do
            attempts = state.delete_attempts + 1

            %{
              state
              | delete_attempts: attempts,
                next_delete_attempt_at:
                  System.monotonic_time(:millisecond) + DeleteRetry.delay(attempts)
            }
          else
            %{state | delete_attempts: 0, next_delete_attempt_at: nil}
          end

        state =
          if observation.state == :running do
            state = %{state | proof_target: running_target(evidence)}
            liveness(state, :observed_running)
          else
            liveness(state, :revoke)
          end

        send(
          state.owner,
          {:vm_actor_reconciled, command.placement_id, self(),
           {command.placement_id, command.execution_epoch, command.generation}}
        )

        publish(state)
        {:noreply, state}

      # Contention: the outcome was not written. The next reconcile re-observes
      # the same physical state idempotently and records it then.
      {:error, :journal_busy} ->
        Lilly.Events.emit("vm.execution_deferred",
          vm_id: command.vm_id,
          placement_id: command.placement_id,
          reason: :journal_busy
        )

        {:noreply, state}

      # The specific closed reason makes the failure diagnosable; the actor
      # still stops (and the runtime fences) as before.
      failure ->
        reason =
          case failure do
            {:error, specific}
            when specific in [:stale_generation, :outcome_sequence_exhausted] ->
              specific

            _ ->
              :journal_write_failed
          end

        actor_stopped(state.command.vm_id, state.command.placement_id, reason)
        {:stop, :journal_write_failed, state}
    end
  end

  # @cc [owner:ghuntley,label:observability;recovery] actor-deferral-transitions-visible
  # A retryable executor result MUST leave the durable journal and outcome
  # unchanged. The actor MUST emit vm.execution_deferred once per distinct
  # consecutive reason for the current command (not on every retry tick), and
  # a recorded outcome or newer command MUST re-arm it. Only identifiers and the
  # closed executor reason atom may be attached.
  defp finish(%{deferred: reason} = state, _command, {:retry, reason}, _evidence),
    do: {:noreply, liveness(%{state | steady: 0}, :inconclusive)}

  defp finish(state, command, {:retry, reason}, _evidence) when is_atom(reason) do
    Lilly.Events.emit("vm.execution_deferred",
      vm_id: command.vm_id,
      placement_id: command.placement_id,
      reason: reason
    )

    {:noreply, liveness(%{state | deferred: reason, steady: 0}, :inconclusive)}
  end

  defp finish(state, _command, {:retry, _}, _evidence),
    do: {:noreply, liveness(%{state | steady: 0}, :inconclusive)}

  defp finish(state, _command, _, _evidence) do
    actor_stopped(state.command.vm_id, state.command.placement_id, :invalid_executor_result)
    {:stop, :invalid_executor_result, state}
  end

  # @cc [owner:ghuntley,label:observability;recovery] failure-event-once-per-recorded-outcome
  # vm.failed MUST be emitted only after the durable journal records a new
  # failed outcome for the current command, so a failed placement whose
  # desired state is still running and is re-observed (once per actor process,
  # see failed-outcome-settles-command) reports once per distinct failed outcome (placement, epoch, generation, reason and
  # facts), not once per reconcile. A recovered outcome, a new failure reason or
  # a newer command's failure MUST emit again; an actor restart over the same
  # journaled failure MUST NOT. Only identifiers and the closed reason atom.
  defp recorded_failure(command, %{state: :failed, reason: reason}) do
    Lilly.Events.emit("vm.failed",
      vm_id: command.vm_id,
      placement_id: command.placement_id,
      reason: reason
    )
  end

  defp recorded_failure(_command, _observation), do: :ok

  defp publish(state) do
    send(
      state.owner,
      {:vm_actor_capacity, state.command.placement_id, self(), capacity_proof(state)}
    )

    send(
      state.owner,
      {:vm_actor_outcome, state.command.placement_id, self(), Journal.pending(state.journal)}
    )
  end

  # @cc [owner:ghuntley,label:capacity] actor-capacity-current-outcome
  # Capacity coverage MUST bind the current durable command and its exact
  # physically verified running/stopped outcome; stale generations cannot cover startup.
  defp capacity_proof(state) do
    case state.journal.outcome do
      %{state: status} = outcome when status in [:running, :stopped, :paused] ->
        if outcome.placement_id == state.command.placement_id and
             outcome.execution_epoch == state.command.execution_epoch and
             outcome.generation == state.command.generation do
          %{
            "execution_epoch" => outcome.execution_epoch,
            "generation" => outcome.generation,
            "outcome_id" => outcome.id,
            "compute" => status == :running,
            "disk" => outcome.disk_present
          }
        end

      _ ->
        nil
    end
  end

  # @cc [owner:ghuntley,label:recovery] retire-only-acknowledged-current-delete
  # maybe_retire/3 MUST request retirement only after the current delete generation has a deleted
  # physical outcome and its durable acknowledgement; an older acknowledgement must not retire
  # active intent.
  defp maybe_retire(owner, command, journal) do
    if journal.acknowledged and journal.outcome != nil and journal.outcome.state == :deleted and
         journal.outcome.generation == command.generation and
         journal.outcome.execution_epoch == command.execution_epoch and
         journal.outcome.placement_id == command.placement_id and command.kind == :delete do
      send(owner, {:vm_actor_retire, command.placement_id, self(), journal.outcome})
    end

    :ok
  end

  # @cc [owner:ghuntley,label:capacity;recovery] actor-observation-cadence
  # Every observation start MUST pass through the Cadence: at most one executor
  # task in flight. The periodic tick is dropped during a run, so reconciles
  # rest between runs and never hold placement or pool locks back to back; a
  # new or superseding command (:request) starts exactly one follow-up as soon
  # as the run completes. An attempt that starts no task completes at once.
  defp request(state, event) do
    case Cadence.step(state.cadence, event) do
      {:ok, cadence, [:start]} -> start(%{state | cadence: cadence})
      {:ok, cadence, []} -> {:noreply, %{state | cadence: cadence}}
    end
  end

  # Superseded work needs the newer command started, unless completing the old
  # run already started it (a pending request); requesting again would mark a
  # second, redundant run due.
  defp requested({:noreply, state}) do
    if Cadence.running?(state.cadence), do: {:noreply, state}, else: request(state, :request)
  end

  defp requested(stop), do: stop

  defp command_changed?(state) do
    case Store.read(state.store, state.command.placement_id) do
      {:ok, command} -> command != state.command
      _ -> true
    end
  end

  defp start(state) do
    case schedule(state) do
      {:noreply, %{task: nil} = state} -> completed({:noreply, state})
      other -> other
    end
  end

  defp completed({:noreply, state}) do
    case Cadence.step(state.cadence, :done) do
      {:ok, cadence, [:start]} -> start(%{state | cadence: cadence})
      {:ok, cadence, []} -> {:noreply, %{state | cadence: cadence}}
      {:error, :invalid_transition} -> {:noreply, state}
    end
  end

  defp completed(stop), do: stop

  # Applies one liveness event: executes its row effects, then keeps one expiry
  # timer at the held rows' deadline (none when no rows are held).
  defp liveness(state, event) do
    case Liveness.step(state.liveness, event) do
      {:ok, machine, effects} ->
        state = %{state | liveness: machine}
        deadline = System.monotonic_time(:millisecond) + backstop_ms(state)
        state = Enum.reduce(effects, state, &live_effect(&1, &2, deadline))
        published? = Enum.any?(effects, &match?({:publish, _}, &1))

        cond do
          Liveness.rows(machine.state) == [] -> disarm(%{state | proof_target: nil})
          published? -> arm(state, deadline)
          true -> state
        end

      # An undeclared transition fails closed: no proof survives it.
      {:error, :invalid_transition} ->
        state = Enum.reduce([:live, :boot], state, &live_effect({:delete, &1}, &2, 0))
        disarm(%{state | liveness: Liveness.new(), proof_target: nil})
    end
  end

  # @cc [owner:ghuntley,label:recovery;security] actor-boot-probe-during-reconcile
  # A reconcile may wait for guest readiness for minutes, and readiness needs
  # roster bootstrap, which needs boot proof. While a reconcile is in flight and
  # the execution is not live, each tick MAY start one independent boot probe
  # (Executor.boot_proof/2, at most one in flight). Its result MUST feed the
  # same liveness events as a reconcile's boot evidence and MUST be ignored if
  # the command changed meanwhile.
  defp probe_boot(%{task: %Task{}, probe: nil, liveness: %{state: liveness}} = state)
       when liveness != :live do
    {executor, context} = state.executor

    if function_exported?(executor, :boot_proof, 2) do
      command = state.command
      task = Task.async(fn -> {:boot_probe, command, executor.boot_proof(context, command)} end)
      %{state | probe: task}
    else
      state
    end
  end

  defp probe_boot(state), do: state

  # @cc [owner:ghuntley,label:security;recovery] actor-watched-proof-exact-target
  # The long backstop MUST require an armed watcher on exactly the VMM that
  # supplied the current proof. Retained, unarmed, unavailable or replaced
  # targets MUST NOT extend authority, including on delayed armed messages.
  @spec watched_proof?(Watch.t(), Watch.target() | nil) :: boolean()
  defp watched_proof?(_watch, nil), do: false
  defp watched_proof?(watch, target), do: Watch.watching?(watch, target)

  # @cc [owner:ghuntley,label:capacity;recovery;concurrency] steady-state-reconcile-backstop
  # Apart from a settled failed outcome (failed-outcome-settles-command) or
  # applied resize (applied-resize-settles-command), a
  # tick or unchanged reconcile cast MAY skip starting a reconcile only while
  # the actor is steady: at least three consecutive reconciles of the current
  # command recorded an unchanged running outcome, an armed watcher holds the
  # exact VMM of the current proof, and the last reconcile started under 10 s
  # ago, well inside the 30 s watched backstop. A changed command, a deferral,
  # any other outcome or any watcher event other than armed MUST end steadiness
  # and restore per-tick reconciles (ADR-0176).
  @spec steady?(map()) :: boolean()
  defp steady?(state) do
    state.steady >= @steady_after and watched_proof?(state.watch, state.proof_target) and
      is_integer(state.last_reconcile_at) and
      System.monotonic_time(:millisecond) - state.last_reconcile_at < @steady_reconcile_ms
  end

  defp backstop_ms(state),
    do: if(watched_proof?(state.watch, state.proof_target), do: @watched_ms, else: @unwatched_ms)

  @spec running_target(
          {:running, {:ok, Watch.target()} | :error | :none}
          | {:booting, {:ok, Watch.target()} | {:error, atom()}}
          | :none
        ) :: Watch.target() | nil
  defp running_target({:running, {:ok, target}}), do: target
  defp running_target(_evidence), do: nil

  defp live_effect({:publish, row}, state, deadline) do
    _ = Lilly.Execution.publish(state.view, row, state.command, state.executor, deadline)
    state
  end

  defp live_effect({:delete, row}, state, _deadline) do
    Lilly.Execution.withdraw(state.view, row, state.command.placement_id)
    state
  end

  defp arm(state, deadline) do
    state = disarm(state)
    ref = make_ref()
    delay = max(deadline - System.monotonic_time(:millisecond), 0)
    %{state | liveness_timer: {ref, Process.send_after(self(), {:liveness_expired, ref}, delay)}}
  end

  defp disarm(state) do
    cancel_liveness_timer(state)
    %{state | liveness_timer: nil}
  end

  defp cancel_liveness_timer(%{liveness_timer: {_ref, timer}}), do: Process.cancel_timer(timer)
  defp cancel_liveness_timer(_state), do: false

  # Evidence gathered inside the observation task: the verified VMM for a
  # running result, or a boot proof while the guest is still booting.
  defp evidence(executor, context, command, {:ok, %{state: :running}}) do
    if function_exported?(executor, :watch_target, 2),
      do: {:running, executor.watch_target(context, command)},
      else: {:running, :none}
  end

  defp evidence(executor, context, command, {:retry, _reason}) do
    if function_exported?(executor, :boot_proof, 2),
      do: {:booting, executor.boot_proof(context, command)},
      else: :none
  end

  defp evidence(_executor, _context, _command, _result), do: :none

  # @cc [owner:ghuntley,label:security;recovery] boot-proof-evidence
  # A boot proof publishes roster-only authority. Lock contention
  # (:execution_unavailable) is inconclusive; any other refusal is definite
  # negative evidence and MUST revoke. A bound watcher MUST retain its actual
  # terminal report even after another observation withdrew proof; replacement
  # targets, superseding commands and actor shutdown close the old watcher.
  # Retaining a watcher with no proof MUST NOT publish or extend authority.
  # A different boot target MUST withdraw old live authority before publishing
  # only roster proof; same-target boot proof MUST NOT renew running authority.
  defp observed({:noreply, state}, {:running, target}), do: {:noreply, follow(state, target)}

  defp observed({:noreply, state}, {:booting, {:ok, target}}) do
    state =
      if state.liveness.state == :live and state.proof_target != target,
        do: liveness(state, :revoke),
        else: state

    state =
      if state.liveness.state == :live, do: state, else: %{state | proof_target: target}

    {:noreply, state |> liveness(:observed_booting) |> follow({:ok, target})}
  end

  defp observed({:noreply, state}, {:booting, {:error, :execution_unavailable}}),
    do: {:noreply, state}

  defp observed({:noreply, state}, {:booting, {:error, _reason}}),
    do: {:noreply, state |> liveness(:boot_failed) |> follow(:none)}

  defp observed({:noreply, state}, :none), do: {:noreply, follow(state, :none)}
  defp observed(stop, _evidence), do: stop

  defp follow(state, {:ok, target}) do
    cond do
      state.watch.target == target and state.watch.state in [:starting, :watching] -> state
      is_nil(state.watch_executable) or Liveness.rows(state.liveness.state) == [] -> state
      state.watch.state == :absent -> watch(state, {:start, target})
      true -> state |> watch(:stop) |> watch({:start, target})
    end
  end

  defp follow(state, _none), do: state

  # @cc [owner:ghuntley,label:security;recovery] watch-exit-revokes-live
  # A watcher report of exited, error or a port crash MUST revoke the live row
  # at once and emit vm.watch_ended; reports from any port other than the
  # current watcher MUST be ignored. A helper may exit before its queued report
  # is handled; closing that already-exited port MUST NOT terminate the actor.
  defp watch(state, event) do
    case Watch.step(state.watch, event) do
      {:ok, machine, effects} -> Enum.reduce(effects, %{state | watch: machine}, &watch_effect/2)
      {:error, :invalid_transition} -> state
    end
  end

  defp watch_effect({:open, %{pid: pid, cgroup: cgroup}}, state) do
    port =
      Port.open({:spawn_executable, state.watch_executable}, [
        :binary,
        :exit_status,
        {:line, 64},
        args: [cgroup, Integer.to_string(pid)]
      ])

    %{state | watch_port: port}
  end

  defp watch_effect(:close, %{watch_port: nil} = state), do: state

  defp watch_effect(:close, %{watch_port: port} = state) do
    try do
      Port.close(port)
    catch
      :error, :badarg -> :ok
    end

    %{state | watch_port: nil}
  end

  defp watch_effect({:revoke, reason}, state) do
    Lilly.Events.emit("vm.watch_ended",
      vm_id: state.command.vm_id,
      placement_id: state.command.placement_id,
      reason: reason
    )

    state = watch_effect(:close, state)
    {:ok, machine, _} = Watch.step(state.watch, :stop)
    liveness(%{state | watch: machine}, :revoke)
  end

  defp public(state),
    do: %{
      vm_id: state.command.vm_id,
      placement_id: state.command.placement_id,
      execution_epoch: state.command.execution_epoch,
      generation: state.command.generation,
      outcome_sequence: state.journal.sequence,
      executing: state.task != nil,
      pending_outcome: not state.journal.acknowledged,
      active: state.active
    }

  defp call(pid, message) do
    try do
      GenServer.call(pid, message, 5000)
    catch
      :exit, _ -> {:error, :terminal_unavailable}
    end
  end
end
