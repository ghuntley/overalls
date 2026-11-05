defmodule Marshall.Agents.ModelCalls do
  @moduledoc "Durable single-attempt model work claimed by the current Ziggy host."
  alias Marshall.Agents.{
    AuditEvent,
    Command,
    Compaction,
    Context,
    ContextPolicy,
    Event,
    ModelCall,
    ModelProtocol,
    Planning,
    Root,
    Thread,
    Turn
  }

  alias Marshall.Compute.{Ledger, VirtualMachine}
  alias Marshall.Inference.Credentials
  require Marshall.Events

  # @cc [owner:ghuntley,label:recovery;concurrency] agent-model-one-attempt
  # A running turn may queue one model step at a time. Provider work MUST be
  # claimed and audited before Ziggy sends upstream bytes. Claimed work never
  # returns to queued after timeout, relocation or process loss.
  @spec queue(String.t(), String.t(), atom()) ::
          {:ok, ModelCall.t() | :compacted} | {:error, term()}
  def queue(turn_id, model, reasoning_effort \\ :medium) do
    Ledger.transaction(fn ->
      host_id = share_turn_host!(turn_id)
      turn = Ledger.lock!(Turn, turn_id) || Ledger.rollback(:not_found)
      thread = Ledger.lock!(Thread, turn.thread_id) || Ledger.rollback(:not_found)

      unless turn.status == :running and thread.active_turn_id == turn.id,
        do: Ledger.rollback(:stale_turn)

      [root] = Ledger.read!(Root, id: thread.root_id)
      vm = Ledger.lock!(VirtualMachine, root.vm_id) || Ledger.rollback(:machine_unavailable)
      unless vm.host_id == host_id, do: Ledger.rollback(:machine_unavailable)

      unless vm.desired_state == :running and vm.observed_state == :running and
               vm.archived_at == nil,
             do: Ledger.rollback(:machine_unavailable)

      # An image whose agent set has no executor cannot run tools.
      unless Marshall.Compute.Images.guest_capabilities(vm.image_id).agents,
        do: Ledger.rollback(:machine_unavailable)

      calls = Ledger.read!(ModelCall, turn_id: turn.id)

      if Enum.any?(calls, &(&1.status in [:queued, :claimed])),
        do: Ledger.rollback(:already_queued)

      commands = Ledger.read!(Command, turn_id: turn.id)

      if Enum.any?(commands, &(&1.status in [:queued, :claimed, :started])),
        do: Ledger.rollback(:waiting_for_tools)

      if Planning.awaiting?(thread.id), do: Ledger.rollback(:waiting_for_answers)
      iteration = Enum.reduce(calls, 0, &max(&1.iteration, &2)) + 1
      inference_count = Enum.count(calls, &(&1.purpose == :inference))
      compaction_count = length(calls) - inference_count
      if iteration > 72, do: Ledger.rollback(:iteration_limit)

      projection =
        case Context.project(thread, turn) do
          {:ok, projection} -> projection
          {:error, reason} -> Ledger.rollback(reason)
        end

      options = projection_options(thread, turn, projection)

      request =
        case ModelProtocol.project(
               projection.events,
               model,
               vm.profile,
               Marshall.Compute.Images.guest_platform(vm.image_id),
               reasoning_effort,
               options
             ) do
          {:ok, body} -> body
          {:error, reason} -> Ledger.rollback(reason)
        end

      previous = Enum.max_by(calls, & &1.iteration, fn -> nil end)

      recovery? =
        previous && previous.status == :failed &&
          Compaction.failure_reason(previous.response) in [
            :context_limit_exceeded,
            :native_compaction_unavailable
          ]

      manual? =
        (turn.maintenance_kind == :compact_context and compaction_count == 0) or recovery? == true

      policy = Application.get_env(:marshall, :agent_context_policy, %{})

      native? =
        ContextPolicy.native_compaction_verified?(policy, :openai, model) and
          not Enum.any?(calls, &(&1.purpose == :native and &1.status == :failed))

      {purpose, request, metadata} =
        case Compaction.next(request,
               manual: manual?,
               token_limit: Map.get(policy, :input_token_limit),
               native_verified?: native?
             ) do
          {:inference, body} ->
            if inference_count >= 64, do: Ledger.rollback(:iteration_limit)

            {if(turn.maintenance_kind == :compact_context,
               do: :maintenance_done,
               else: :inference
             ), body, %{}}

          {:compact, plan} ->
            if compaction_count >= 8, do: Ledger.rollback(:compaction_no_progress)

            metadata = %{
              "snapshot_id" => projection.snapshot.id,
              "expected_generation" =>
                if(projection.checkpoint, do: projection.checkpoint.generation, else: 0),
              "frontier" =>
                Map.new(projection.frontier, fn {key, value} -> {Atom.to_string(key), value} end),
              "retained_input" => plan.retained_input,
              "source_digest" => plan.source_digest,
              "source_bytes" => plan.source_bytes,
              "source_items" => plan.source_items
            }

            {plan.kind, plan.request, metadata}

          {:error, reason} ->
            Ledger.rollback(reason)
        end

      if purpose == :maintenance_done do
        {:ok, _} =
          Marshall.Agents.TurnCoordinator.finish(turn.id, :completed, "Context compacted.")

        :compacted
      else
        Ledger.create!(ModelCall, :queue, %{
          root_id: root.id,
          thread_id: thread.id,
          turn_id: turn.id,
          iteration: iteration,
          host_id: vm.host_id,
          placement_id: vm.current_placement_id,
          execution_epoch: vm.execution_epoch,
          request: request,
          purpose: purpose,
          context_metadata: metadata
        })
      end
    end)
  end

  # @cc [owner:ghuntley,label:concurrency] model-call-queue-host-before-vm
  # Host-authenticated calls lock the host and then the VM (ADR-0019). The
  # queued ModelCall references the host, so its insert takes a host key-share
  # lock. Queueing MUST take that host lock before the Turn, Thread and VM locks,
  # resolving the host from unlocked reads, and MUST refuse if the locked VM is
  # no longer on that host; a VM-then-host order deadlocks with a host fence.
  @spec share_turn_host!(String.t()) :: String.t()
  defp share_turn_host!(turn_id) do
    [turn] = Ledger.read!(Turn, id: turn_id) |> found!()
    [thread] = Ledger.read!(Thread, id: turn.thread_id) |> found!()
    [root] = Ledger.read!(Root, id: thread.root_id)

    case Ledger.read!(VirtualMachine, id: root.vm_id) do
      [%VirtualMachine{host_id: host_id}] when is_binary(host_id) ->
        Ledger.share_host!(host_id) || Ledger.rollback(:machine_unavailable)
        host_id

      _ ->
        Ledger.rollback(:machine_unavailable)
    end
  end

  @spec found!([record]) :: [record] when record: Ash.Resource.Record.t()
  defp found!([_] = rows), do: rows
  defp found!(_), do: Ledger.rollback(:not_found)

  @spec projection_options(Thread.t(), Turn.t(), Context.projection()) :: keyword()
  defp projection_options(thread, turn, projection) do
    checkpoint = projection.checkpoint

    [
      collaboration_mode: turn.collaboration_mode,
      child?: thread.parent_thread_id != nil,
      instructions:
        projection.snapshot.instructions ++
          [
            "Current working directory: " <> projection.snapshot.working_directory,
            Marshall.Accounts.GitSettings.instruction(projection.snapshot.configuration_owner_id)
          ],
      checkpoint: if(checkpoint, do: checkpoint.state),
      retained_input: if(checkpoint, do: checkpoint.retained_input, else: [])
    ]
  end

  @doc "Read-only context estimate; the caller must authorize the enclosing thread."
  @spec context_usage(Thread.t()) :: {:ok, Compaction.measurement()} | {:error, atom()}
  def context_usage(thread) do
    turn =
      if thread.active_turn_id,
        do: List.first(Ledger.read!(Turn, id: thread.active_turn_id)),
        else: Ledger.read!(Turn, thread_id: thread.id) |> Enum.max_by(& &1.ordinal, fn -> nil end)

    with %Turn{} <- turn,
         [root] <- Ledger.read!(Root, id: thread.root_id),
         [vm] <- Ledger.read!(VirtualMachine, id: root.vm_id),
         {:ok, projection} <- Context.project(thread, turn),
         {:ok, body} <-
           ModelProtocol.project(
             projection.events,
             Marshall.Threads.Mode.model(turn.mode),
             vm.profile,
             Marshall.Compute.Images.guest_platform(vm.image_id),
             Marshall.Threads.Mode.reasoning_effort(turn.mode),
             projection_options(thread, turn, projection)
           ) do
      policy = Application.get_env(:marshall, :agent_context_policy, %{})
      {:ok, Compaction.measure(body, token_limit: Map.get(policy, :input_token_limit))}
    else
      _ -> {:error, :context_unavailable}
    end
  end

  @spec claim(binary()) :: {:ok, map()} | {:error, term()}
  def claim(token) do
    Ledger.transaction(fn ->
      authority = Credentials.authenticate_locked!(token)

      %{rows: rows} =
        Ecto.Adapters.SQL.query!(
          Marshall.Repo,
          """
          SELECT m.id FROM agent_model_calls AS m
          JOIN agent_turns AS t ON t.id = m.turn_id AND t.thread_id = m.thread_id
          JOIN agent_threads AS th ON th.id = m.thread_id AND th.root_id = m.root_id
          JOIN agent_roots AS r ON r.id = m.root_id
          JOIN compute_virtual_machines AS vm ON vm.id = r.vm_id
          JOIN compute_workload_placements AS p ON p.id = vm.current_placement_id
          WHERE m.host_id = $1 AND m.status = 'queued'
            AND p.host_id = m.host_id AND vm.current_placement_id = m.placement_id
            AND vm.execution_epoch = m.execution_epoch
            AND vm.desired_state = 'running' AND vm.observed_state = 'running'
            AND vm.archived_at IS NULL AND t.status = 'running'
            AND th.active_turn_id = t.id
          ORDER BY m.inserted_at, m.id
          LIMIT 1 FOR UPDATE OF m SKIP LOCKED
          """,
          [Ecto.UUID.dump!(authority.host_id)],
          log: false
        )

      case rows do
        [] ->
          %{call: nil}

        [[raw_id]] ->
          call = Ledger.lock!(ModelCall, Ecto.UUID.load!(raw_id))
          [root] = Ledger.read!(Root, id: call.root_id)
          vm = Ledger.lock!(VirtualMachine, root.vm_id) || Ledger.rollback(:stale_execution)
          [turn] = Ledger.read!(Turn, id: call.turn_id)
          [thread] = Ledger.read!(Thread, id: call.thread_id)
          actor = Marshall.Accounts.Security.current(turn.actor_id)

          unless vm.host_id == authority.host_id and
                   vm.current_placement_id == call.placement_id and
                   vm.execution_epoch == call.execution_epoch and
                   vm.desired_state == :running and vm.observed_state == :running and
                   vm.archived_at == nil and turn.status == :running and
                   thread.active_turn_id == turn.id and
                   match?(%Marshall.Accounts.User{deleted_at: nil, active: true}, actor) and
                   Marshall.Access.Authorization.allowed?(vm, actor, "write"),
                 do: Ledger.rollback(:stale_execution)

          options = [
            collaboration_mode: turn.collaboration_mode,
            child?: thread.parent_thread_id != nil
          ]

          allowed? =
            case call.purpose do
              :inference ->
                ModelProtocol.request_tools_allowed?(call.request, vm.profile, options)

              :summary ->
                Compaction.request_allowed?(call.request, :summary)

              :native ->
                native_compaction_enabled?(call.request) and
                  Compaction.request_allowed?(call.request, :native)
            end

          if allowed? do
            claim_allowed!(call, vm, thread, turn)
          else
            cancel_disallowed!(call, vm, thread, turn)
            %{call: nil}
          end
      end
    end)
  end

  defp claim_allowed!(call, vm, thread, turn) do
    claim_id = Ash.UUID.generate()

    claimed =
      Ledger.update!(call, :transition, %{
        status: :claimed,
        claim_id: claim_id,
        claimed_at: Ledger.now()
      })

    Ledger.create!(AuditEvent, :record, %{
      vm_id: vm.id,
      thread_id: thread.id,
      turn_id: turn.id,
      kind: :model_dispatched,
      target_id: call.id,
      outcome: :accepted
    })

    Ledger.after_commit(fn ->
      Marshall.Events.emit("agent.model_claimed", vm_id: vm.id, call_id: call.id)
    end)

    %{
      call: %{
        id: claimed.id,
        claim_id: claim_id,
        binding: %{
          host_id: vm.host_id,
          vm_id: vm.id,
          placement_id: vm.current_placement_id,
          execution_epoch: vm.execution_epoch
        },
        request: claimed.request
      }
    }
  end

  @spec native_compaction_enabled?(term()) :: boolean()
  defp native_compaction_enabled?(%{"model" => model}) when is_binary(model) do
    policy = Application.get_env(:marshall, :agent_context_policy, %{})
    ContextPolicy.native_compaction_verified?(policy, :openai, model)
  end

  defp native_compaction_enabled?(_), do: false

  # @cc [owner:ghuntley,label:security;recovery] agent-queued-model-current-capabilities
  # A queued model request created under an earlier policy MUST NOT advertise
  # removed tools after rollout. Queued native maintenance MUST also be
  # cancelled when the current deployment no longer verifies native support.
  # Cancel disallowed work durably before Ziggy can claim it.
  defp cancel_disallowed!(call, vm, thread, turn) do
    Ledger.update!(call, :transition, %{
      status: :cancelled,
      response: %{"reason" => "capability_denied"},
      finished_at: Ledger.now()
    })

    Ledger.create!(AuditEvent, :record, %{
      vm_id: vm.id,
      thread_id: thread.id,
      turn_id: turn.id,
      kind: :model_finished,
      target_id: call.id,
      outcome: :failed
    })

    Ledger.after_commit(fn ->
      Marshall.Events.emit("agent.model_finished",
        vm_id: vm.id,
        call_id: call.id,
        outcome: :failed
      )
    end)
  end

  @spec complete(binary(), String.t(), String.t(), term()) :: {:ok, map()} | {:error, term()}
  def complete(token, call_id, claim_id, response)
      when is_map(response) and is_binary(call_id) and is_binary(claim_id) do
    with true <- OverallsProtocol.uuid?(call_id) and OverallsProtocol.uuid?(claim_id),
         true <- byte_size(Jason.encode!(response)) <= 1_048_576 do
      Ledger.transaction(fn -> complete_locked!(token, call_id, claim_id, response) end)
    else
      _ -> {:error, :invalid_request}
    end
  end

  def complete(_, _, _, _), do: {:error, :invalid_request}

  defp complete_locked!(token, call_id, claim_id, response) do
    authority = Credentials.authenticate_locked!(token)
    candidate = List.first(Ledger.read!(ModelCall, id: call_id)) || Ledger.rollback(:not_found)
    turn = Ledger.lock!(Turn, candidate.turn_id) || Ledger.rollback(:not_found)
    thread = Ledger.lock!(Thread, candidate.thread_id) || Ledger.rollback(:not_found)
    call = Ledger.lock!(ModelCall, call_id) || Ledger.rollback(:not_found)

    unless call.host_id == authority.host_id and call.claim_id == claim_id,
      do: Ledger.rollback(:stale_claim)

    cond do
      call.status in [:completed, :failed, :uncertain] and call.response == response ->
        %{acknowledged: call.id}

      call.status != :claimed or turn.status != :running or thread.active_turn_id != turn.id ->
        Ledger.rollback(:stale_claim)

      true ->
        apply_response!(call, turn, thread, response)
    end
  end

  defp apply_response!(call, turn, thread, response) do
    [root] = Ledger.read!(Root, id: call.root_id)
    vm = Ledger.lock!(VirtualMachine, root.vm_id) || Ledger.rollback(:machine_unavailable)

    outcome =
      case call.purpose do
        :inference ->
          ModelProtocol.parse_response(response, vm.profile,
            collaboration_mode: turn.collaboration_mode,
            child?: thread.parent_thread_id != nil
          )

        kind ->
          Compaction.parse_response(response, kind)
      end

    current_binding? =
      vm.host_id == call.host_id and vm.current_placement_id == call.placement_id and
        vm.execution_epoch == call.execution_epoch

    status =
      cond do
        not current_binding? -> :uncertain
        match?({:ok, _}, outcome) -> :completed
        true -> :failed
      end

    Ledger.update!(call, :transition, %{
      status: status,
      response: response,
      finished_at: Ledger.now()
    })

    Ledger.create!(AuditEvent, :record, %{
      vm_id: vm.id,
      thread_id: thread.id,
      turn_id: turn.id,
      kind: :model_finished,
      target_id: call.id,
      outcome: status
    })

    actor = Marshall.Accounts.Security.current(turn.actor_id)

    cond do
      not current_binding? ->
        {:ok, _} =
          Marshall.Agents.TurnCoordinator.finish(turn.id, :failed, :machine_unavailable)

      not match?(%Marshall.Accounts.User{deleted_at: nil, active: true}, actor) or
          not Marshall.Access.Authorization.allowed?(vm, actor, "write") ->
        {:ok, _} = Marshall.Agents.TurnCoordinator.finish(turn.id, :failed, :access_revoked)

      vm.desired_state != :running or vm.observed_state != :running ->
        {:ok, _} =
          Marshall.Agents.TurnCoordinator.finish(turn.id, :failed, :machine_unavailable)

      call.purpose != :inference and match?({:ok, _}, outcome) ->
        {:ok, state} = outcome
        install_compaction!(call, turn, thread, state)

      recoverable_rejection?(call, response) ->
        :ok

      transient_provider_failure?(call, response) ->
        Ledger.update!(call, :transition, %{
          status: :queued,
          response: nil,
          finished_at: nil,
          claim_id: nil,
          claimed_at: nil
        })

        :ok

      match?({:ok, {:assistant, _}}, outcome) ->
        {:ok, {:assistant, text}} = outcome
        record_output!(thread, turn, response)
        {:ok, _} = Marshall.Agents.TurnCoordinator.finish(turn.id, :completed, text)

      match?({:ok, {:tools, _}}, outcome) ->
        {:ok, {:tools, calls}} = outcome
        thread = record_output!(thread, turn, response)
        queue_tools!(call, turn, thread, vm, calls)

      match?({:error, :capability_denied}, outcome) ->
        {:ok, _} = Marshall.Agents.TurnCoordinator.finish(turn.id, :failed, :capability_denied)

      true ->
        {:ok, _} = Marshall.Agents.TurnCoordinator.finish(turn.id, :failed, :provider_failed)
    end

    Ledger.after_commit(fn ->
      Marshall.Events.emit("agent.model_finished",
        vm_id: vm.id,
        call_id: call.id,
        outcome: status
      )
    end)

    %{acknowledged: call.id}
  end

  @doc false
  @spec retryable_provider_response?(atom(), pos_integer(), map()) :: boolean()
  def retryable_provider_response?(purpose, iteration, response)
      when is_atom(purpose) and is_integer(iteration) and is_map(response) do
    purpose == :inference and iteration < 3 and
      get_in(response, ["error"]) in ["upstream_failed", "server_is_overloaded"]
  end

  def retryable_provider_response?(_, _, _), do: false

  @spec transient_provider_failure?(ModelCall.t(), map()) :: boolean()
  defp transient_provider_failure?(%ModelCall{purpose: purpose, iteration: iteration}, response) do
    retryable_provider_response?(purpose, iteration, response)
  end

  @spec recoverable_rejection?(ModelCall.t(), map()) :: boolean()
  defp recoverable_rejection?(call, response) do
    Compaction.failure_reason(response) == :context_limit_exceeded or
      (call.purpose == :native and
         Compaction.failure_reason(response) == :native_compaction_unavailable)
  end

  # @cc [owner:ghuntley,label:recovery] model-compaction-install-complete-once
  # A maintenance result MUST replace context only after verified completion and
  # strict progress, under its original snapshot and captured turn frontier.
  # Raw transcript events MUST remain intact and continuation must not replay
  # a claimed provider attempt.
  @spec install_compaction!(ModelCall.t(), Turn.t(), Thread.t(), map()) :: term()
  defp install_compaction!(call, turn, thread, state) do
    metadata = call.context_metadata
    plan = %{source_bytes: metadata["source_bytes"], source_items: metadata["source_items"]}
    snapshot = Context.snapshot(turn.id)

    if (snapshot && snapshot.id == metadata["snapshot_id"]) and is_map(state) and
         Compaction.progress?(plan, state) do
      frontier = metadata["frontier"]

      checkpoint =
        Context.install_checkpoint!(turn, snapshot, %{
          expected_generation: metadata["expected_generation"],
          frontier: %{
            turn_id: frontier["turn_id"],
            turn_ordinal: frontier["turn_ordinal"],
            sequence: frontier["sequence"]
          },
          state: state,
          retained_input: metadata["retained_input"],
          source_digest: metadata["source_digest"]
        })

      Ledger.create!(Event, :append, %{
        thread_id: thread.id,
        turn_id: turn.id,
        sequence: thread.next_event_sequence,
        kind: :context_compacted,
        body: %{"checkpoint_id" => checkpoint.id, "kind" => Atom.to_string(call.purpose)}
      })

      Ledger.update!(thread, :advance, %{next_event_sequence: thread.next_event_sequence + 1})

      if turn.maintenance_kind == :compact_context do
        Marshall.Agents.TurnCoordinator.finish(turn.id, :completed, "Context compacted.")
      end

      checkpoint
    else
      Marshall.Agents.TurnCoordinator.finish(turn.id, :failed, :compaction_no_progress)
    end
  end

  # @cc [owner:ghuntley,label:security;recovery] agent-reasoning-private-replay
  # Completed Responses output, including encrypted reasoning, MUST be retained
  # in authorized thread state for stateless continuation, never in diagnostics.
  defp record_output!(thread, turn, response) do
    case ModelProtocol.replay_output(response) do
      {:ok, output} ->
        Ledger.create!(Event, :append, %{
          thread_id: thread.id,
          turn_id: turn.id,
          sequence: thread.next_event_sequence,
          kind: :model_output,
          body: %{"output" => output}
        })

        Ledger.update!(thread, :advance, %{
          next_event_sequence: thread.next_event_sequence + 1
        })

      _ ->
        thread
    end
  end

  defp queue_tools!(call, turn, thread, vm, calls) do
    Marshall.Compute.Idle.touch_locked!(vm)
    {questions, calls} = Enum.split_with(calls, &(&1.tool == :request_user_input))
    {command_calls, child_calls} = Enum.split_with(calls, &(&1.tool != :spawn_child_agent))

    Enum.each(command_calls, fn item ->
      Command
      |> Ledger.create!(:queue, %{
        root_id: call.root_id,
        thread_id: thread.id,
        turn_id: call.turn_id,
        call_id: item.id,
        tool: item.tool,
        arguments: command_arguments(item, turn)
      })
      |> Marshall.Agents.ServerToolJob.enqueue!()
    end)

    Ledger.create!(Event, :append, %{
      thread_id: thread.id,
      turn_id: call.turn_id,
      sequence: thread.next_event_sequence,
      kind: :tool_queued,
      body: %{
        "calls" =>
          Enum.map(calls, fn item ->
            %{
              "call_id" => item.id,
              "tool" => Atom.to_string(item.tool),
              "arguments" => item.arguments
            }
          end)
      }
    })

    next_sequence =
      Enum.reduce(child_calls, thread.next_event_sequence + 1, fn item, sequence ->
        child =
          Ledger.create!(Thread, :open, %{
            root_id: call.root_id,
            parent_thread_id: thread.id,
            title: item.arguments["title"],
            created_by_id: turn.actor_id,
            mode: turn.mode,
            collaboration_mode: turn.collaboration_mode,
            working_directory: Context.snapshot(turn.id).working_directory,
            selected_skills: turn.selected_skills
          })

        key =
          :crypto.hash(:sha256, call.id <> ":" <> item.id)
          |> Base.encode16(case: :lower)

        child_turn =
          Ledger.create!(Turn, :enqueue, %{
            thread_id: child.id,
            actor_id: turn.actor_id,
            request_key: key,
            ordinal: 1,
            prompt: item.arguments["prompt"],
            mode: turn.mode,
            collaboration_mode: turn.collaboration_mode,
            working_directory: Context.snapshot(turn.id).working_directory,
            configuration_owner_id: turn.configuration_owner_id,
            selected_skills: turn.selected_skills
          })

        Ledger.create!(Event, :append, %{
          thread_id: child.id,
          turn_id: child_turn.id,
          sequence: 1,
          kind: :prompt,
          body: %{"prompt" => item.arguments["prompt"]}
        })

        Ledger.update!(child, :advance, %{next_event_sequence: 2})

        Ledger.create!(Event, :append, %{
          thread_id: thread.id,
          turn_id: turn.id,
          sequence: sequence,
          kind: :child_spawned,
          body: %{
            "call_id" => item.id,
            "child_thread_id" => child.id,
            "child_turn_id" => child_turn.id
          }
        })

        Ledger.create!(AuditEvent, :record, %{
          vm_id: vm.id,
          thread_id: child.id,
          turn_id: child_turn.id,
          actor_id: turn.actor_id,
          kind: :child_created,
          target_id: child.id,
          outcome: :accepted
        })

        Ledger.create!(AuditEvent, :record, %{
          vm_id: vm.id,
          thread_id: child.id,
          turn_id: child_turn.id,
          actor_id: turn.actor_id,
          kind: :prompt_admitted,
          target_id: child_turn.id,
          outcome: :accepted
        })

        Ledger.after_commit(fn ->
          Marshall.Events.emit("agent.child_created",
            vm_id: vm.id,
            thread_id: child.id,
            parent_thread_id: thread.id
          )
        end)

        sequence + 1
      end)

    thread = Ledger.update!(thread, :advance, %{next_event_sequence: next_sequence})
    Enum.each(questions, &Planning.request_questions_locked!(thread, turn, &1))
  end

  @spec command_arguments(ModelProtocol.call(), Turn.t()) :: map()
  defp command_arguments(%{tool: :exec_command, arguments: arguments}, turn) do
    Map.put_new(arguments, "workdir", Context.snapshot(turn.id).working_directory)
  end

  defp command_arguments(%{arguments: arguments}, _turn), do: arguments

  # Called with the turn transaction open. Queued work has never reached a
  # provider, so relocation may cancel it without risking a repeated effect.
  @spec cancel_queued!(Turn.t(), VirtualMachine.t(), [ModelCall.t()]) :: :ok
  def cancel_queued!(turn, vm, calls) do
    Enum.each(calls, fn call ->
      if call.status == :queued do
        call = Ledger.lock!(ModelCall, call.id)

        if call.status == :queued do
          Ledger.update!(call, :transition, %{status: :cancelled, finished_at: Ledger.now()})

          Ledger.create!(AuditEvent, :record, %{
            vm_id: vm.id,
            thread_id: call.thread_id,
            turn_id: turn.id,
            kind: :model_finished,
            target_id: call.id,
            outcome: :failed
          })

          Ledger.after_commit(fn ->
            Marshall.Events.emit("agent.model_finished",
              vm_id: vm.id,
              call_id: call.id,
              outcome: :failed
            )
          end)
        end
      end
    end)

    :ok
  end

  # @cc [owner:ghuntley,label:recovery] agent-model-claimed-timeout-uncertain
  # A claimed provider attempt that disappears cannot be retried. Mark it
  # uncertain and fail the active turn after the bounded execution window.
  @spec reap() :: :ok
  def reap do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        Marshall.Repo,
        """
        SELECT id FROM agent_model_calls
        WHERE status = 'claimed' AND claimed_at < now() - interval '10 minutes'
        ORDER BY claimed_at, id LIMIT 128
        """,
        [],
        log: false
      )

    Enum.each(rows, fn [raw_id] -> reap_one(Ecto.UUID.load!(raw_id)) end)
    :ok
  end

  defp reap_one(id) do
    Ledger.transaction(fn ->
      candidate = List.first(Ledger.read!(ModelCall, id: id))

      if candidate && candidate.status == :claimed do
        turn = Ledger.lock!(Turn, candidate.turn_id)
        thread = Ledger.lock!(Thread, candidate.thread_id)
        call = Ledger.lock!(ModelCall, id)

        if call.status == :claimed and
             DateTime.compare(call.claimed_at, DateTime.add(Ledger.now(), -600, :second)) == :lt do
          [root] = Ledger.read!(Root, id: call.root_id)

          Ledger.update!(call, :transition, %{
            status: :uncertain,
            finished_at: Ledger.now(),
            response: %{"error" => "result_lost"}
          })

          Ledger.create!(AuditEvent, :record, %{
            vm_id: root.vm_id,
            thread_id: call.thread_id,
            turn_id: call.turn_id,
            kind: :model_finished,
            target_id: call.id,
            outcome: :uncertain
          })

          if (turn && thread && turn.status == :running) and thread.active_turn_id == turn.id,
            do: Marshall.Agents.TurnCoordinator.finish(turn.id, :failed, :provider_failed)

          Ledger.after_commit(fn ->
            Marshall.Events.emit("agent.model_finished",
              vm_id: root.vm_id,
              call_id: call.id,
              outcome: :uncertain
            )
          end)
        end
      end
    end)
  end
end
