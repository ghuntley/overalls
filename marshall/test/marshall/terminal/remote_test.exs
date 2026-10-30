defmodule Marshall.Terminal.RemoteTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  alias Marshall.Terminal.{Directory, PeerBudget, Relay, Remote}

  @fixtures Path.expand("../../fixtures/tls", __DIR__)
  @peer_restart_cases 100

  setup tags do
    if tags[:private_peer_budget], do: isolate_peer_budget!()

    server =
      start_supervised!(
        {Bandit,
         plug: MarshallWeb.TerminalPeerAPI,
         scheme: :https,
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false,
         certfile: Path.join(@fixtures, "localhost.pem"),
         keyfile: Path.join(@fixtures, "localhost.key")}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    old_url = Application.get_env(:marshall, :terminal_peer_url)
    old_ca = Application.get_env(:marshall, :terminal_peer_ca)
    Application.put_env(:marshall, :terminal_peer_url, "https://127.0.0.1:#{port}")
    Application.put_env(:marshall, :terminal_peer_ca, Path.join(@fixtures, "ca.pem"))

    on_exit(fn ->
      Application.put_env(:marshall, :terminal_peer_url, old_url)
      Application.put_env(:marshall, :terminal_peer_ca, old_ca)
    end)

    if tags[:hegel_case_sandbox] do
      :ok
    else
      %{fixture: fixture, stream: stream, remote: remote} = ordinary_context()
      %{fixture: fixture, stream: stream, remote: remote}
    end
  end

  @spec ordinary_context() :: %{
          fixture: map(),
          stream: pid(),
          remote: pid()
        }
  defp ordinary_context do
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    stream = Marshall.TerminalFixtures.stream_fixture(fixture.host.id)
    {:ok, location} = Directory.lookup(fixture.host.id)
    remote = start_remote(location, fn spec -> start_supervised!(spec) end)
    %{fixture: fixture, stream: stream, remote: remote}
  end

  @spec property_context() :: %{
          fixture: map(),
          stream: pid(),
          remote: pid(),
          budget: pid(),
          budget_id: reference()
        }
  defp property_context do
    Marshall.DataCase.isolate_property_case()
    %{pid: budget, id: budget_id} = start_case_budget()
    previous_budget = Application.get_env(:marshall, :terminal_peer_budget)
    Application.put_env(:marshall, :terminal_peer_budget, budget)

    Hegel.on_cleanup(fn ->
      if is_nil(previous_budget),
        do: Application.delete_env(:marshall, :terminal_peer_budget),
        else: Application.put_env(:marshall, :terminal_peer_budget, previous_budget)
    end)

    fixture = Marshall.TerminalFixtures.terminal_fixture()
    stream = Marshall.TerminalFixtures.stream_fixture(fixture.host.id, :property)
    {:ok, location} = Directory.lookup(fixture.host.id)
    remote = start_remote(location, &Overalls.HegelFixtures.start_supervised!/1)
    %{fixture: fixture, stream: stream, remote: remote, budget: budget, budget_id: budget_id}
  end

  @spec teardown_property_context(map()) :: :ok
  defp teardown_property_context(%{remote: remote, stream: stream, budget: budget}) do
    if Process.alive?(remote), do: GenServer.stop(remote)
    if Process.alive?(stream), do: Process.exit(stream, :shutdown)
    await_budget_empty(budget, System.monotonic_time(:millisecond) + 2_000)
  end

  @spec start_case_budget() :: %{id: reference(), pid: pid()}
  defp start_case_budget do
    id = make_ref()
    pid = start_supervised!({PeerBudget, name: nil, limit: 512}, id: id)
    Hegel.on_cleanup(fn -> stop_case_budget(id) end)
    %{id: id, pid: pid}
  end

  @spec start_remote(Marshall.Terminal.Location.t(), (map() -> pid())) :: pid()
  defp start_remote(location, starter) do
    starter.(%{
      id: make_ref(),
      start: {Remote, :start, [self(), location]},
      restart: :temporary
    })
  end

  @spec await_budget_empty(pid(), integer()) :: :ok
  defp await_budget_empty(budget, deadline) do
    cond do
      not Process.alive?(budget) ->
        :ok

      PeerBudget.used(budget) == 0 ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        :ok

      true ->
        receive do
        after
          1 -> await_budget_empty(budget, deadline)
        end
    end
  end

  @spec current_case_budget(reference()) :: pid() | nil
  defp current_case_budget(id) do
    {:ok, supervisor} = ExUnit.fetch_test_supervisor()

    case List.keyfind(Supervisor.which_children(supervisor), id, 0) do
      {^id, pid, _, _} when is_pid(pid) -> pid
      _ -> nil
    end
  end

  @spec stop_case_budget(reference()) :: :ok
  defp stop_case_budget(id) do
    {:ok, supervisor} = ExUnit.fetch_test_supervisor()

    case List.keyfind(Supervisor.which_children(supervisor), id, 0) do
      nil ->
        :ok

      {^id, :undefined, _, _} ->
        :ok = Supervisor.delete_child(supervisor, id)

      {^id, pid, _, _} when is_pid(pid) ->
        :ok = Supervisor.terminate_child(supervisor, id)

        case Supervisor.delete_child(supervisor, id) do
          :ok -> :ok
          {:error, :not_found} -> :ok
          other -> raise "case peer budget cleanup failed: #{inspect(other)}"
        end
    end
  end

  # @cc [owner:ghuntley,label:verification;recovery] peer-budget-fixture-supervision
  # Generated budget deaths MUST use a test-owned supervisor with the same
  # registered API and capacity. Its restart allowance MUST cover the complete
  # generated history; the original application child MUST be restored only
  # after ExUnit has stopped the test supervisor and its replacement budget.
  @spec isolate_peer_budget!() :: :ok
  defp isolate_peer_budget! do
    original = Process.whereis(PeerBudget)
    assert is_pid(original)
    assert PeerBudget.used(original) == 0
    limit = :sys.get_state(original).limit
    monitor = Process.monitor(original)
    assert :ok = Supervisor.terminate_child(Marshall.Supervisor, PeerBudget)

    # ExUnit stops all start_supervised! children before running on_exit hooks,
    # including when setup or a generated case fails.
    on_exit(fn ->
      assert is_nil(Process.whereis(PeerBudget))
      assert {:ok, restored} = Supervisor.restart_child(Marshall.Supervisor, PeerBudget)
      assert Process.whereis(PeerBudget) == restored
      assert :sys.get_state(restored).limit == limit
      assert PeerBudget.used(restored) == 0
    end)

    assert_receive {:DOWN, ^monitor, :process, ^original, :shutdown}, 1_000

    start_supervised!(%{
      id: :private_peer_budget,
      start:
        {Supervisor, :start_link,
         [
           [{PeerBudget, limit: limit}],
           [strategy: :one_for_one, max_restarts: @peer_restart_cases, max_seconds: 5]
         ]},
      type: :supervisor,
      shutdown: 5_000
    })

    assert :sys.get_state(PeerBudget).limit == limit
    :ok
  end

  # @cc [owner:ghuntley,label:verification;capacity;recovery] peer-budget-incarnation-live-sockets
  # Budget death MUST retire every admitted real TLS peer owner before fresh
  # pairs acquire successor slots. The synthetic host stream MUST remain alive;
  # this test MUST NOT claim native guest survival or independent-node recovery.
  @tag :hegel
  @tag :hegel_case_sandbox
  @tag timeout: 600_000
  test "budget restart retires live TLS peers and admits exact replacement pairs" do
    # The native runner uses test_cases to bound these real-socket histories.
    Hegel.check(
      fn ->
        context = property_context()
        Hegel.on_cleanup(fn -> teardown_property_context(context) end)
        %{fixture: fixture, stream: stream, remote: initial, budget: budget} = context
        count = draw("count", integer(1..3))
        {:ok, location} = Directory.lookup(fixture.host.id)
        remotes = for _ <- 1..count, do: start_peer(location)
        remotes = if Process.alive?(initial), do: [initial | remotes], else: remotes

        for remote <- remotes, do: healthy_peer(remote, fixture.vm)
        assert PeerBudget.used(budget) == 2 * length(remotes)
        owners = Map.keys(:sys.get_state(budget).owners)
        monitors = Enum.map(owners, &Process.monitor/1)
        budget_monitor = Process.monitor(budget)
        Process.exit(budget, :kill)
        assert_receive {:DOWN, ^budget_monitor, :process, ^budget, :killed}, 1_000

        for {owner, monitor} <- Enum.zip(owners, monitors),
            do: assert_receive({:DOWN, ^monitor, :process, ^owner, _}, 2_000)

        successor =
          await_budget(context.budget_id, budget, System.monotonic_time(:millisecond) + 2_000)

        assert is_pid(successor)
        assert successor != budget
        Application.put_env(:marshall, :terminal_peer_budget, successor)
        assert PeerBudget.used(successor) == 0
        assert Process.alive?(stream)
        assert {:ok, ^location} = Directory.lookup(fixture.host.id)

        replacements = for _ <- 1..count, do: start_peer(location)
        for remote <- replacements, do: healthy_peer(remote, fixture.vm)
        assert PeerBudget.used(successor) == 2 * count
        replacement_owners = Map.keys(:sys.get_state(successor).owners)
        replacement_monitors = Enum.map(replacement_owners, &Process.monitor/1)
        for remote <- replacements, do: GenServer.stop(remote)

        for {owner, monitor} <- Enum.zip(replacement_owners, replacement_monitors),
            do: assert_receive({:DOWN, ^monitor, :process, ^owner, _}, 2_000)

        assert Process.alive?(stream)
      end,
      profile: :ci,
      test_cases: @peer_restart_cases
    )
  end

  # @cc [owner:ghuntley,label:verification;recovery] peer-tls-shifted-silence
  # Real peer output between heartbeat ticks MUST renew outgoing silence;
  # subsequent silent transport MUST retire the hop within fifteen seconds
  # plus bounded test scheduler allowance. The host stream remains synthetic.
  @tag :hegel
  @tag :hegel_case_sandbox
  @tag timeout: 2_700_000
  test "shifted TLS activity expires without waiting for another heartbeat" do
    # Each generated case waits out a real fifteen-second silence deadline
    # (about 16.5 s per case), so the default 100-case exploration needs about
    # 28 minutes; the aggregate timeout leaves load margin above that.
    Hegel.check(
      fn ->
        context = property_context()
        Hegel.on_cleanup(fn -> teardown_property_context(context) end)
        %{fixture: fixture, remote: initial, budget: budget} = context

        owners = Map.keys(:sys.get_state(budget).owners)
        monitors = Enum.map(owners, &Process.monitor/1)
        GenServer.stop(initial)

        for {owner, monitor} <- Enum.zip(owners, monitors),
            do: assert_receive({:DOWN, ^monitor, :process, ^owner, _}, 2_000)

        offset = draw("offset", integer(500..1500))
        {:ok, previous_location} = Directory.lookup(fixture.host.id)
        assert :ok = Directory.renew(fixture.host.id, previous_location.nonce)
        {:ok, location} = Directory.lookup(fixture.host.id)
        remote = start_peer(location)
        healthy_peer(remote, fixture.vm)
        [peer] = Map.keys(:sys.get_state(budget).owners) -- [remote]
        marker = make_ref()
        Process.send_after(self(), {:shifted_activity, marker}, offset)
        assert_receive {:shifted_activity, ^marker}, 2_000
        send(peer, {:terminal_output, <<42>>})
        assert_receive {:terminal_output, <<42>>}, 1_000
        last_seen = :sys.get_state(remote).last_seen
        :ok = :sys.suspend(peer)

        Hegel.on_cleanup(fn ->
          try do
            :sys.resume(peer)
          catch
            :exit, _ -> :ok
          end
        end)

        monitor = Process.monitor(remote)
        Process.send_after(self(), {:renew_location, marker}, 10_000)
        assert_receive {:renew_location, ^marker}, 11_000
        assert :ok = Directory.renew(fixture.host.id, location.nonce)
        remaining = max(0, last_seen + 15_000 - System.monotonic_time(:millisecond))
        assert_receive {:DOWN, ^monitor, :process, ^remote, :normal}, remaining + 250
        elapsed = System.monotonic_time(:millisecond) - last_seen
        assert elapsed >= 15_000
        assert elapsed <= 15_250
        assert_receive {:terminal_closed, %{reason: :stream_unavailable}}, 1_000
        :ok = :sys.resume(peer)
        assert await_peer_release(peer, budget, System.monotonic_time(:millisecond) + 2_000)
        assert PeerBudget.used(budget) == 0
      end,
      profile: :ci,
      test_cases: 100
    )
  end

  @spec await_peer_release(pid(), pid(), integer()) :: boolean()
  defp await_peer_release(peer, budget, deadline) do
    cond do
      not Map.has_key?(:sys.get_state(budget).owners, peer) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      true ->
        receive do
        after
          1 -> await_peer_release(peer, budget, deadline)
        end
    end
  end

  # @cc [owner:ghuntley,label:verification;recovery] incoming-peer-tls-silence
  # Incoming peer activity between liveness ticks MUST renew its silence
  # deadline; fifteen subsequent silent seconds MUST terminate its WebSock
  # application and release its slot, independently of server-process lifetime.
  @tag :hegel
  @tag :hegel_case_sandbox
  @tag timeout: 2_700_000
  test "incoming TLS silence retires the application at its renewed deadline" do
    # Each generated case waits out a real fifteen-second silence deadline
    # (about 16.5 s per case), so the default 100-case exploration needs about
    # 28 minutes; the aggregate timeout leaves load margin above that.
    Hegel.check(
      fn ->
        context = property_context()
        Hegel.on_cleanup(fn -> teardown_property_context(context) end)
        %{fixture: fixture, remote: initial, budget: budget} = context

        owners = Map.keys(:sys.get_state(budget).owners)
        monitors = Enum.map(owners, &Process.monitor/1)
        GenServer.stop(initial)

        for {owner, monitor} <- Enum.zip(owners, monitors),
            do: assert_receive({:DOWN, ^monitor, :process, ^owner, _}, 2_000)

        offset = draw("offset", integer(500..1500))
        {:ok, location} = Directory.lookup(fixture.host.id)
        assert :ok = Directory.renew(fixture.host.id, location.nonce)
        remote = start_peer(location)
        healthy_peer(remote, fixture.vm)
        [peer] = Map.keys(:sys.get_state(budget).owners) -- [remote]
        previous = peer_last_seen(peer)
        marker = make_ref()
        Process.send_after(self(), {:incoming_activity, marker}, offset)
        assert_receive {:incoming_activity, ^marker}, 2_000
        channel = :sys.get_state(remote).channel
        send(remote, {:viewer_output_ack, channel, 0, 0})
        _ = :sys.get_state(remote)

        last_seen =
          await_peer_activity(peer, previous, System.monotonic_time(:millisecond) + 1_000)

        assert is_integer(last_seen)
        :erlang.trace(peer, true, [:send, :monotonic_timestamp])
        :ok = :sys.suspend(remote)

        Hegel.on_cleanup(fn ->
          try do
            :sys.resume(remote)
          catch
            :exit, _ -> :ok
          end
        end)

        Process.send_after(self(), {:renew_incoming_location, marker}, 10_000)
        assert_receive {:renew_incoming_location, ^marker}, 11_000
        assert :ok = Directory.renew(fixture.host.id, location.nonce)
        remaining = max(0, last_seen + 15_000 - System.monotonic_time(:millisecond))

        timestamp =
          receive do
            {:trace_ts, ^peer, :send, {:"$gen_cast", {:release, ^peer}}, _budget, timestamp} ->
              timestamp
          after
            remaining + 250 ->
              {_socket, %{connection: connection}} = :sys.get_state(peer)
              renewed_by = connection.websock_state.last_seen - last_seen
              occupied = Map.has_key?(:sys.get_state(budget).owners, peer)

              flunk(
                "termination unobserved: state=#{connection.state}, renewed_by_ms=#{renewed_by}, occupied=#{occupied}"
              )
          end

        elapsed = System.convert_time_unit(timestamp, :native, :millisecond) - last_seen
        assert elapsed >= 15_000
        assert elapsed <= 15_250
        assert await_peer_release(peer, budget, System.monotonic_time(:millisecond) + 2_000)
        monitor = Process.monitor(remote)
        :ok = :sys.resume(remote)
        assert_receive {:DOWN, ^monitor, :process, ^remote, :normal}, 2_000
        assert_receive {:terminal_closed, %{reason: :stream_unavailable}}, 1_000
        assert PeerBudget.used(budget) == 0
      end,
      profile: :ci,
      test_cases: 100
    )
  end

  @spec peer_last_seen(pid()) :: integer()
  defp peer_last_seen(peer) do
    {_socket, %{connection: %{websock_state: %{last_seen: last_seen}}}} = :sys.get_state(peer)
    last_seen
  end

  @spec await_peer_activity(pid(), integer(), integer()) :: integer() | nil
  defp await_peer_activity(peer, previous, deadline) do
    current = peer_last_seen(peer)

    cond do
      current > previous ->
        current

      System.monotonic_time(:millisecond) >= deadline ->
        nil

      true ->
        receive do
        after
          1 -> await_peer_activity(peer, previous, deadline)
        end
    end
  end

  @spec start_peer(Marshall.Terminal.Location.t()) :: pid()
  defp start_peer(location) do
    start_owned(%{
      id: make_ref(),
      start: {Remote, :start, [self(), location]},
      restart: :temporary
    })
  end

  @spec start_owned(map()) :: pid()
  defp start_owned(spec) do
    if Hegel.in_property_case?() do
      Overalls.HegelFixtures.start_supervised!(spec)
    else
      start_supervised!(spec)
    end
  end

  @spec healthy_peer(pid(), Marshall.Compute.VirtualMachine.t()) :: :ok
  defp healthy_peer(remote, vm) do
    send(
      remote,
      {:viewer_attach,
       %{
         caller: self(),
         ref: make_ref(),
         message: %{
           type: :attach,
           vm_id: vm.id,
           placement_id: vm.current_placement_id,
           execution_epoch: vm.execution_epoch,
           guest_session_id: 1,
           mode: :ro,
           cursor: 0,
           cols: 80,
           rows: 24
         }
       }}
    )

    assert_receive {:terminal_attached, %{ok: true, channel: channel, guest_session_id: 1}}, 2_000
    assert :sys.get_state(remote).channel == channel

    :ok
  end

  @spec await_budget(reference(), pid(), integer()) :: pid() | nil
  defp await_budget(id, previous, deadline) do
    current = current_case_budget(id)

    cond do
      is_pid(current) and current != previous ->
        current

      System.monotonic_time(:millisecond) >= deadline ->
        nil

      true ->
        receive do
        after
          1 -> await_budget(id, previous, deadline)
        end
    end
  end

  test "peer forwarding accepts the PID owner with a separate reply alias", %{
    remote: remote,
    fixture: fixture
  } do
    message = %{
      type: :listing,
      vm_id: fixture.vm.id,
      placement_id: fixture.vm.current_placement_id,
      execution_epoch: fixture.vm.execution_epoch
    }

    assert {:ok, %{type: :listed, sessions: []}} = Relay.control(remote, message)
    refute_receive {:relay_reply, _, _}, 0
  end

  test "foreign ownership is refused through the alias, including after it expires", %{
    remote: remote
  } do
    alias_ref = :erlang.alias()
    request = %{caller: remote, ref: make_ref(), reply_to: alias_ref, message: %{type: :listing}}
    send(remote, {:relay_control, request})
    assert_receive {:relay_reply, _, {:error, :stream_busy}}, 1000
    :erlang.unalias(alias_ref)
    send(remote, {:relay_control, request})
    :sys.get_state(remote)
    refute_receive {:relay_reply, _, _}, 0
  end

  test "peer shutdown reports pending failure through the alias", %{remote: remote} do
    :sys.suspend(remote)
    reply_alias = :erlang.alias()
    reference = make_ref()
    request = %{caller: self(), reply_to: reply_alias, ref: reference, message: %{type: :listing}}
    :sys.replace_state(remote, &%{&1 | pending: request})
    # terminate/2 must use the same response destination as a normal control.
    :ok = GenServer.stop(remote, :normal)
    assert_receive {:relay_reply, ^reference, {:error, :stream_unavailable}}
    :erlang.unalias(reply_alias)
  end
end
