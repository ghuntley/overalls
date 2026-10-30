defmodule Enrico.ManagerHistoryPropertyTest do
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen

  alias Enrico.{Config, Manager}

  @moduletag capture_log: true
  @moduletag timeout: 600_000
  @id "11111111-1111-4111-8111-111111111111"
  @attempt "22222222-2222-4222-8222-222222222222"
  @head String.duplicate("a", 40)

  # Real git children converge in milliseconds on an idle host but can take
  # several seconds on a loaded CI runner; a short deadline there fails a case
  # that then passes on replay, which Hegel reports as flaky.
  @await_ms 60_000

  property "occupied native writer refuses clone cleanup and administrative removal before effects",
    profile: :ci do
    suffix = draw("suffix", member_of(["a", "b", "c"]))

    with_state(fn initial ->
      root = Path.join(initial.config.state_dir, "owned-#{suffix}.git")
      temporary = root <> ".new"
      File.mkdir_p!(temporary)
      sentinel = Path.join(temporary, "retained")
      File.write!(sentinel, "existing clone bytes")
      witness = root <> ".owner"
      helper = System.find_executable("enrico-git-owner") || raise ArgumentError
      shell = System.find_executable("bash") || raise ArgumentError

      port =
        Port.open({:spawn_executable, helper}, [
          :binary,
          :exit_status,
          args: [
            "10000",
            "65536",
            initial.config.state_dir,
            Path.basename(root),
            "exclusive",
            shell,
            "-c",
            "printf ready > \"$1\"; sleep 600",
            "fixture",
            witness
          ]
        ])

      try do
        await(fn -> File.read(witness) == {:ok, "ready"} end)
        assert {:error, :git_failed} = Enrico.Git.refresh(root, "NixOS", "nixpkgs")
        assert {:error, :git_failed} = Enrico.Git.remove(temporary)
        assert File.read!(sentinel) == "existing clone bytes"
        refute File.exists?(root)
        refute File.exists?(root <> ".calls")
      after
        if Port.info(port), do: Port.close(port)
      end

      await(fn -> Enrico.Git.remove(temporary) == :ok end)
      refute File.exists?(temporary)
    end)
  end

  property "manager replacement retires saturated workers before new admission",
    profile: :ci do
    for culprit <- [:manager, :tasks], count <- [1, 7, 8], do: restart_history(culprit, count)

    culprit = draw("culprit", member_of([:manager, :tasks]))
    count = draw("count", member_of([1, 7, 8]))

    restart_history(culprit, count)
  end

  @spec restart_history(:manager | :tasks, pos_integer()) :: term()
  defp restart_history(culprit, count) do
    with_state(fn initial ->
      directory = initial.config.state_dir
      bin = Path.join(directory, "bin")
      File.mkdir_p!(bin)
      File.ln_s!(Path.expand("support/controlled_git.sh", __DIR__), Path.join(bin, "git"))
      original_path = System.fetch_env!("PATH")
      System.put_env("PATH", bin <> ":" <> original_path)
      ids = Enum.map(1..count, &neighbor/1)
      root = fn id -> Path.join(directory, id <> ".git") end

      try do
        start_supervised!({Enrico.RefreshSupervisor, initial.config})

        for id <- ids do
          File.write!(root.(id) <> ".hold", "")
          assert {:ok, :running} = Manager.refresh(id, @attempt, "NixOS", "nixpkgs")
          await(fn -> File.read(root.(id) <> ".calls") == {:ok, "clone\n"} end)
        end

        native_pids =
          Enum.map(ids, fn id ->
            [pid] = String.split(File.read!(root.(id) <> ".pids"), "\n", trim: true)
            {value, ""} = Integer.parse(pid)
            assert value > 0
            value
          end)

        old_manager = Process.whereis(Manager)
        old_tasks = Process.whereis(Enrico.Tasks)
        workers = Task.Supervisor.children(Enrico.Tasks)
        assert length(workers) == count
        monitors = Enum.map([old_manager, old_tasks | workers], &{&1, Process.monitor(&1)})
        Process.exit(if(culprit == :manager, do: old_manager, else: old_tasks), :kill)

        for {pid, ref} <- monitors do
          assert_receive {:DOWN, ^ref, :process, ^pid, _}, @await_ms
        end

        await(fn ->
          is_pid(Process.whereis(Manager)) and Process.whereis(Manager) != old_manager
        end)

        assert Process.whereis(Enrico.Tasks) != old_tasks
        assert Task.Supervisor.children(Enrico.Tasks) == []
        await(fn -> Enum.all?(native_pids, &native_process_retired?/1) end)
        assert :sys.get_state(Manager).active == %{}
        assert :sys.get_state(Manager).slo.requests == 0
        target = hd(ids)
        assert {:ok, :running} = Manager.refresh(target, @attempt, "NixOS", "nixpkgs")
        await(fn -> File.read(root.(target) <> ".calls") == {:ok, "clone\nclone\n"} end)
        assert length(Task.Supervisor.children(Enrico.Tasks)) == 1
        assert {:ok, :running} = Manager.refresh(target, @attempt, "NixOS", "nixpkgs")
        assert File.read!(root.(target) <> ".calls") == "clone\nclone\n"
        File.rm!(root.(target) <> ".hold")
        await(fn -> match?(%{state: :succeeded}, Manager.status(target, @attempt)) end)
        assert :sys.get_state(Manager).slo.requests == 1
        assert Enum.all?(workers, &(not Process.alive?(&1)))
      after
        for id <- ids, do: File.rm(root.(id) <> ".hold")

        try do
          stop_supervised(Enrico.RefreshSupervisor)
        after
          System.put_env("PATH", original_path)
        end
      end
    end)
  end

  property "real saturated workers release one slot for the refused attempt",
    profile: :ci do
    for terminal <- [:success, :failure, :death], do: saturation_history(terminal, 1, 2)

    terminal = draw("terminal", member_of([:success, :failure, :death]))
    victim = draw("victim", integer(1..8))
    refusals = draw("refusals", integer(1..3))

    saturation_history(terminal, victim, refusals)
  end

  @spec native_process_retired?(pos_integer()) :: boolean()
  defp native_process_retired?(pid) do
    case File.read("/proc/#{pid}/stat") do
      {:error, :enoent} -> true
      {:ok, stat} -> Regex.match?(~r/^\d+ \([^)]*\) [ZX] /, stat)
      _ -> false
    end
  end

  @spec saturation_history(:success | :failure | :death, pos_integer(), pos_integer()) :: term()
  defp saturation_history(terminal, victim, refusals) do
    with_state(fn initial ->
      directory = initial.config.state_dir
      bin = Path.join(directory, "bin")
      File.mkdir_p!(bin)
      File.ln_s!(Path.expand("support/controlled_git.sh", __DIR__), Path.join(bin, "git"))
      original_path = System.fetch_env!("PATH")
      System.put_env("PATH", bin <> ":" <> original_path)
      ids = Enum.map(1..8, &neighbor/1)
      root = fn id -> Path.join(directory, id <> ".git") end

      try do
        start_supervised!(
          Supervisor.child_spec(
            {Task.Supervisor, name: Enrico.Tasks, max_children: Manager.refresh_limit()},
            id: :history_tasks
          )
        )

        start_supervised!(Supervisor.child_spec({Manager, initial.config}, id: :history_manager))
        for id <- ids ++ [@id], do: File.write!(root.(id) <> ".hold", "")

        for id <- ids do
          assert {:ok, :running} = Manager.refresh(id, @attempt, "NixOS", "nixpkgs")
          await(fn -> File.read(root.(id) <> ".calls") == {:ok, "clone\n"} end)
        end

        full = :sys.get_state(Manager)
        assert map_size(full.active) == 8
        assert Task.Supervisor.children(Enrico.Tasks) |> length() == 8

        for _ <- 1..refusals do
          assert {:error, :unavailable} = Manager.refresh(@id, @attempt, "NixOS", "nixpkgs")
          assert :sys.get_state(Manager) == full

          conn =
            Plug.Test.conn(
              :post,
              "/v1/repos/#{@id}/refresh",
              JSON.encode!(%{attempt_id: @attempt, owner: "NixOS", repo: "nixpkgs"})
            )
            |> Plug.Conn.put_req_header("authorization", "Bearer " <> initial.config.token)
            |> Enrico.HTTP.call(initial.config)

          assert conn.status == 503
          assert JSON.decode!(conn.resp_body) == %{"error" => "unavailable"}
          assert :sys.get_state(Manager) == full
          refute File.exists?(root.(@id) <> ".calls")
          refute File.exists?(root.(@id) <> ".new")
        end

        assert {:ok, :running} = Manager.refresh(hd(ids), @attempt, "NixOS", "nixpkgs")
        assert :sys.get_state(Manager) == full
        released = neighbor(victim)

        if terminal == :death do
          {_ref, {_id, _attempt, _generation, pid}} =
            Enum.find(
              full.monitors,
              fn {_ref, {id, _, _, _}} -> id == released end
            )

          Process.exit(pid, :kill)
        else
          if terminal == :failure, do: File.write!(root.(released) <> ".fail", "")
          File.rm!(root.(released) <> ".hold")
        end

        await(fn -> map_size(:sys.get_state(Manager).active) == 7 end)
        assert :sys.get_state(Manager).slo.requests == 1
        await(fn -> Manager.refresh(@id, @attempt, "NixOS", "nixpkgs") == {:ok, :running} end)
        await(fn -> File.read(root.(@id) <> ".calls") == {:ok, "clone\n"} end)
        assert map_size(:sys.get_state(Manager).active) == 8
        assert Task.Supervisor.children(Enrico.Tasks) |> length() <= 8
        assert {:ok, :running} = Manager.refresh(@id, @attempt, "NixOS", "nixpkgs")
        assert File.read!(root.(@id) <> ".calls") == "clone\n"
        saturated = :sys.get_state(Manager)

        expected =
          if terminal == :success,
            do: %{state: :succeeded, head: "0000000000000000000000000000000000000001"},
            else: :failed

        assert {:ok, ^expected} = Manager.refresh(released, @attempt, "NixOS", "nixpkgs")
        assert :sys.get_state(Manager) == saturated
        for id <- ids ++ [@id], do: File.rm(root.(id) <> ".hold")
        await(fn -> :sys.get_state(Manager).active == %{} end)
        final = :sys.get_state(Manager)
        assert final.slo.requests == 9
        assert final.slo.failures == if(terminal == :success, do: 0, else: 1)
        assert final.monitors == %{}
        assert final.generations == %{}
        assert {:ok, %{state: :succeeded}} = Manager.refresh(@id, @attempt, "NixOS", "nixpkgs")
        assert :sys.get_state(Manager) == final
      after
        for id <- ids ++ [@id], do: File.rm(root.(id) <> ".hold")

        try do
          try do
            stop_supervised(:history_manager)
          after
            stop_supervised(:history_tasks)
          end
        after
          System.put_env("PATH", original_path)
        end
      end
    end)
  end

  property "saturated refresh admission preserves replay and refuses without effects",
    profile: :ci do
    extra = draw("extra", integer(0..3))

    with_state(fn initial ->
      state =
        Enum.reduce(1..(8 + extra), initial, fn index, acc ->
          {next, _generation} = admit(acc, neighbor(index), @attempt)
          next
        end)

      assert {:reply, {:error, :unavailable}, ^state} =
               Manager.handle_call({:refresh, @id, @attempt, "NixOS", "nixpkgs"}, self(), state)

      assert {:reply, {:ok, :running}, ^state} =
               Manager.handle_call(
                 {:refresh, neighbor(1), @attempt, "NixOS", "nixpkgs"},
                 self(),
                 state
               )

      assert {:reply, {:error, :busy}, ^state} =
               Manager.handle_call(
                 {:refresh, neighbor(1), @id, "NixOS", "nixpkgs"},
                 self(),
                 state
               )

      assert state.slo.requests == 0
      assert state.monitors == %{}
      assert File.ls!(state.config.state_dir) == []
    end)
  end

  property "unknown or missing completion generations cannot manufacture an outcome",
    profile: :ci do
    generation = draw("generation", member_of([nil, false, 0, "", make_ref()]))
    attempt = draw("attempt", member_of([nil, @attempt]))

    with_state(fn state ->
      assert {:noreply, ^state} =
               Manager.handle_info({:finished, @id, nil, nil, {:error, :git_failed}}, state)

      assert {:noreply, ^state} =
               Manager.handle_info({:finished, @id, attempt, generation, {:ok, @head}}, state)

      assert state.slo.requests == 0
      assert state.attempts == %{}
    end)
  end

  test "real refresh workers preserve reuse at every fixed retention boundary" do
    for terminal <- [:success, :death], neighbors <- [1_023, 1_024, 1_025] do
      real_refresh_history(terminal, neighbors)
    end
  end

  # Six fixed native histories measured 164 seconds. Preserve all 100 generated
  # histories with roughly 2x aggregate headroom; each await remains bounded.
  @tag timeout: 5_400_000
  property "real refresh workers preserve reuse against retired generation messages",
    profile: :ci do
    terminal = draw("terminal", member_of([:success, :death]))
    neighbors = draw("neighbors", member_of([1023, 1024, 1025]))

    real_refresh_history(terminal, neighbors)
  end

  @spec real_refresh_history(:success | :death, pos_integer()) :: term()
  defp real_refresh_history(terminal, neighbors) do
    with_state(fn initial ->
      directory = initial.config.state_dir
      bin = Path.join(directory, "bin")
      File.mkdir_p!(bin)
      File.ln_s!(Path.expand("support/controlled_git.sh", __DIR__), Path.join(bin, "git"))
      original_path = System.fetch_env!("PATH")
      System.put_env("PATH", bin <> ":" <> original_path)

      try do
        start_supervised!(
          Supervisor.child_spec({Task.Supervisor, name: Enrico.Tasks}, id: :history_tasks)
        )

        start_supervised!(Supervisor.child_spec({Manager, initial.config}, id: :history_manager))

        root = Path.join(directory, @id <> ".git")
        File.write!(root <> ".hold", "")
        assert {:ok, :running} = Manager.refresh(@id, @attempt, "NixOS", "nixpkgs")
        old_state = :sys.get_state(Manager)

        [{old_ref, {@id, @attempt, old_generation, old_worker}}] =
          Map.to_list(old_state.monitors)

        await(fn -> File.read(root <> ".calls") == {:ok, "clone\n"} end)
        assert {:ok, :running} = Manager.refresh(@id, @attempt, "NixOS", "nixpkgs")
        assert {:error, :busy} = Manager.remove(@id)
        File.rm!(root <> ".hold")
        head = "0000000000000000000000000000000000000001"
        await(fn -> Manager.status(@id, @attempt) == %{state: :succeeded, head: head} end)
        assert :sys.get_state(Manager).monitors == %{}

        assert {:ok, %{state: :succeeded, head: ^head}} =
                 Manager.refresh(@id, @attempt, "NixOS", "nixpkgs")

        assert :ok = Manager.remove(@id)
        File.write!(root <> ".hold", "")
        assert {:ok, :running} = Manager.refresh(@id, @attempt, "NixOS", "nixpkgs")
        await(fn -> File.read(root <> ".calls") == {:ok, "clone\nclone\n"} end)
        current = :sys.get_state(Manager)
        [{_ref, {@id, @attempt, _generation, worker}}] = Map.to_list(current.monitors)
        send(Process.whereis(Manager), {:finished, @id, @attempt, old_generation, {:ok, @head}})
        send(Process.whereis(Manager), {:DOWN, old_ref, :process, old_worker, :killed})
        assert :sys.get_state(Manager) == current
        assert {:ok, :running} = Manager.refresh(@id, @attempt, "NixOS", "nixpkgs")

        Enum.each(1..neighbors, fn index ->
          id = neighbor(index)
          assert {:ok, :running} = Manager.refresh(id, @attempt, "NixOS", "nixpkgs")
          await(fn -> Manager.status(id, @attempt) == %{state: :succeeded, head: head} end)
        end)

        assert Manager.status(@id, @attempt) == :running
        assert {:ok, :running} = Manager.refresh(@id, @attempt, "NixOS", "nixpkgs")
        assert :sys.get_state(Manager).completed_count == min(neighbors, 1_024)

        expected = if terminal == :success, do: %{state: :succeeded, head: head}, else: :failed
        if terminal == :death, do: Process.exit(worker, :kill)
        File.rm!(root <> ".hold")
        await(fn -> Manager.status(@id, @attempt) == expected end)
        assert {:ok, ^expected} = Manager.refresh(@id, @attempt, "NixOS", "nixpkgs")
        settled = :sys.get_state(Manager)
        assert settled.slo.requests == neighbors + 2
        assert settled.completed_count == 1_024
        assert :queue.len(settled.completed) == 1_024
        assert map_size(settled.attempts) == 1_024
        assert Map.has_key?(settled.attempts, {neighbor(1), @attempt}) == (neighbors == 1_023)

        assert settled.attempts[{neighbor(neighbors), @attempt}] == %{
                 state: :succeeded,
                 head: head
               }

        assert settled.monitors == %{}
        assert settled.generations == %{}
        assert File.read!(root <> ".calls") == "clone\nclone\n"
      after
        try do
          try do
            stop_supervised(:history_manager)
          after
            stop_supervised(:history_tasks)
          end
        after
          System.put_env("PATH", original_path)
        end
      end
    end)
  end

  @spec await((-> boolean()), integer()) :: :ok
  defp await(predicate, deadline \\ System.monotonic_time(:millisecond) + @await_ms) do
    cond do
      predicate.() ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("controlled refresh did not converge")

      true ->
        Process.sleep(5)
        await(predicate, deadline)
    end
  end

  property "removed receipts cannot evict a reused running attempt at the retention boundary",
    profile: :ci do
    neighbors = draw("neighbors", member_of([1023, 1024, 1025]))

    with_state(fn state ->
      {state, generation} = admit(state, @id, @attempt)

      {:noreply, state} =
        Manager.handle_info({:finished, @id, @attempt, generation, {:ok, @head}}, state)

      {:reply, :ok, state} = Manager.handle_call({:remove, @id}, self(), state)
      assert state.completed_count == 0
      assert :queue.is_empty(state.completed)

      {state, generation} = admit(state, @id, @attempt)

      state =
        Enum.reduce(1..neighbors, state, fn index, current ->
          id = neighbor(index)
          {current, token} = admit(current, id, @attempt)

          {:noreply, next} =
            Manager.handle_info({:finished, id, @attempt, token, {:ok, @head}}, current)

          next
        end)

      assert {:reply, :running, ^state} =
               Manager.handle_call({:status, @id, @attempt}, self(), state)

      assert state.active[@id] == @attempt

      assert {:reply, {:ok, :running}, ^state} =
               Manager.handle_call({:refresh, @id, @attempt, "NixOS", "nixpkgs"}, self(), state)

      assert state.completed_count == min(neighbors, 1_024)
      assert :queue.len(state.completed) == state.completed_count
      assert map_size(state.attempts) == state.completed_count + 1

      assert state.attempts[{neighbor(neighbors), @attempt}] == %{
               state: :succeeded,
               head: @head
             }

      assert Map.has_key?(state.attempts, {neighbor(1), @attempt}) == neighbors <= 1_024

      previous_requests = state.slo.requests

      {:noreply, settled} =
        Manager.handle_info({:finished, @id, @attempt, generation, {:ok, @head}}, state)

      status = %{state: :succeeded, head: @head}

      assert {:reply, ^status, ^settled} =
               Manager.handle_call({:status, @id, @attempt}, self(), settled)

      assert {:reply, {:ok, ^status}, ^settled} =
               Manager.handle_call(
                 {:refresh, @id, @attempt, "NixOS", "nixpkgs"},
                 self(),
                 settled
               )

      assert settled.slo.requests == previous_requests + 1
      assert settled.completed_count == 1_024
      assert :queue.len(settled.completed) == 1_024
      assert map_size(settled.attempts) == 1_024
      assert settled.attempts[{neighbor(neighbors), @attempt}] == status
      assert Map.has_key?(settled.attempts, {neighbor(1), @attempt}) == (neighbors == 1_023)
      assert Map.has_key?(settled.attempts, {neighbor(2), @attempt}) == neighbors <= 1_024
    end)
  end

  property "old-generation results and death cannot settle a reused attempt",
    profile: :ci do
    result = draw("result", member_of(ok: @head, error: :git_failed))
    order = draw("order", member_of([:result_first, :death_first]))

    with_state(fn state ->
      worker =
        spawn(fn ->
          receive do
            :stop -> :ok
          end
        end)

      monitor = Process.monitor(worker)

      try do
        {state, old} = admit(state, @id, @attempt)
        state = %{state | monitors: %{monitor => {@id, @attempt, old, worker}}}
        {:noreply, state} = Manager.handle_info({:finished, @id, @attempt, old, result}, state)
        assert state.monitors == %{}
        assert state.generations == %{}
        assert state.slo.requests == 1
        {:reply, :ok, state} = Manager.handle_call({:remove, @id}, self(), state)
        {state, current} = admit(state, @id, @attempt)

        messages = [
          {:finished, @id, @attempt, old, result},
          {:DOWN, monitor, :process, worker, :killed}
        ]

        messages = if order == :death_first, do: Enum.reverse(messages), else: messages

        Enum.each(messages, fn message ->
          assert {:noreply, ^state} = Manager.handle_info(message, state)
        end)

        {:noreply, settled} =
          Manager.handle_info({:finished, @id, @attempt, current, result}, state)

        assert settled.slo.requests == 2
        assert settled.active == %{}
        assert settled.generations == %{}
        assert settled.completed_count == 1

        assert {:noreply, ^settled} =
                 Manager.handle_info({:finished, @id, @attempt, current, result}, settled)
      after
        Process.demonitor(monitor, [:flush])
        shutdown = Process.monitor(worker)
        Process.exit(worker, :kill)

        receive do
          {:DOWN, ^shutdown, :process, ^worker, _reason} -> :ok
        after
          1_000 -> flunk("fixture worker did not terminate")
        end
      end
    end)
  end

  # These are callback histories with synthetic admission state, not real
  # Task.Supervisor/Git histories or native service acceptance.
  @spec admit(Manager.state(), binary(), binary()) :: {Manager.state(), reference()}
  defp admit(state, id, attempt) do
    token = make_ref()

    {%{
       state
       | attempts: Map.put(state.attempts, {id, attempt}, :running),
         active: Map.put(state.active, id, attempt),
         started: Map.put(state.started, {id, attempt}, System.monotonic_time(:microsecond)),
         generations: Map.put(state.generations, {id, attempt}, token)
     }, token}
  end

  @spec neighbor(pos_integer()) :: binary()
  defp neighbor(index),
    do: "33333333-3333-4333-8333-" <> String.pad_leading(Integer.to_string(index), 12, "0")

  # @cc [owner:ghuntley,label:verification;concurrency] manager-history-fixture-isolation
  # Each history MUST exclusively create fresh state, so independent BEAM test
  # runs cannot reuse or remove each other's native helpers, mirrors or receipts.
  @spec with_state((Manager.state() -> term())) :: term()
  defp with_state(fun) do
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

    directory =
      Path.join(System.tmp_dir!(), "enrico-history-#{suffix}")

    File.mkdir!(directory)

    try do
      config = %Config{
        bind: {127, 0, 0, 1},
        port: 1,
        state_dir: directory,
        token: "fixture",
        certificate: "/unused",
        key: "/unused",
        status_socket: "/unused"
      }

      {:ok, state} = Manager.init(config)
      fun.(state)
    after
      File.rm_rf!(directory)
    end
  end
end
