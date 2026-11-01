defmodule Brady.CacheHistoryTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen

  alias Brady.Cache
  alias Brady.Cache.{Budget, Policy, Store}
  alias Brady.HTTP.Head

  @now 1_600_000_000
  @limits %{quota: 10_000_000, object: 1_000_000, high: 9_000_000, low: 8_000_000}
  @outcomes [:complete, :short, :overflow, :abort, :owner_loss, :cache_loss]
  @type identity :: 0..6
  @type outcome :: :complete | :short | :overflow | :abort | :owner_loss | :cache_loss
  @type entry :: %{
          body: binary(),
          stored: integer(),
          expires: integer(),
          age: non_neg_integer(),
          etag: String.t()
        }
  @type state :: %{
          root: String.t(),
          supervisor: pid(),
          store: pid(),
          now: integer(),
          writable: boolean(),
          entries: %{identity() => entry()}
        }
  @type command ::
          {:download, identity(), outcome(), binary(), pos_integer(), non_neg_integer(),
           non_neg_integer()}
          | {:advance, pos_integer()}
          | :restart
          | :pressure
          | :resume

  defmodule Owner do
    @moduledoc false
    use GenServer

    @type command ::
            {:begin, Policy.request(), Head.head(), integer(), integer()}
            | {:append, reference(), binary()}
            | {:commit, reference()}
            | {:abort, reference()}
            | {:lookup, Policy.request(), integer()}
            | {:read, reference(), non_neg_integer(), pos_integer()}
            | {:close, reference()}
    @type reply ::
            :ok
            | :bypass
            | :miss
            | :eof
            | {:ok, reference() | binary()}
            | {:error, :storage}
            | {:hit, reference(), Head.head(), non_neg_integer(), non_neg_integer()}

    @spec start_link(pid()) :: GenServer.on_start()
    def start_link(store), do: GenServer.start_link(__MODULE__, store)

    @spec call(pid(), command()) :: reply()
    def call(owner, command), do: GenServer.call(owner, command)

    @impl true
    def init(store), do: {:ok, store}

    @impl true
    def handle_call(command, _from, store) do
      result =
        case command do
          {:begin, request, head, sent, received} ->
            Cache.begin_write(store, request, head, sent, received)

          {:append, ref, bytes} ->
            Cache.append(store, ref, bytes)

          {:commit, ref} ->
            Cache.commit(store, ref)

          {:abort, ref} ->
            Cache.abort(store, ref)

          {:lookup, request, now} ->
            Cache.lookup(store, request, now)

          {:read, ref, offset, size} ->
            Store.read(store, ref, offset, size)

          {:close, ref} ->
            Cache.close(store, ref)
        end

      {:reply, result, store}
    end
  end

  # @cc [owner:ghuntley,label:verification] brady-history-independent-bytes
  # The model MUST derive reusable bytes and freshness only from generated public
  # responses and completed owner operations, never Policy/Range/key decisions.
  # Every history MUST exercise each interrupted publication outcome and restart;
  # asserted hits MUST stream the exact modeled origin/variant bytes from disk.
  # Each history restarts the cache store, so generation is I/O-bound: under
  # host load the default profile's TooSlow health check failed it (only 7
  # inputs in 31 s, 2026-11-01). The :ci profile suppresses only that check;
  # every generated history is still asserted.
  property "public download histories publish only complete current origin and variant bytes",
    profile: :ci do
    body = draw("body", binary(min_length: 2, max_length: 96))
    commands = draw("commands", list_of(command(), min_length: 8, max_length: 20))

    with_store(fn state ->
      mandatory =
        Enum.with_index(@outcomes, fn outcome, id ->
          {:download, id, outcome, body <> <<id>>, 80, id, 1}
        end)

      complete = for id <- 0..6, do: {:download, id, :complete, body <> <<id>>, 80, 0, 0}

      history =
        [:resume] ++
          mandatory ++
          [:resume] ++
          complete ++
          [:restart] ++
          commands ++
          [:restart, {:advance, 100}, :resume] ++ complete ++ [:pressure, :resume]

      Enum.reduce(history, state, fn command, current ->
        current |> step(command) |> assert_model()
      end)
    end)
  end

  # @cc [owner:ghuntley,label:verification] brady-history-current-privacy
  # Current credential/conditional refusals MUST hold before and after complete
  # publication and Store restart, including mixed-case duplicate headers and
  # ranges. Refused writes MUST leave the real object inventory unchanged.
  property "current private requests and responses cannot consume or populate shared objects" do
    body = draw("body", binary(min_length: 2, max_length: 128))
    order = draw("order", shuffle(Enum.to_list(0..11)))
    uppercase = draw("uppercase", boolean())

    with_store(fn state ->
      state = step(state, :resume)
      request = request(0)
      response = response(body, state.now, 80, 0)
      private = private_requests(request, uppercase)

      assert_private(state, private, response, order)
      state = step(state, {:download, 0, :complete, body, 80, 0, 0}) |> assert_model()
      assert_private(state, private, response, order)
      state = step(state, :restart) |> assert_model() |> step(:resume)
      assert_private(state, private, response, Enum.reverse(order))

      for headers <- [[{"range", "bytes=1-"}], [{"if-range", "\"fixture\""}]] do
        before = inventory(state)
        ranged = add_headers(request(6), headers)
        assert :bypass = Cache.begin_write(state.store, ranged, response, @now, @now)
        assert inventory(state) == before
      end

      for headers <- [
            [{"set-cookie", "fixture-only"}],
            [{"cache-control", "private"}],
            [{"cache-control", "no-store"}],
            [{"cache-control", "max-age=80"}],
            [{"vary", "*"}],
            [{"age", "0"}, {"age", "0"}]
          ] do
        before = inventory(state)
        rejected = %{response | headers: response.headers ++ headers}
        assert :bypass = Cache.begin_write(state.store, request(6), rejected, @now, @now)
        assert inventory(state) == before
      end

      assert_model(state)
    end)
  end

  # @cc [owner:ghuntley,label:verification] brady-history-owner-pins
  # Foreign process calls MUST NOT read or close an owner's read lease. Pressure
  # MUST retain that owner's exact bytes until close or owner death; a later
  # pressure observation MUST reclaim the now-unpinned object before recovery.
  property "reader ownership survives pressure and releases on close or process loss" do
    body = draw("body", binary(min_length: 2, max_length: 128))
    endings = draw("endings", shuffle([:close, :owner_loss]))

    with_store(fn state ->
      Enum.reduce(endings, state, fn ending, state ->
        state = state |> step(:resume) |> step({:download, 0, :complete, body, 80, 0, 0})
        state = step(state, {:download, 1, :complete, body <> "other", 80, 0, 0})
        owner = start_owner(state)
        {:hit, ref, _, 0, length} = Owner.call(owner, {:lookup, request(0), state.now})
        assert {:error, :storage} = Store.read(state.store, ref, 0, length)
        assert :ok = Cache.close(state.store, ref)
        assert Store.stats(state.store).readers == 1

        assert :ok = Store.observe(state.store, 10, 100, true)
        assert %{objects: 1, readers: 1, writable: false} = Store.stats(state.store)
        assert :miss = Cache.lookup(state.store, request(1), state.now)
        assert {:ok, ^body} = Owner.call(owner, {:read, ref, 0, length})

        case ending do
          :close -> assert :ok = Owner.call(owner, {:close, ref})
          :owner_loss -> kill_and_drain(owner)
        end

        await_leases(state.store, 0, 0)
        assert :ok = Store.observe(state.store, 10, 100, true)
        assert %{objects: 0, used: 0} = Store.stats(state.store)
        stop_owner(owner)
        %{state | entries: %{}, writable: false} |> step(:restart) |> assert_model()
      end)
    end)
  end

  @spec command() :: Hegel.Gen.t()
  defp command do
    frequency([
      {5,
       gen all(
             id <- integer(0..6),
             outcome <- member_of(@outcomes),
             body <- binary(min_length: 2, max_length: 96),
             ttl <- integer(30..80),
             age <- integer(0..5),
             delay <- integer(0..3)
           ) do
         {:download, id, outcome, body, ttl, age, delay}
       end},
      {2, map(integer(1..90), &{:advance, &1})},
      {1, member_of([:restart, :pressure, :resume])}
    ])
  end

  @spec step(state(), command()) :: state()
  defp step(state, {:advance, seconds}), do: %{state | now: state.now + seconds}

  defp step(state, :pressure) do
    assert :ok = Store.observe(state.store, 10, 100, true)
    %{state | writable: false, entries: %{}}
  end

  defp step(state, :resume) do
    assert :ok = Store.observe(state.store, 90, 100, true)
    %{state | writable: true}
  end

  defp step(state, :restart) do
    kill_and_drain(state.store)
    assert :miss = Cache.lookup(state.store, request(0), state.now)
    store = start_store(state.supervisor, state.root)
    assert %{writers: 0, readers: 0, pending: 0, writable: false} = Store.stats(store)
    assert File.ls!(Path.join(state.root, "tmp")) == []
    %{state | store: store, writable: false}
  end

  defp step(state, {:download, id, outcome, body, ttl, age, delay}) do
    sent = state.now
    state = %{state | now: sent + delay} |> assert_model()
    # Refresh an explicit component pressure input; this is not native ZFS proof.
    if state.writable, do: Store.observe(state.store, 90, 100, true)
    owner = start_owner(state)
    head = response(body, sent, ttl, age)
    result = Owner.call(owner, {:begin, request(id), head, sent, state.now})

    try do
      if state.writable and not Map.has_key?(state.entries, id) do
        assert {:ok, ref} = result
        before = Store.stats(state.store)
        assert :bypass = Cache.append(state.store, ref, "foreign")
        assert :bypass = Cache.commit(state.store, ref)
        assert :ok = Cache.abort(state.store, ref)
        assert Store.stats(state.store) == before
        assert :miss = Cache.lookup(state.store, request(id), state.now)
        cut = div(byte_size(body), 2)
        assert :ok = Owner.call(owner, {:append, ref, binary_part(body, 0, cut)})
        assert :miss = Cache.lookup(state.store, request(id), state.now)
        finish_download(state, owner, ref, id, outcome, body, cut, ttl, age + delay, head)
      else
        assert :bypass = result
        state
      end
    after
      stop_owner(owner)
    end
  end

  @spec finish_download(
          state(),
          pid(),
          reference(),
          identity(),
          outcome(),
          binary(),
          non_neg_integer(),
          pos_integer(),
          non_neg_integer(),
          Head.head()
        ) :: state()
  defp finish_download(state, owner, ref, id, :complete, body, cut, ttl, age, head) do
    assert :ok = Owner.call(owner, {:append, ref, binary_part(body, cut, byte_size(body) - cut)})
    assert :ok = Owner.call(owner, {:commit, ref})
    assert :bypass = Owner.call(owner, {:append, ref, "late"})
    assert :bypass = Owner.call(owner, {:commit, ref})

    entry = %{
      body: body,
      stored: state.now,
      expires: state.now + ttl - age,
      age: age,
      etag: List.keyfind(head.headers, "etag", 0) |> elem(1)
    }

    %{state | entries: Map.put(state.entries, id, entry)}
  end

  defp finish_download(state, owner, ref, _id, outcome, body, _cut, _ttl, _age, _head) do
    case outcome do
      :short -> assert :bypass = Owner.call(owner, {:commit, ref})
      :overflow -> assert :bypass = Owner.call(owner, {:append, ref, body})
      :abort -> assert :ok = Owner.call(owner, {:abort, ref})
      :owner_loss -> kill_and_drain(owner)
      :cache_loss -> :ok
    end

    state = if outcome == :cache_loss, do: step(state, :restart), else: state
    assert :bypass = Cache.append(state.store, ref, "stale")
    assert :bypass = Cache.commit(state.store, ref)
    await_leases(state.store, 0, 0)
    state
  end

  @spec assert_model(state()) :: state()
  defp assert_model(state) do
    entries = Map.filter(state.entries, fn {_, entry} -> state.now < entry.expires end)

    for id <- 0..6 do
      case entries[id] do
        nil ->
          assert :miss = Cache.lookup(state.store, request(id), state.now)

        entry ->
          assert_read(state, request(id), entry.body, 200, entry)
          headers = [{"range", "bytes=1-"}, {"if-range", entry.etag}]
          partial = binary_part(entry.body, 1, byte_size(entry.body) - 1)
          assert_read(state, add_headers(request(id), headers), partial, 206, entry)

          assert :miss =
                   Cache.lookup(
                     state.store,
                     add_headers(request(id), [{"range", "bytes=1-"}, {"if-range", "\"other\""}]),
                     state.now
                   )
      end
    end

    assert %{pending: 0, writers: 0, readers: 0, objects: count} = Store.stats(state.store)
    assert count == map_size(entries)
    assert File.ls!(Path.join(state.root, "tmp")) == []

    assert disk_bodies(state.root) ==
             Enum.sort(Enum.map(entries, fn {_, entry} -> entry.body end))

    %{state | entries: entries}
  end

  @spec assert_read(state(), Policy.request(), binary(), pos_integer(), entry()) :: :ok
  defp assert_read(state, request, expected, status, entry) do
    assert {:hit, ref, head, offset, length} = Cache.lookup(state.store, request, state.now)

    try do
      assert head.status == status
      assert head.body == {:length, byte_size(expected)}
      assert {"age", Integer.to_string(entry.age + state.now - entry.stored)} in head.headers
      parent = self()
      tag = make_ref()

      assert :ok =
               Cache.stream(state.store, ref, offset, length, fn bytes ->
                 send(parent, {tag, bytes})
                 :ok
               end)

      assert_receive {^tag, ^expected}
      refute_receive {^tag, _}, 0
      :ok
    after
      Cache.close(state.store, ref)
    end
  end

  @spec assert_private(state(), [Policy.request()], Head.head(), [non_neg_integer()]) :: :ok
  defp assert_private(state, private, response, order) do
    for index <- order do
      request = Enum.fetch!(private, index)
      before = inventory(state)
      assert :miss = Cache.lookup(state.store, request, state.now)
      assert :bypass = Cache.begin_write(state.store, request, response, @now, @now)
      assert inventory(state) == before
    end

    :ok
  end

  @spec private_requests(Policy.request(), boolean()) :: [Policy.request()]
  defp private_requests(request, uppercase) do
    names =
      ~w(authorization proxy-authorization cookie x-api-key if-match if-none-match if-modified-since cache-control pragma)

    headers =
      Enum.map(names, fn name ->
        mixed = if uppercase, do: String.upcase(name), else: name
        add_headers(request, [{mixed, "fixture-only"}, {name, "second"}, {"range", "bytes=1-"}])
      end)

    headers ++
      [
        %{request | target: "/image?signature=fixture"},
        %{request | method: "POST"},
        add_headers(request, [{"if-unmodified-since", "fixture-only"}])
      ]
  end

  @spec request(identity()) :: Policy.request()
  defp request(id) do
    base = %{
      method: "GET",
      scheme: :https,
      host: "packages.example",
      port: 443,
      target: "/image",
      headers: []
    }

    case id do
      0 -> base
      1 -> %{base | headers: [{"accept-encoding", ""}]}
      2 -> %{base | headers: [{"accept-encoding", "gzip"}]}
      3 -> %{base | host: "other.example"}
      4 -> %{base | scheme: :http}
      5 -> %{base | port: 8443}
      6 -> %{base | target: "/other"}
    end
  end

  @spec response(binary(), integer(), pos_integer(), non_neg_integer()) :: Head.head()
  defp response(body, sent, ttl, age) do
    date = sent |> DateTime.from_unix!() |> Calendar.strftime("%a, %d %b %Y %H:%M:%S GMT")
    etag = "\"" <> Base.encode16(:crypto.hash(:sha256, body), case: :lower) <> "\""

    %{
      status: 200,
      body: {:length, byte_size(body)},
      headers: [
        {"date", date},
        {"cache-control", "public, max-age=#{ttl}"},
        {"age", Integer.to_string(age)},
        {"vary", "accept-encoding"},
        {"etag", etag}
      ]
    }
  end

  @spec add_headers(Policy.request(), Policy.headers()) :: Policy.request()
  defp add_headers(request, headers), do: %{request | headers: request.headers ++ headers}

  @spec inventory(state()) :: {map(), [{String.t(), binary()}]}
  defp inventory(state) do
    files =
      state.root
      |> Path.join("{objects,tmp}/**/*")
      |> Path.wildcard()
      |> Enum.filter(&File.regular?/1)
      |> Enum.map(&{Path.relative_to(&1, state.root), File.read!(&1)})

    {Store.stats(state.store), files}
  end

  @spec disk_bodies(String.t()) :: [binary()]
  defp disk_bodies(root),
    do:
      root
      |> Path.join("objects/*/*/body")
      |> Path.wildcard()
      |> Enum.map(&File.read!/1)
      |> Enum.sort()

  @spec with_store((state() -> term())) :: term()
  defp with_store(fun) do
    id = make_ref()
    suffix = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    root = Path.join(System.tmp_dir!(), "brady-history-#{suffix}")
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one}, id: id)

    try do
      store = start_store(supervisor, root)

      fun.(%{
        root: root,
        supervisor: supervisor,
        store: store,
        now: @now,
        writable: false,
        entries: %{}
      })
    after
      stop_supervised!(id)
      File.rm_rf!(root)
      refute File.exists?(root)
    end
  end

  @spec start_store(pid(), String.t(), Budget.limits()) :: pid()
  defp start_store(supervisor, root, limits \\ @limits) do
    spec = Supervisor.child_spec({Store, root: root, limits: limits}, restart: :temporary)
    {:ok, store} = DynamicSupervisor.start_child(supervisor, spec)
    store
  end

  @spec start_owner(state()) :: pid()
  defp start_owner(state) do
    spec = Supervisor.child_spec({Owner, state.store}, restart: :temporary)
    {:ok, owner} = DynamicSupervisor.start_child(state.supervisor, spec)
    owner
  end

  @spec kill_and_drain(pid()) :: :ok
  defp kill_and_drain(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 2_000
    refute Process.alive?(pid)
    :ok
  end

  @spec stop_owner(pid()) :: :ok
  defp stop_owner(owner) do
    if Process.alive?(owner), do: GenServer.stop(owner)
    :ok
  end

  @spec await_leases(pid(), non_neg_integer(), non_neg_integer()) :: :ok
  defp await_leases(store, readers, writers),
    do: await_leases(store, readers, writers, System.monotonic_time(:millisecond) + 2_000)

  @spec await_leases(pid(), non_neg_integer(), non_neg_integer(), integer()) :: :ok
  defp await_leases(store, readers, writers, deadline) do
    stats = Store.stats(store)

    if stats.readers == readers and stats.writers == writers do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline
      await_leases(store, readers, writers, deadline)
    end
  end
end
