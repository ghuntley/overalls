defmodule Marshall.Control.SocketConcurrencyTest do
  # Mutates the global Marshall.Control.Concurrency configuration.
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen

  alias Marshall.Control.Concurrency
  alias Marshall.ControlSocketDriver, as: Driver

  setup do
    previous = Application.get_env(:marshall, Concurrency)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:marshall, Concurrency, previous),
        else: Application.delete_env(:marshall, Concurrency)
    end)

    :ok
  end

  @spec configure(keyword()) :: :ok
  defp configure(options), do: Application.put_env(:marshall, Concurrency, options)

  test "configuration is typed, defaults to two running and refuses invalid values" do
    assert Concurrency.parse([]) ==
             {:ok, %Concurrency{lilly_running: 2, queue_deadline_ms: 4_000}}

    assert Concurrency.parse(lilly_running: "3") ==
             {:ok, %Concurrency{lilly_running: 3, queue_deadline_ms: 4_000}}

    for invalid <- [
          [lilly_running: 0],
          [lilly_running: 65],
          [lilly_running: "2x"],
          [lilly_running: 2.0],
          [queue_deadline_ms: 0],
          [queue_deadline_ms: 5_001],
          [unknown: 1],
          %{lilly_running: 2},
          [:lilly_running]
        ] do
      assert Concurrency.parse(invalid) == :error
    end

    configure(lilly_running: 0)
    assert_raise ArgumentError, fn -> Concurrency.fetch!() end
    configure(lilly_running: 5)
    limits = Marshall.Control.Service.limits(Marshall.Control.Services.Lilly)
    assert limits.running == 5 and limits.in_flight == 64
  end

  test "services without a running limit keep running every accepted request" do
    for module <- [Marshall.Control.Services.Audi, Marshall.Control.Services.Porsche] do
      limits = Marshall.Control.Service.limits(module)
      assert limits.running == limits.in_flight
    end
  end

  # @cc [owner:ghuntley,label:verification;capacity] control-burst-within-small-pool
  # Fourteen simultaneous exchanges from one host socket, each holding a
  # serializing transaction lock, MUST all complete against a three-connection
  # pool with no checkout timeout and at most two running at once. The same
  # burst with the bound lifted MUST time out checkouts, so the test detects
  # the regression it guards (run 41126173301, ADR-0275).
  test "a fourteen-exchange burst completes against a three-connection pool" do
    repo = start_pool()

    configure(lilly_running: 2)
    {responses, peak} = db_burst(repo, 14)
    assert Enum.sort(Enum.map(responses, &elem(&1, 0))) == Enum.to_list(1..14)
    assert Enum.all?(responses, fn {id, result} -> result == {:ok, %{"n" => id}} end)
    assert peak <= 2

    configure(lilly_running: 14)
    {unbounded, unbounded_peak} = db_burst(repo, 14)
    assert unbounded_peak > 3
    assert Enum.any?(unbounded, &match?({_id, {:error, "queue_timeout"}}, &1))
  end

  test "a request that waited past the queue deadline is refused and never started" do
    configure(lilly_running: 1, queue_deadline_ms: 50)
    state = Driver.bound(%{test: self()})
    {state, []} = Driver.request(state, 1, "stub.wait")
    {state, []} = Driver.request(state, 2, "stub.wait")
    {state, []} = Driver.request(state, 3, "stub.wait")
    assert_receive {:control_stub_started, 1, first}
    Process.sleep(60)

    send(first, :release)
    {state, responses} = Driver.deliver(state, task_reply())

    assert responses == [
             {1, {:ok, %{"n" => 1}}},
             {2, {:error, "temporarily_unavailable"}},
             {3, {:error, "temporarily_unavailable"}}
           ]

    refute_received {:control_stub_started, _, _}
    assert state.tasks == %{} and :queue.is_empty(state.queue)
  end

  test "a request whose task dies is answered unavailable and the next one starts" do
    configure(lilly_running: 1)
    state = Driver.bound(%{test: self()})
    {state, []} = Driver.request(state, 1, "stub.wait")
    {state, []} = Driver.request(state, 2, "stub.wait")
    assert_receive {:control_stub_started, 1, first}
    Process.exit(first, :kill)

    {state, responses} =
      receive do
        {:DOWN, _ref, :process, ^first, _reason} = down -> Driver.deliver(state, down)
      end

    assert responses == [{1, {:error, "unavailable"}}]
    assert_receive {:control_stub_started, 2, second}
    send(second, :release)
    assert {_state, [{2, {:ok, %{"n" => 2}}}]} = Driver.deliver(state, task_reply())
  end

  # @cc [owner:ghuntley,label:verification;protocol] control-bounded-fifo-property
  # For any burst size up to beyond in_flight and any completion order, every
  # request MUST be answered exactly once, accepted requests MUST start in
  # arrival order, at most `running` MUST run at once, and only arrivals past
  # the in_flight bound MUST be refused busy.
  property "bursts start in arrival order within the bound and are answered once",
    test_cases: 100 do
    running = draw("running", integer(1..4))
    burst = draw("burst", integer(1..70))
    configure(lilly_running: running)
    state = Driver.bound(%{test: self()})

    {state, immediate} =
      Enum.reduce(1..burst, {state, []}, fn id, {state, responses} ->
        {state, now} = Driver.request(state, id, "stub.wait")
        {state, responses ++ now}
      end)

    accepted = min(burst, 64)
    assert immediate == for(id <- (accepted + 1)..burst//1, do: {id, {:error, "busy"}})

    {started, answered} = settle(state, accepted, running, %{}, [], [])
    refute_received {:control_stub_started, _, _}
    assert started == Enum.to_list(1..accepted)
    assert Enum.sort(answered) == for(id <- 1..accepted, do: {id, {:ok, %{"n" => id}}})
  end

  # Releases a drawn running task until every accepted request was answered,
  # checking the running bound after each step. `live` maps started ids to
  # their task pids.
  @spec settle(
          map(),
          non_neg_integer(),
          pos_integer(),
          %{integer() => pid()},
          [integer()],
          list()
        ) ::
          {[integer()], list()}
  defp settle(state, accepted, running, live, started, answered) do
    # The socket starts queued work synchronously; wait for exactly the number
    # of task starts the bound allows, never a fixed sleep.
    expected = min(running, accepted - length(answered))
    {live, now_started} = await_started(live, expected, [])
    started = started ++ now_started
    assert map_size(state.tasks) <= running and map_size(live) == expected

    if length(answered) == accepted do
      {started, answered}
    else
      ids = live |> Map.keys() |> Enum.sort()
      pick = Enum.at(ids, draw("release", integer(0..(length(ids) - 1))))
      send(Map.fetch!(live, pick), :release)
      {state, responses} = Driver.deliver(state, task_reply())
      settle(state, accepted, running, Map.delete(live, pick), started, answered ++ responses)
    end
  end

  @spec await_started(%{integer() => pid()}, non_neg_integer(), [integer()]) ::
          {%{integer() => pid()}, [integer()]}
  defp await_started(live, expected, started) when map_size(live) >= expected,
    do: {live, started}

  defp await_started(live, expected, started) do
    receive do
      {:control_stub_started, id, pid} ->
        await_started(Map.put(live, id, pid), expected, started ++ [id])
    after
      5_000 -> flunk("a queued request did not start")
    end
  end

  @spec task_reply() :: {reference(), term()}
  defp task_reply do
    receive do
      {ref, _result} = reply when is_reference(ref) -> reply
    after
      5_000 -> flunk("no task reply")
    end
  end

  @spec start_pool() :: pid()
  defp start_pool do
    options =
      :marshall
      |> Application.fetch_env!(Marshall.Repo)
      |> Keyword.merge(
        name: nil,
        pool: DBConnection.ConnectionPool,
        pool_size: 3,
        queue_target: 20,
        queue_interval: 100
      )

    start_supervised!(%{id: :control_pool, start: {Marshall.Repo, :start_link, [options]}})
  end

  @spec db_burst(pid(), pos_integer()) :: {[Driver.response()], non_neg_integer()}
  defp db_burst(repo, count) do
    state = Driver.bound(%{test: self(), repo: repo})

    state =
      Enum.reduce(1..count, state, fn id, state ->
        {state, []} = Driver.request(state, id, "stub.db")
        state
      end)

    collect(state, count, 0, 0, [])
  end

  @spec collect(map(), non_neg_integer(), integer(), non_neg_integer(), list()) ::
          {list(), non_neg_integer()}
  defp collect(_state, 0, _running, peak, responses), do: {responses, peak}

  defp collect(state, remaining, running, peak, responses) do
    receive do
      {:control_stub_started, _id, _pid} ->
        collect(state, remaining, running + 1, max(peak, running + 1), responses)

      {:control_stub_finished, _id} ->
        collect(state, remaining, running - 1, peak, responses)

      {ref, _result} = reply when is_reference(ref) ->
        {state, now} = Driver.deliver(state, reply)
        collect(state, remaining - length(now), running, peak, responses ++ now)
    after
      15_000 -> flunk("burst did not complete")
    end
  end
end
