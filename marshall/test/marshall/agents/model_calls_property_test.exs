defmodule Marshall.Agents.ModelCallsPropertyTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen

  alias Marshall.Accounts.User
  alias Marshall.Agents

  alias Marshall.Agents.{
    AuditEvent,
    Event,
    Executor,
    ExecutorSession,
    Loop,
    ModelCall,
    ModelCalls
  }

  alias Marshall.Agents.{Root, Thread, Turn, TurnCoordinator}
  alias Marshall.Compute.{Ledger, VirtualMachine}
  alias Marshall.Inference.{Credentials, Request, Requests}

  @type fixture :: %{
          owner: User.t(),
          vm: VirtualMachine.t(),
          turn: Turn.t(),
          token: String.t()
        }
  @type work :: %{id: String.t(), claim_id: String.t()}

  @overload %{"error" => "retryable_overload"}
  @answer %{"choices" => [%{"message" => %{"content" => "A fixture joke."}}]}
  @accounting %{
    "outcome" => "upstream_error",
    "completeness" => "unknown",
    "tokens" => %{},
    "cost_estimate" => nil
  }

  # @cc [owner:ghuntley,label:verification;recovery] agent-overload-retained-history
  # Generated histories MUST exercise the real SQL-backed queue, claim,
  # inference admission, completion and scheduler. Every safe retry needs a
  # distinct UUIDv7 accepted by admission, immutable failed receipts and bounded
  # backoff; terminal failures and exhausted budgets must never admit more work.
  @tag hegel_case_sandbox: true, timeout: 240_000
  property "safe overload retries retain attempts and fresh admission survives repeated polls",
    test_cases: 100 do
    :ok = isolate_property_case()
    prefix_steps = draw("successful_steps", integer(0..2))
    overloads = draw("consecutive_overloads", integer(0..3))
    polls = draw("duplicate_polls", integer(1..3))

    ending =
      draw(
        "ending",
        member_of([
          :success,
          :lost,
          "upstream_failed",
          "server_is_overloaded",
          "no_accounts",
          "pool_exhausted",
          "insufficient_quota"
        ])
      )

    c = fixture()
    repeat(prefix_steps, fn -> complete_tool_step(c) end)
    repeat(overloads, fn -> complete_overload(c, polls) end)

    if overloads < 3 do
      work = claim_and_admit(c)

      case ending do
        :success ->
          complete(c, work, @answer)
          assert [%{status: :completed}] = Ledger.read!(Turn, id: c.turn.id)

        :lost ->
          [call] = Ledger.read!(ModelCall, id: work.id)

          Ledger.update!(call, :transition, %{
            claimed_at: DateTime.add(Ledger.now(), -601, :second)
          })

          assert :ok = ModelCalls.reap()
          assert [%{status: :uncertain}] = Ledger.read!(ModelCall, id: work.id)

        error ->
          complete(c, work, %{"error" => error})
      end
    end

    expected_count = prefix_steps + overloads + if(overloads == 3, do: 0, else: 1)
    assert length(calls(c)) == expected_count

    if overloads == 3 or ending != :success do
      assert [%{status: :failed, failure_reason: :provider_failed}] =
               Ledger.read!(Turn, id: c.turn.id)

      assert [] = Ledger.read!(Event, turn_id: c.turn.id, kind: :assistant)
    else
      assert [%{body: %{"text" => "A fixture joke."}}] =
               Ledger.read!(Event, turn_id: c.turn.id, kind: :assistant)
    end

    history = calls(c)
    repeat(polls, fn -> assert :ok = Loop.tick() end)
    assert calls(c) == history
    assert {:ok, %{call: nil}} = ModelCalls.claim(c.token)
    assert length(Ledger.read!(Request, vm_id: c.vm.id)) == expected_count
    assert length(Enum.uniq_by(history, & &1.id)) == expected_count
    assert Enum.all?(history, &(String.at(&1.id, 14) == "7"))

    for call <- history do
      assert [_] = Ledger.read!(AuditEvent, target_id: call.id, kind: :model_dispatched)
      assert [_] = Ledger.read!(AuditEvent, target_id: call.id, kind: :model_finished)
    end
  end

  test "a successful tool step resets the consecutive retry budget" do
    c = fixture()
    complete_overload(c, 1)
    complete_overload(c, 1)
    complete_tool_step(c)
    complete_overload(c, 1)
    complete_overload(c, 1)
    complete(c, claim_and_admit(c), @answer)
    assert [%{status: :completed}] = Ledger.read!(Turn, id: c.turn.id)
    assert length(calls(c)) == 6
  end

  test "a completed maintenance call ends the previous overload streak" do
    c = fixture()
    complete_overload(c, 1)
    complete_overload(c, 1)
    work = claim_and_admit(c)

    # Seed the durable maintenance boundary; CompactionModelCallsTest exercises
    # actual installation and progress. This case checks subsequent accounting.
    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      "UPDATE agent_model_calls SET purpose = 'summary', status = 'completed', response = $2, finished_at = clock_timestamp() WHERE id = $1",
      [Ecto.UUID.dump!(work.id), @answer],
      log: false
    )

    assert :ok = Loop.tick()
    complete_overload(c, 1)
    complete_overload(c, 1)
    complete(c, claim_and_admit(c), @answer)
    assert [%{status: :completed}] = Ledger.read!(Turn, id: c.turn.id)
  end

  test "a claimed safe-overload result remains uncertain after execution changes" do
    c = fixture()
    work = claim_and_admit(c)

    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      "UPDATE compute_virtual_machines SET execution_epoch = execution_epoch + 1 WHERE id = $1",
      [Ecto.UUID.dump!(c.vm.id)],
      log: false
    )

    complete(c, work, @overload)
    assert :ok = Loop.tick()
    assert [%{status: :uncertain}] = calls(c)

    assert [%{status: :failed, failure_reason: :machine_unavailable}] =
             Ledger.read!(Turn, id: c.turn.id)
  end

  for purpose <- [:summary, :native] do
    @tag purpose: purpose
    test "#{purpose} maintenance overloads are terminal", %{purpose: purpose} do
      c = fixture()
      work = claim_and_admit(c)

      Ecto.Adapters.SQL.query!(
        Marshall.Repo,
        "UPDATE agent_model_calls SET purpose = $2 WHERE id = $1",
        [Ecto.UUID.dump!(work.id), Atom.to_string(purpose)],
        log: false
      )

      complete(c, work, @overload)
      assert :ok = Loop.tick()
      assert [%{status: :failed}] = calls(c)

      assert [%{status: :failed, failure_reason: :provider_failed}] =
               Ledger.read!(Turn, id: c.turn.id)
    end
  end

  test "an overload marker with additional response content cannot authorize retry" do
    c = fixture()
    complete(c, claim_and_admit(c), Map.put(@overload, "output", []))
    assert :ok = Loop.tick()
    assert [%{status: :failed}] = calls(c)

    assert [%{status: :failed, failure_reason: :provider_failed}] =
             Ledger.read!(Turn, id: c.turn.id)
  end

  @spec fixture() :: fixture()
  defp fixture do
    c = Marshall.TerminalFixtures.terminal_fixture(%{profile: :standard})
    [root] = Ledger.read!(Root, vm_id: c.vm.id)
    [thread] = Ledger.read!(Thread, root_id: root.id)
    {:ok, issued} = Credentials.rotate(c.vm.host_id, 3600)

    assert {:ok, %{turn_id: id}} =
             Agents.submit_prompt(
               %{
                 thread_id: thread.id,
                 prompt: "tell me a joke",
                 request_key: Ash.UUID.generate()
               },
               actor: c.owner
             )

    assert {:ok, %{id: ^id} = turn} = TurnCoordinator.claim_next()
    Marshall.AgentContextFixtures.context_fixture(turn, c.vm, c.owner)
    assert {:ok, _} = ModelCalls.queue(turn.id, "gpt-6-sol")
    %{owner: c.owner, vm: c.vm, turn: turn, token: issued.id <> "." <> issued.secret}
  end

  @spec calls(fixture()) :: [ModelCall.t()]
  defp calls(c), do: Ledger.read!(ModelCall, turn_id: c.turn.id) |> Enum.sort_by(& &1.iteration)

  @spec claim_and_admit(fixture()) :: work()
  defp claim_and_admit(c) do
    assert {:ok, %{call: %{id: id} = work}} = ModelCalls.claim(c.token)
    assert {:ok, %{call: nil}} = ModelCalls.claim(c.token)

    admission = %{
      "request_id" => id,
      "host_id" => c.vm.host_id,
      "vm_id" => c.vm.id,
      "placement_id" => c.vm.current_placement_id,
      "execution_epoch" => c.vm.execution_epoch,
      "provider" => "openai",
      "model" => "gpt-6-sol",
      "operation" => "responses"
    }

    assert {:ok, %{request_id: ^id}} = Requests.admit(c.token, admission)
    assert {:error, :duplicate_request} = Requests.admit(c.token, admission)
    work
  end

  @spec complete(fixture(), work(), map()) :: :ok
  defp complete(c, work, response) do
    assert {:ok, _} = Requests.complete(c.token, work.id, @accounting)

    assert {:ok, %{acknowledged: id}} =
             ModelCalls.complete(c.token, work.id, work.claim_id, response)

    assert id == work.id
    [before] = Ledger.read!(ModelCall, id: id)

    assert {:ok, %{acknowledged: ^id}} =
             ModelCalls.complete(c.token, work.id, work.claim_id, response)

    assert [^before] = Ledger.read!(ModelCall, id: id)

    assert {:error, :stale_claim} =
             ModelCalls.complete(c.token, work.id, work.claim_id, %{"error" => "different"})

    :ok
  end

  @spec complete_overload(fixture(), pos_integer()) :: :ok
  defp complete_overload(c, polls) do
    work = claim_and_admit(c)
    complete(c, work, @overload)
    [finished] = Ledger.read!(ModelCall, id: work.id)
    assert finished.status == :failed
    assert finished.response == @overload
    assert finished.claim_id == work.claim_id
    assert finished.claimed_at != nil
    assert finished.finished_at != nil

    streak =
      calls(c)
      |> Enum.reverse()
      |> Enum.take_while(&(&1.purpose == :inference and &1.response == @overload))
      |> length()

    if streak < 3 do
      assert [%{status: :running}] = Ledger.read!(Turn, id: c.turn.id)
      deadline = DateTime.add(finished.finished_at, streak, :second)

      assert ModelCalls.provider_retry(calls(c), DateTime.add(deadline, -1, :microsecond)) ==
               :wait

      assert ModelCalls.provider_retry(calls(c), deadline) == :ready

      waiting =
        Ledger.update!(finished, :transition, %{
          finished_at: DateTime.add(Ledger.now(), 60, :second)
        })

      repeat(polls, fn ->
        assert {:error, :retry_waiting} = ModelCalls.queue(c.turn.id, "gpt-6-sol")
        assert :ok = Loop.tick()
        assert {:ok, %{call: nil}} = ModelCalls.claim(c.token)
        assert [^waiting] = Ledger.read!(ModelCall, id: work.id)
      end)

      due =
        Ledger.update!(waiting, :transition, %{
          finished_at: DateTime.add(Ledger.now(), -streak, :second)
        })

      repeat(polls, fn -> assert :ok = Loop.tick() end)
      assert [^due] = Ledger.read!(ModelCall, id: work.id)
      assert [_] = Enum.filter(calls(c), &(&1.status == :queued))

      assert {:ok, %{acknowledged: _}} =
               ModelCalls.complete(c.token, work.id, work.claim_id, @overload)

      assert [^due] = Ledger.read!(ModelCall, id: work.id)
    else
      assert [%{status: :failed, failure_reason: :provider_failed}] =
               Ledger.read!(Turn, id: c.turn.id)

      repeat(polls, fn -> assert :ok = Loop.tick() end)
      assert [^finished] = Ledger.read!(ModelCall, id: work.id)
      assert {:ok, %{call: nil}} = ModelCalls.claim(c.token)
    end

    :ok
  end

  @spec complete_tool_step(fixture()) :: :ok
  defp complete_tool_step(c) do
    work = claim_and_admit(c)

    complete(c, work, %{
      "status" => "completed",
      "output" => [
        %{
          "type" => "function_call",
          "call_id" => work.id,
          "name" => "exec_command",
          "arguments" => ~s({"cmd":"pwd"})
        }
      ]
    })

    [executor] = Ledger.read!(Executor, vm_id: c.vm.id, invalidated_at: [is_nil: true])
    binding = Marshall.AgentContextFixtures.binding(c.vm)
    assert {:ok, command} = ExecutorSession.claim(binding, executor.id, executor.fence_epoch)

    assert {:ok, _} =
             ExecutorSession.transition(
               binding,
               executor.id,
               executor.fence_epoch,
               command.id,
               :started
             )

    assert {:ok, _} =
             ExecutorSession.transition(
               binding,
               executor.id,
               executor.fence_epoch,
               command.id,
               :completed,
               %{"stdout" => "/workspace"}
             )

    assert :ok = Loop.tick()
    :ok
  end

  @spec repeat(non_neg_integer(), (-> term())) :: :ok
  defp repeat(0, _fun), do: :ok

  defp repeat(count, fun) do
    Enum.each(1..count, fn _ -> fun.() end)
  end
end
