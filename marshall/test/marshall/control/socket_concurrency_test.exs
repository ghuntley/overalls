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

  test "only Lilly's session open and execution exchange take the report lane" do
    assert Marshall.Control.Service.priority_ops(Marshall.Control.Services.Lilly) ==
             MapSet.new(["lilly.sessions", "lilly.exchange"])

    for module <- [
          Marshall.Control.Services.Audi,
          Marshall.Control.Services.Galileo,
          Marshall.Control.Services.Porsche,
          Marshall.Control.Services.Ziggy,
          Marshall.Control.Services.Peach
        ] do
      assert Marshall.Control.Service.priority_ops(module) == MapSet.new()
    end
  end

  # @cc [owner:ghuntley,label:verification;capacity] control-report-lane-before-burst
  # An execution exchange arriving behind a utility burst MUST start at the
  # next free running slot, ahead of every queued utility, and MUST NOT add a
  # running slot (run 41179645145: the report aged past capacity freshness
  # while it waited behind the burst, ADR-0275).
  test "a report-lane request starts ahead of a queued utility burst within the bound" do
    configure(lilly_running: 2, queue_deadline_ms: 5_000)
    state = Driver.bound(%{test: self()})

    state =
      Enum.reduce(1..13, state, fn id, state ->
        {state, []} = Driver.request(state, id, "stub.wait")
        state
      end)

    {state, []} = Driver.request(state, 14, "stub.priority")
    assert_receive {:control_stub_started, 1, first}
    assert_receive {:control_stub_started, 2, second}
    assert map_size(state.tasks) == 2
    assert :queue.len(state.queue) == 11 and :queue.len(state.priority) == 1

    send(first, :release)
    {state, [{1, {:ok, %{"n" => 1}}}]} = Driver.deliver(state, task_reply())
    assert_receive {:control_stub_started, 14, exchange}
    refute_received {:control_stub_started, 3, _}
    assert map_size(state.tasks) == 2 and :queue.is_empty(state.priority)

    send(exchange, :release)
    {state, [{14, {:ok, %{"n" => 14}}}]} = Driver.deliver(state, task_reply())
    assert_receive {:control_stub_started, 3, third}
    assert map_size(state.tasks) == 2 and :queue.len(state.queue) == 10
    on_exit(fn -> Enum.each([second, third], &Process.exit(&1, :kill)) end)

    # Running plus both lanes count against in_flight: 2 running, 10 queued,
    # so 52 more priority requests fill 64 and the next one is busy.
    full =
      Enum.reduce(15..66, state, fn id, state ->
        {state, []} = Driver.request(state, id, "stub.priority")
        state
      end)

    assert {_full, [{67, {:error, "busy"}}]} = Driver.request(full, 67, "stub.priority")
  end

  # @cc [owner:ghuntley,label:verification;protocol] control-report-lane-property
  # For any interleaving of utility and report-lane arrivals with releases of
  # running requests, the socket MUST start exactly the request a two-lane
  # model predicts (the oldest queued report-lane request, else the oldest
  # queued utility), never more than `running` at once, and MUST answer every
  # accepted request exactly once.
  property "interleaved lanes start report-lane requests first, each lane in arrival order",
    test_cases: 100 do
    running = draw("running", integer(1..3))
    steps = draw("steps", integer(1..40))
    configure(lilly_running: running, queue_deadline_ms: 5_000)
    state = Driver.bound(%{test: self()})
    model = %{running: running, live: %{}, priority: [], ordinary: [], answered: [], next: 1}

    {state, model} =
      Enum.reduce(1..steps, {state, model}, fn _step, {state, model} ->
        if model.live == %{} or draw("arrive", boolean()) do
          lane_step(state, model, draw("priority", boolean()))
        else
          ids = model.live |> Map.keys() |> Enum.sort()
          release_step(state, model, Enum.at(ids, draw("release", integer(0..(length(ids) - 1)))))
        end
      end)

    model = drain(state, model)
    refute_received {:control_stub_started, _, _}
    accepted = model.next - 1
    assert Enum.sort(model.answered) == Enum.to_list(1..accepted)
  end

  @typep lane_model :: %{
           running: pos_integer(),
           live: %{pos_integer() => pid()},
           priority: [pos_integer()],
           ordinary: [pos_integer()],
           answered: [pos_integer()],
           next: pos_integer()
         }

  # One arrival: it starts at once if a slot is free (both lanes are then
  # empty), otherwise it joins the back of its lane.
  @spec lane_step(map(), lane_model(), boolean()) :: {map(), lane_model()}
  defp lane_step(state, model, priority?) do
    id = model.next
    {state, []} = Driver.request(state, id, if(priority?, do: "stub.priority", else: "stub.wait"))
    model = %{model | next: id + 1}

    model =
      cond do
        map_size(model.live) < model.running ->
          assert model.priority == [] and model.ordinary == []
          started(model, id)

        priority? ->
          %{model | priority: model.priority ++ [id]}

        true ->
          %{model | ordinary: model.ordinary ++ [id]}
      end

    model_matches(state, model)
  end

  # One release: the released request is answered and the model's next
  # request (report lane first) starts in its slot.
  @spec release_step(map(), lane_model(), pos_integer()) :: {map(), lane_model()}
  defp release_step(state, model, id) do
    send(Map.fetch!(model.live, id), :release)
    {state, responses} = Driver.deliver(state, task_reply())
    assert responses == [{id, {:ok, %{"n" => id}}}]
    model = %{model | live: Map.delete(model.live, id), answered: [id | model.answered]}

    model =
      case model do
        %{priority: [next | rest]} -> started(%{model | priority: rest}, next)
        %{ordinary: [next | rest]} -> started(%{model | ordinary: rest}, next)
        _ -> model
      end

    model_matches(state, model)
  end

  @spec started(lane_model(), pos_integer()) :: lane_model()
  defp started(model, id) do
    assert_receive {:control_stub_started, ^id, pid}, 5_000
    %{model | live: Map.put(model.live, id, pid)}
  end

  @spec model_matches(map(), lane_model()) :: {map(), lane_model()}
  defp model_matches(state, model) do
    assert map_size(state.tasks) == map_size(model.live)
    assert map_size(state.tasks) <= model.running
    assert :queue.to_list(state.priority) |> Enum.map(&elem(&1, 0)) == model.priority
    assert :queue.to_list(state.queue) |> Enum.map(&elem(&1, 0)) == model.ordinary
    {state, model}
  end

  @spec drain(map(), lane_model()) :: lane_model()
  defp drain(_state, %{live: live} = model) when map_size(live) == 0, do: model

  defp drain(state, model) do
    id = model.live |> Map.keys() |> Enum.min()
    {state, model} = release_step(state, model, id)
    drain(state, model)
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
