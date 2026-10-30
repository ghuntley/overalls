defmodule Porsche.RunnerTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Porsche.Runner
  @operation "11111111-1111-4111-8111-111111111111"
  @other_operation "22222222-2222-4222-8222-222222222222"
  @id "intended-operation"

  test "oversized disks fail before contacting Marshall" do
    {options, state} = script([])
    assert %{exit_status: 2} = Runner.run(client(), "s", "new --disk 501", options)
    assert state.().calls == []

    {options, state} = script([receipt("accepted")])

    assert %{exit_status: 0} =
             Runner.run(client(), "s", "new --disk 500 --no-wait --request-id #{@id}", options)

    assert [call] = state.().calls
    assert get_in(call, ["command", "options", "disk"]) == "500"
  end

  test "team machine creation preserves the selected team in the Marshall request" do
    {options, state} = script([receipt("accepted")])

    assert %{exit_status: 0} =
             Runner.run(
               client(),
               "s",
               "new --team platform-team --no-wait --request-id #{@id}",
               options
             )

    assert get_in(hd(state.().calls), ["command", "options", "team"]) == "platform-team"
  end

  test "team commands dispatch every read and mutation unchanged" do
    mutation_commands = [
      {"team create platform-team --request-id #{@id}", "team create", ["platform-team"]},
      {"team member add platform-team member@example.com admin --request-id #{@id}",
       "team member add", ["platform-team", "member@example.com", "admin"]},
      {"team member remove platform-team member@example.com --request-id #{@id}",
       "team member remove", ["platform-team", "member@example.com"]},
      {"team transfer offer platform-team member@example.com --request-id #{@id}",
       "team transfer offer", ["platform-team", "member@example.com"]},
      {"team transfer accept #{@operation} --request-id #{@id}", "team transfer accept",
       [@operation]},
      {"team transfer decline #{@operation} --request-id #{@id}", "team transfer decline",
       [@operation]},
      {"team transfer cancel #{@operation} --request-id #{@id}", "team transfer cancel",
       [@operation]}
    ]

    for {text, expected_command, expected_arguments} <- mutation_commands do
      response = Map.put(receipt("succeeded"), "operation_id", nil)
      {options, state} = script([response])
      assert %{exit_status: 0} = Runner.run(client(), "s", text, options)
      [call] = state.().calls
      assert get_in(call, ["command", "command"]) == expected_command
      assert get_in(call, ["command", "arguments"]) == expected_arguments
      assert get_in(call, ["command", "options", "request-id"]) == @id
    end

    {options, state} =
      script([%{"version" => 1, "status" => "succeeded", "result" => %{"members" => []}}])

    assert %{exit_status: 0} = Runner.run(client(), "s", "team show platform-team", options)
    [call] = state.().calls
    assert get_in(call, ["command", "command"]) == "team show"
    assert get_in(call, ["command", "arguments"]) == ["platform-team"]
    assert get_in(call, ["command", "options"]) == %{}
  end

  test "host, capacity, clone and relocation refusals are command errors without resubmission" do
    for reason <- [
          :insufficient_capacity,
          :host_unavailable,
          :clone_already_published,
          :clone_not_retryable,
          :clone_in_progress,
          :workload_not_stable,
          :checkpoint_unavailable,
          :vm_busy,
          :source_unavailable,
          :transfer_busy,
          :resize_in_progress,
          :relocation_in_progress,
          :relocation_committed,
          :relocation_finished,
          :relocation_retry_unavailable,
          :placement_changed,
          :idempotency_conflict
        ] do
      {options, state} = script([{:error, reason}])

      result =
        Runner.run(client(), "current-session", "clone source --request-id #{@id}", options)

      assert result.exit_status == 2
      assert result.response["error"] == Atom.to_string(reason)
      assert length(state.().calls) == 1
    end
  end

  test "device refusals keep their closed reason and add a fixed next-step hint" do
    for {reason, hint} <- [
          push_disabled: "push notifications turned off",
          device_limit: "device rm"
        ] do
      {options, state} = script([{:error, reason}])

      result =
        Runner.run(
          client(),
          "s",
          "device rm 5d7a6f0e-2b1c-4e8f-9a3d-6c0b1e2f3a4b --request-id #{@id}",
          options
        )

      assert result.exit_status == 2
      assert result.response["error"] == Atom.to_string(reason)
      assert result.response["hint"] =~ hint
      assert length(state.().calls) == 1
    end

    {options, _state} = script([{:error, :not_found}])

    assert %{exit_status: 2} =
             Runner.run(
               client(),
               "s",
               "device prefs 5d7a6f0e-2b1c-4e8f-9a3d-6c0b1e2f3a4b --enabled false",
               options
             )

    # A push key placeholder must be replaced from stdin before dispatch.
    enc = Base.url_encode64(:binary.copy(<<5>>, 32), padding: false)

    assert %{exit_status: 2, response: %{"error" => "stdin_secret_required"}} =
             Runner.run(
               client(),
               "s",
               "device register --platform ios --push-key - --enc-pubkey #{enc}"
             )
  end

  test "pin refusals keep their closed reason and add a fixed next-step hint" do
    {options, state} = script([{:error, :machine_pinned}])
    result = Runner.run(client(), "s", "rm pinned-machine --request-id #{@id}", options)
    assert result.exit_status == 2
    assert result.response["error"] == "machine_pinned"
    assert result.response["hint"] =~ "unpin it first: unpin MACHINE"
    assert length(state.().calls) == 1

    {options, _state} = script([{:error, :pin_limit}])
    result = Runner.run(client(), "s", "pin another-machine --request-id #{@id}", options)
    assert result.exit_status == 2
    assert result.response["error"] == "pin_limit"
    assert result.response["hint"] =~ "unpin one first"

    {options, _state} = script([{:error, :forbidden}])
    result = Runner.run(client(), "s", "pin another-machine --request-id #{@id}", options)
    refute Map.has_key?(result.response, "hint")

    for name <- ["pin", "unpin"] do
      {options, state} = script([Map.put(receipt("succeeded"), "operation_id", nil)])

      assert %{exit_status: 0} =
               Runner.run(client(), "s", "#{name} vm-one --request-id #{@id}", options)

      [call] = state.().calls
      assert get_in(call, ["command", "command"]) == name
      assert get_in(call, ["command", "arguments"]) == ["vm-one"]
      # A synchronous mutation submits once and never waits on a receipt.
      refute Enum.any?(state.().progress, &(&1.event == :waiting))
    end
  end

  test "one admission then correlated request polls, with the same session authority" do
    {options, state} = script([receipt("accepted"), receipt("accepted"), receipt("succeeded")])

    assert %{exit_status: 0, response: %{"status" => "succeeded"}} =
             Runner.run(client(), "current-session", "new --request-id #{@id}", options)

    calls = state.().calls

    assert Enum.map(calls, &get_in(&1, ["command", "command"])) == [
             "new",
             "request show",
             "request show"
           ]

    assert Enum.all?(calls, &(&1["session_token"] == "current-session"))
    assert Enum.map(tl(calls), &get_in(&1, ["command", "arguments"])) == [[@id], [@id]]
    assert state.().time == 2000

    assert state.().progress == [
             %{event: :submitting, request_id: @id},
             %{event: :waiting, request_id: @id},
             %{event: :waiting, request_id: @id}
           ]
  end

  test "accepted work times out locally, retaining receipt identity without cancellation" do
    {options, state} = script(List.duplicate(receipt("accepted"), 10))

    assert %{
             exit_status: 4,
             response: %{
               "status" => "accepted",
               "wait_status" => "timed_out",
               "request_id" => @id
             }
           } =
             Runner.run(
               client(),
               "session",
               "stop machine --timeout 2 --request-id #{@id}",
               options
             )

    assert state.().time == 2000

    assert Enum.map(state.().calls, &get_in(&1, ["command", "command"])) == [
             "stop",
             "request show"
           ]

    assert state.().timeouts == [2000, 1000]
  end

  test "default physical wait is 120 seconds and no-wait returns immediately" do
    {options, state} = script(List.duplicate(receipt("accepted"), 130))

    assert %{exit_status: 4} =
             Runner.run(client(), "s", "start machine --request-id #{@id}", options)

    assert state.().time == 120_000
    assert length(state.().calls) == 120

    {options, state} = script([receipt("accepted")])

    assert %{exit_status: 0, response: %{"status" => "accepted"}} =
             Runner.run(client(), "s", "rm machine --no-wait --request-id #{@id}", options)

    assert length(state.().calls) == 1
    assert state.().time == 0

    {options, state} = script([receipt("accepted")])

    assert %{exit_status: 0, response: %{"status" => "accepted"}} =
             Runner.run(
               client(),
               "s",
               "relocate machine --no-wait --request-id #{@id}",
               options
             )

    assert get_in(hd(state.().calls), ["command", "command"]) == "relocate"
    assert state.().time == 0
  end

  test "revocation and forbidden access stop the wait without repeating admission" do
    for reason <- [:unauthorized, :forbidden] do
      {options, state} = script([receipt("accepted"), {:error, reason}])
      result = Runner.run(client(), "s", "new --request-id #{@id}", options)
      assert result.exit_status != 0
      assert result.response["request_id"] == @id
      assert result.response["error"] == Atom.to_string(reason)
      assert length(state.().calls) == 2
    end
  end

  # @cc [owner:ghuntley,label:verification;recovery] porsche-wait-transient-poll
  # A transient poll failure before the deadline MUST keep waiting and reach
  # the terminal receipt, never re-submitting admission.
  test "transient poll failures keep waiting for the terminal receipt" do
    for reason <- [:transport_error, :temporarily_unavailable, :rate_limited, :http_error] do
      {options, state} =
        script([receipt("accepted"), {:error, reason}, receipt("succeeded")])

      result = Runner.run(client(), "s", "new --request-id #{@id}", options)
      assert result.exit_status == 0
      assert result.response["status"] == "succeeded"
      assert length(state.().calls) == 3
      assert Enum.count(state.().calls, &(get_in(&1, ["command", "command"]) == "new")) == 1
    end
  end

  test "a lost admission reply generates one request id and stops" do
    {options, state} = script([{:error, :transport_error}])
    result = Runner.run(client(), "s", "new", options)
    assert result.exit_status == 5
    generated = result.response["request_id"]
    assert generated =~ ~r/\Aporsche-[0-9a-f]{32}\z/
    assert state.().progress == [%{event: :submitting, request_id: generated}]
    assert get_in(hd(state.().calls), ["command", "options", "request-id"]) == generated
  end

  test "malformed or mismatched receipts never establish completion" do
    for invalid <- [
          receipt("succeeded") |> put_in(["request_id"], "other-request"),
          receipt("succeeded") |> put_in(["version"], 2),
          receipt("succeeded") |> put_in(["operation_id"], nil),
          receipt("acknowledged"),
          receipt("succeeded") |> Map.put("extra", "field")
        ] do
      {options, state} = script([invalid])

      assert %{exit_status: 5, response: %{"error" => "invalid_response"}} =
               Runner.run(client(), "s", "new --request-id #{@id}", options)

      assert length(state.().calls) == 1
    end

    {options, _} =
      script([
        receipt("accepted"),
        Map.put(receipt("succeeded"), "operation_id", @other_operation)
      ])

    assert %{exit_status: 5, response: %{"error" => "invalid_response"}} =
             Runner.run(client(), "s", "new --request-id #{@id}", options)
  end

  test "read commands do not generate receipts and synchronous mutations do not poll" do
    {options, state} =
      script([%{"version" => 1, "status" => "succeeded", "result" => %{"id" => "account"}}])

    assert %{exit_status: 0} = Runner.run(client(), "s", "whoami", options)
    assert state.().progress == []
    assert get_in(hd(state.().calls), ["command", "options"]) == %{}

    {options, state} = script([Map.put(receipt("succeeded"), "operation_id", nil)])

    assert %{exit_status: 0} =
             Runner.run(
               client(),
               "s",
               "ssh-key remove #{@operation} --request-id #{@id}",
               options
             )

    assert length(state.().calls) == 1

    {options, state} = script([receipt("accepted")])
    assert %{exit_status: 0} = Runner.run(client(), "s", "request show #{@id}", options)
    assert length(state.().calls) == 1
    assert state.().progress == []
  end

  test "parser errors never contact Marshall" do
    {options, state} = script([])
    assert %{exit_status: 2} = Runner.run(client(), "s", "new; reboot", options)
    assert state.().calls == []
  end

  test "HTTP latency consumes the wait budget and revocation still wins over timeout" do
    for {error, expected} <- [{:transport_error, 4}, {:unauthorized, 3}] do
      {options, state} =
        script([
          {:delay, 400, receipt("accepted")},
          {:delay, 600, {:error, error}}
        ])

      assert %{exit_status: ^expected} =
               Runner.run(client(), "s", "new --timeout 2 --request-id #{@id}", options)

      assert state.().time == 2000
      assert state.().timeouts == [2000, 600]
      assert length(state.().calls) == 2
    end
  end

  property "wait traces submit once and stop at the first terminal receipt or deadline" do
    pending = draw("pending", integer(0..10))
    timeout = draw("timeout", integer(1..8))
    terminal = draw("terminal", member_of(["succeeded", "failed", "superseded"]))
    replies = List.duplicate(receipt("accepted"), pending) ++ [receipt(terminal)]
    {options, state} = script(replies)
    result = Runner.run(client(), "s", "new --timeout #{timeout} --request-id #{@id}", options)

    if pending < timeout do
      assert result.response["status"] == terminal
      assert result.exit_status == if(terminal == "succeeded", do: 0, else: 1)
      assert length(state.().calls) == pending + 1
    else
      assert result.exit_status == 4
      assert result.response["status"] == "accepted"
      assert length(state.().calls) == timeout
    end

    assert Enum.count(state.().calls, &(get_in(&1, ["command", "command"]) == "new")) == 1
  end

  defp client do
    {:ok, client} =
      Porsche.Client.new(
        "https://marshall.test",
        "porsche_gateway_" <> Base.url_encode64(<<0::256>>, padding: false)
      )

    client
  end

  defp receipt(status),
    do: %{
      "version" => 1,
      "request_id" => @id,
      "operation_id" => @operation,
      "status" => status,
      "result" => %{"id" => "machine"}
    }

  # This models only the runner's network replies and monotonic clock. Marshall's
  # authority and physical completion are separately exercised in backend tests.
  defp script(replies) do
    key = make_ref()
    Process.put(key, %{replies: replies, calls: [], timeouts: [], progress: [], time: 0})

    options = [
      now: fn -> Process.get(key).time end,
      sleep: fn milliseconds ->
        Process.put(key, Map.update!(Process.get(key), :time, &(&1 + milliseconds)))
      end,
      progress: fn progress ->
        Process.put(key, Map.update!(Process.get(key), :progress, &(&1 ++ [progress])))
      end,
      request: fn _client, "commands", message, options ->
        state = Process.get(key)
        [reply | rest] = state.replies

        Process.put(key, %{
          state
          | replies: rest,
            calls: state.calls ++ [message],
            timeouts: state.timeouts ++ [Keyword.fetch!(options, :timeout)]
        })

        reply =
          case reply do
            {:delay, milliseconds, value} ->
              Process.put(key, Map.update!(Process.get(key), :time, &(&1 + milliseconds)))
              value

            value ->
              value
          end

        case reply do
          {:error, _} = error -> error
          reply -> {:ok, reply}
        end
      end
    ]

    {options, fn -> Process.get(key) end}
  end
end
