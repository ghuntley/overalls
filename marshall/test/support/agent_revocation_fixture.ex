defmodule Marshall.AgentRevocationFixture do
  @moduledoc "Disposable agent CLI/executor fixtures, revocation write gates and scoped row inventories."
  alias Marshall.Accounts.User
  alias Marshall.Agents.{CLIAccess, Command, Executor, ExecutorSession, Loop, ModelCall}
  alias Marshall.Agents.{ModelCalls, Root, Thread, Turn}
  alias Marshall.Compute.{Host, Ledger, Operation, Outcomes, VirtualMachine}
  alias Marshall.ComputeFixtures, as: Fixtures
  alias Marshall.JobHistoryFixture

  @type role :: :operator | :revoked
  @type fixture :: %{
          owner: User.t(),
          member: User.t(),
          vm: VirtualMachine.t(),
          root: Root.t(),
          thread: Thread.t(),
          binding: %{String.t() => String.t() | pos_integer()},
          secret: String.t(),
          code: String.t(),
          token: String.t()
        }
  @type snapshot :: %{String.t() => [[term()]]}
  @type gate_kind :: :approve | :claim | :withdraw | :retire | :register | :fail_turn
  @type outcome ::
          {:ok, term()} | {:raised, :error | :exit | :throw, term(), Exception.stacktrace()}

  @spec invoke(module(), atom(), [term()]) :: {:completed, outcome()}
  defdelegate invoke(module, function, arguments), to: JobHistoryFixture

  @spec query(String.t(), [term()]) :: Postgrex.Result.t()
  defdelegate query(sql, params \\ []), to: JobHistoryFixture

  # @cc [owner:ghuntley,label:verification] agent-revocation-real-fixture
  # Fixtures MUST compose the actual provision/observation/sharing and CLI
  # approval actions; bounding the VM to a synthetic running report is the only
  # permitted shortcut, matching the recorded executor-loss fixture authority.
  @spec setup() :: fixture()
  def setup do
    Fixtures.host_fixture()
    owner = Fixtures.user()
    member = Fixtures.user()
    {:ok, vm} = Marshall.Compute.provision(Fixtures.request(), actor: owner)
    [operation] = Ledger.read!(Operation, vm_id: vm.id)

    event = %{
      id: Ash.UUID.generate(),
      vm_id: vm.id,
      placement_id: operation.placement_id,
      execution_epoch: operation.execution_epoch,
      operation_id: operation.id,
      generation: operation.generation,
      sequence: 1,
      state: :running,
      compute_empty: false,
      disk_present: true,
      cleanup_complete: false,
      reason: :none
    }

    {:ok, parsed} =
      OverallsProtocol.Execution.outcome(OverallsProtocol.Execution.encode_outcome(event))

    {:ok, _} =
      Ledger.transaction(fn ->
        Ledger.lock!(Host, vm.host_id)
        Outcomes.ingest_locked!(vm.host_id, [parsed])
      end)

    [root] = Ledger.read!(Root, vm_id: vm.id)
    [thread] = Ledger.read!(Thread, root_id: root.id)
    {:ok, issued} = Marshall.Inference.Credentials.rotate(vm.host_id, 3600)
    secret = "overalls_agent_" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)

    fixture = %{
      owner: owner,
      member: member,
      vm: vm,
      root: root,
      thread: thread,
      binding: %{
        "host_id" => vm.host_id,
        "vm_id" => vm.id,
        "placement_id" => vm.current_placement_id,
        "execution_epoch" => vm.execution_epoch
      },
      secret: secret,
      code: Base.encode16(:crypto.hash(:sha256, secret), case: :lower),
      token: issued.id <> "." <> issued.secret
    }

    {:ok, _} = share(fixture, :operator)
    {:ok, _} = CLIAccess.approve(vm.id, fixture.code, member)
    fixture
  end

  @spec share(fixture(), role()) :: {:ok, term()} | {:error, term()}
  def share(fixture, role) do
    Marshall.Access.set_access(
      %{
        vm_id: fixture.vm.id,
        email: to_string(fixture.member.email),
        role: role,
        idempotency_key: Ash.UUID.generate()
      },
      actor: fixture.owner
    )
  end

  @spec retire_owner(User.t(), User.t()) :: term()
  def retire_owner(admin, owner) do
    User
    |> Ash.ActionInput.for_action(
      :delete_user,
      %{user_id: owner.id, confirmation: to_string(owner.email)},
      actor: admin
    )
    |> Ash.run_action()
  end

  @spec prompt(fixture(), String.t(), User.t() | nil) :: term()
  def prompt(fixture, request_key, actor \\ nil) do
    Marshall.Agents.submit_prompt(
      %{
        thread_id: fixture.thread.id,
        prompt: "perform one fixture effect",
        request_key: request_key
      },
      actor: actor || fixture.member
    )
  end

  @spec submit!(fixture()) :: Turn.t()
  def submit!(fixture) do
    {:ok, result} = prompt(fixture, Ash.UUID.generate())
    [turn] = Ledger.read!(Turn, id: result.turn_id)
    settle_context!(fixture, turn)
    turn
  end

  # Turns admit model work only after their durable context snapshot settles
  # (ADR-0178); settle it through the real executor coordinator first. Context
  # runs under the root owner's guest account, so the owner is the default.
  @spec settle_context!(fixture(), Turn.t(), User.t() | nil) :: :ok
  def settle_context!(fixture, turn, actor \\ nil) do
    turn_id = turn.id
    {:ok, %{id: ^turn_id} = started} = Marshall.Agents.TurnCoordinator.claim_next()
    Marshall.AgentContextFixtures.context_fixture(started, fixture.vm, actor || fixture.owner)
    :ok
  end

  @spec tick() :: :ok
  defdelegate tick(), to: Loop

  @spec claim_tool!(fixture(), Executor.t()) :: Command.t()
  def claim_tool!(fixture, executor) do
    {:ok, %Command{} = command} =
      ExecutorSession.claim(fixture.binding, executor.id, executor.fence_epoch)

    command
  end

  @spec complete_model!(fixture(), Turn.t()) :: :ok
  def complete_model!(fixture, turn) do
    settle_pending_context!(fixture, turn)
    {:ok, %{call: work}} = ModelCalls.claim(fixture.token)
    [%{turn_id: claimed}] = Ledger.read!(ModelCall, id: work.id)

    if claimed != turn.id do
      raise "model claim picked an unrelated fixture turn"
    end

    {:ok, _} =
      ModelCalls.complete(fixture.token, work.id, work.claim_id, %{
        "choices" => [%{"message" => %{"content" => "done"}}]
      })

    :ok
  end

  @spec turn(String.t()) :: Turn.t()
  def turn(id) do
    [%{status: _} = turn] = Ledger.read!(Turn, id: id)
    turn
  end

  # Real executors advertise context inventory; replacements must too, or a
  # turn that re-prepares context after an executor change can never settle.
  @spec register!(fixture()) :: Executor.t()
  def register!(fixture) do
    {:ok, executor} = ExecutorSession.register(fixture.binding, nil, ["context-v1"])
    executor
  end

  # A turn re-prepares context when its contributing executor changed; settle
  # that inventory through the real coordinator, then let the loop queue model work.
  @spec settle_pending_context!(fixture(), Turn.t()) :: :ok
  def settle_pending_context!(fixture, turn) do
    case Marshall.Agents.Context.prepare(turn.id) do
      {:pending, _} ->
        [current] = Ledger.read!(Turn, id: turn.id)
        Marshall.AgentContextFixtures.context_fixture(current, fixture.vm, fixture.owner)
        Loop.tick()

      _ ->
        :ok
    end
  end

  @spec queue_tool!(fixture(), Turn.t()) :: ModelCall.t()
  def queue_tool!(fixture, turn) do
    settle_pending_context!(fixture, turn)
    {:ok, %{call: work}} = ModelCalls.claim(fixture.token)
    [%{turn_id: claimed}] = Ledger.read!(ModelCall, id: work.id)

    if claimed != turn.id do
      raise "model claim picked an unrelated fixture turn"
    end

    {:ok, _} =
      ModelCalls.complete(fixture.token, work.id, work.claim_id, %{
        "status" => "completed",
        "output" => [
          %{
            "type" => "function_call",
            "call_id" => "effect",
            "name" => "exec_command",
            "arguments" => ~s({"cmd":"fixture-effect"})
          }
        ]
      })

    work
  end

  # @cc [owner:ghuntley,label:verification] agent-revocation-scoped-inventory
  # Inventories MUST project complete scoped rows through digests; command
  # arguments, prompts, results and credentials MUST NOT enter observations.
  @spec snapshot(String.t()) :: snapshot()
  def snapshot(vm_id) do
    vm = Ecto.UUID.dump!(vm_id)
    roots = "SELECT id FROM agent_roots WHERE vm_id=$1"
    threads = "SELECT id FROM agent_threads WHERE root_id IN (#{roots})"
    turns = "SELECT id FROM agent_turns WHERE thread_id IN (#{threads})"

    Map.new(
      [
        {"agent_cli_sessions", "vm_id=$1"},
        {"agent_audit_events", "vm_id=$1"},
        {"agent_executors", "vm_id=$1"},
        {"agent_roots", "vm_id=$1"},
        {"agent_threads", "root_id IN (#{roots})"},
        {"agent_turns", "id IN (#{turns})"},
        {"agent_events", "turn_id IN (#{turns})"},
        {"agent_model_calls", "turn_id IN (#{turns})"},
        {"agent_commands", "turn_id IN (#{turns})"}
      ],
      fn {table, filter} ->
        {table,
         query("SELECT to_jsonb(r) FROM #{table} r WHERE #{filter} ORDER BY id", [vm]).rows}
      end
    )
  end

  @spec observing_lease(String.t()) :: %{String.t() => String.t() | pos_integer()}
  def observing_lease(binding), do: binding

  # @cc [owner:ghuntley,label:verification] agent-revocation-real-write-gate
  # Gates MUST suspend the actual production write on the fixture's own rows
  # without adding authority; independent observers MUST see only committed rows.
  @spec install_gate(gate_kind(), map(), pos_integer()) :: :ok
  def install_gate(kind, keys, gate) do
    gate = Integer.to_string(gate)
    name = name(gate)

    {table, event, condition} =
      case kind do
        :approve ->
          {"agent_cli_sessions", "INSERT", "NEW.code_hash='#{keys[:code]}'"}

        :claim ->
          {"agent_commands", "UPDATE",
           "OLD.id='#{uuid(keys[:command_id])}' AND OLD.status='queued' " <>
             "AND NEW.status='claimed'"}

        :withdraw ->
          {"access_grants", "UPDATE",
           "NEW.user_id='#{uuid(keys[:member_id])}' AND OLD.archived_at IS NULL " <>
             "AND NEW.archived_at IS NOT NULL"}

        :retire ->
          {"users", "UPDATE",
           "NEW.id='#{uuid(keys[:owner_id])}' AND OLD.deleted_at IS NULL " <>
             "AND NEW.deleted_at IS NOT NULL"}

        :register ->
          {"agent_executors", "INSERT", "NEW.vm_id='#{uuid(keys[:vm_id])}'"}

        :fail_turn ->
          {"agent_turns", "UPDATE",
           "NEW.id='#{uuid(keys[:turn_id])}' AND OLD.status='running' AND NEW.status='failed'"}
      end

    query("""
    CREATE FUNCTION #{name}() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF #{condition} THEN PERFORM pg_advisory_xact_lock(#{gate}); END IF;
      RETURN NEW;
    END; $$
    """)

    query(
      "CREATE TRIGGER #{name} BEFORE #{event} ON #{table} FOR EACH ROW EXECUTE FUNCTION #{name}()"
    )

    :ok
  end

  @spec remove_gate(pos_integer()) :: :ok
  def remove_gate(gate) do
    name = name(Integer.to_string(gate))

    for table <- [
          "agent_cli_sessions",
          "agent_commands",
          "access_grants",
          "users",
          "agent_executors",
          "agent_turns"
        ] do
      query("DROP TRIGGER IF EXISTS #{name} ON #{table}")
    end

    query("DROP FUNCTION IF EXISTS #{name}()")
    :ok
  end

  # @cc [owner:ghuntley,label:verification] agent-revocation-complete-cleanup
  # Cleanup MUST remove the fixture's VM, agent, access, host and account rows
  # in any outcome while preserving unrelated preexisting rows; failure of
  # cleanup MUST remain visible rather than mask the original assertion.
  @spec cleanup(fixture(), [User.t()]) :: :ok
  def cleanup(fixture, extra_users \\ []) do
    vm_id = uuid(fixture.vm.id)
    roots = "SELECT id FROM agent_roots WHERE vm_id='#{vm_id}'"
    threads = "SELECT id FROM agent_threads WHERE root_id IN (#{roots})"
    turns = "SELECT id FROM agent_turns WHERE thread_id IN (#{threads})"

    for table <- [
          "agent_commands",
          "agent_model_calls",
          "agent_events"
        ] do
      query("DELETE FROM #{table} WHERE turn_id IN (#{turns})", [])
    end

    query("DELETE FROM agent_events WHERE thread_id IN (#{threads})", [])

    # Turns enqueue thread feed jobs keyed by turn and agent thread; they
    # must go before the turns, or they outlive the fixture as raw jobs.
    %{rows: feed_jobs} =
      query(
        "DELETE FROM oban_jobs WHERE args->>'turn_id' IN (SELECT id::text FROM agent_turns WHERE id IN (#{turns})) OR args->>'agent_thread_id' IN (SELECT id::text FROM agent_threads WHERE id IN (#{threads})) RETURNING id",
        []
      )

    for [job] <- feed_jobs do
      query("DELETE FROM admin_job_events WHERE job_id=$1", [job])
      query("DELETE FROM admin_job_snapshots WHERE id=$1", [job])
    end

    query("DELETE FROM agent_turns WHERE id IN (#{turns})", [])
    query("DELETE FROM agent_executors WHERE root_id IN (#{roots})", [])
    query("DELETE FROM agent_cli_sessions WHERE vm_id='#{vm_id}'", [])
    query("DELETE FROM agent_audit_events WHERE vm_id='#{vm_id}'", [])

    query("DELETE FROM agent_threads_versions WHERE version_source_id IN (#{threads})", [])
    query("DELETE FROM agent_threads WHERE root_id IN (#{roots})", [])
    query("DELETE FROM agent_roots_versions WHERE version_source_id IN (#{roots})", [])
    query("DELETE FROM agent_roots WHERE vm_id='#{vm_id}'", [])

    host_id = uuid(fixture.vm.host_id)

    query("DELETE FROM access_changes WHERE vm_id='#{vm_id}'", [])

    query(
      "DELETE FROM access_changes WHERE requested_by_id IN ('#{uuid(fixture.owner.id)}','#{uuid(fixture.member.id)}')",
      []
    )

    for user <- [fixture.owner, fixture.member] do
      id = uuid(user.id)

      query(
        "DELETE FROM access_grants_versions WHERE version_source_id IN (SELECT id FROM access_grants WHERE vm_id='#{vm_id}' OR user_id='#{id}')",
        []
      )
    end

    query("DELETE FROM access_grants WHERE vm_id='#{vm_id}'", [])

    %{rows: jobs} =
      query(
        "DELETE FROM oban_jobs WHERE args->'primary_key'->>'id' IN (SELECT id::text FROM compute_operations WHERE vm_id='#{vm_id}') RETURNING id",
        []
      )

    for [job] <- jobs do
      query("DELETE FROM admin_job_events WHERE job_id=$1", [job])
      query("DELETE FROM admin_job_snapshots WHERE id=$1", [job])
    end

    query("UPDATE compute_operations SET completion_outcome_id=NULL WHERE vm_id='#{vm_id}'", [])
    query("DELETE FROM compute_physical_outcomes WHERE vm_id='#{vm_id}'", [])

    for table <- [
          "compute_operations",
          "compute_reservations",
          "compute_network_addresses",
          "compute_lifecycle_events"
        ] do
      query("DELETE FROM #{table} WHERE vm_id='#{vm_id}'", [])
    end

    query(
      "DELETE FROM ingress_endpoints_versions WHERE version_source_id IN (SELECT id FROM ingress_endpoints WHERE vm_id='#{vm_id}')",
      []
    )

    query("DELETE FROM ingress_endpoints WHERE vm_id='#{vm_id}'", [])
    query("DELETE FROM compute_virtual_machines_versions WHERE version_source_id='#{vm_id}'", [])

    query(
      "WITH removed AS (DELETE FROM compute_workload_placements WHERE vm_id='#{vm_id}' RETURNING vm_id) DELETE FROM compute_virtual_machines WHERE id IN (SELECT vm_id FROM removed)",
      []
    )

    query(
      "DELETE FROM inference_credentials_versions WHERE version_source_id IN (SELECT id FROM inference_credentials WHERE host_id='#{host_id}')",
      []
    )

    query("DELETE FROM inference_credentials WHERE host_id='#{host_id}'", [])
    query("DELETE FROM compute_host_sessions WHERE host_id='#{host_id}'", [])
    query("DELETE FROM compute_storage_pools WHERE host_id='#{host_id}'", [])
    query("DELETE FROM compute_hosts WHERE id='#{host_id}'", [])

    Marshall.AdminAccountFixture.cleanup([fixture.owner, fixture.member | extra_users])
    :ok
  end

  @spec uuid(String.t()) :: String.t()
  defp uuid(id), do: Ecto.UUID.cast!(id)

  @spec name(String.t()) :: String.t()
  defp name(gate), do: "agent_revocation_gate_" <> gate
end
