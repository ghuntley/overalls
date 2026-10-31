defmodule Lilly.Host.StorageObserveTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Lilly.Host.{Pool, Storage}
  @moduletag :tmp_dir

  @mutations [:prepare, :ready, :delete, :template_reserve, :template_create, :resize, :other]

  setup %{tmp_dir: directory} do
    File.chmod!(directory, 0o700)

    pool = %Pool{
      id: "11111111-1111-4111-8111-111111111111",
      path: directory,
      filesystem_id: "zfs:1:2"
    }

    %{pool: pool}
  end

  # A fenced read that reports its start and returns `result` after `hold_ms`.
  @spec slow_observe(Pool.t(), pid(), non_neg_integer(), term()) :: Task.t()
  defp slow_observe(pool, test, hold_ms, result) do
    Task.async(fn ->
      Storage.observe(
        pool,
        fn -> :ok end,
        fn _token ->
          send(test, :reading)
          Process.sleep(hold_ms)
          result
        end,
        200
      )
    end)
  end

  # @cc [owner:ghuntley,label:verification;concurrency] fenced-read-never-blocks-mutation
  # While a fenced capacity read runs for 4 s, a transfer section with a 1 s
  # wait MUST acquire the pool lock at once, and the straddled read MUST be
  # withheld as storage_busy rather than reported.
  test "a 4 s fenced read never delays a 1 s section, and is withheld after it", %{pool: pool} do
    observation = slow_observe(pool, self(), 4000, {:ok, :capacity})
    assert_receive :reading, 1000

    started = System.monotonic_time(:millisecond)
    assert Storage.locked(pool, fn -> :received end, 1000) == :received
    assert System.monotonic_time(:millisecond) - started < 500

    assert Task.await(observation, 10_000) == {:error, :storage_busy}
  end

  test "a fenced read with no section during it is reported", %{pool: pool} do
    assert Storage.locked(pool, fn -> :prepared end, 1000, :prepare) == :prepared
    observation = slow_observe(pool, self(), 300, {:ok, :capacity})
    assert Task.await(observation, 5000) == {:ok, :capacity}
    assert Storage.locked(pool, fn -> :after end, 1000) == :after
  end

  test "a held native lock withholds the fenced read before it starts", %{pool: pool} do
    {:ok, owner} = Lilly.Host.Lock.acquire(Path.join(pool.path, ".lilly-storage"))

    try do
      result =
        Task.async(fn ->
          Storage.observe(pool, fn -> :ok end, fn _ -> flunk("read ran") end, 200)
        end)
        |> Task.await(5000)

      assert result == {:error, :storage_busy}
    after
      Lilly.Host.Lock.release(owner)
    end
  end

  # @cc [owner:ghuntley,label:verification;capacity] generation-advance-gates-mutation
  # A mutation section that cannot replace a still-readable generation token
  # MUST NOT run; once the token can change again, sections run.
  test "a section that cannot advance the generation never runs", %{pool: pool} do
    assert Storage.locked(pool, fn -> :first end, 1000) == :first
    path = Path.join([pool.path, ".lilly-storage", "generation"])
    {:ok, token} = Storage.generation(pool)
    File.chmod!(path, 0o400)
    test = self()

    try do
      assert Storage.locked(pool, fn -> send(test, :ran) end, 1000) == {:error, :storage_busy}
      refute_received :ran
      assert Storage.generation(pool) == {:ok, token}
    after
      File.chmod!(path, 0o600)
    end

    assert Storage.locked(pool, fn -> :again end, 1000) == :again
    refute Storage.generation(pool) == {:ok, token}
  end

  # @cc [owner:ghuntley,label:verification;capacity] straddled-observation-never-fresh
  # For any interleaving of mutation sections before, during and after a
  # fenced read, and any read outcome (success or a classification error),
  # observe/4 MUST return the read's outcome exactly when no mutation section
  # began during the read, and storage_busy otherwise. Snapshot sections
  # during the read do not withhold it.
  @tag :hegel
  test "an observation straddling a mutation is never reported", %{pool: pool} do
    Hegel.check(
      fn ->
        before = draw("before", list_of(member_of(@mutations), max_length: 2))
        during = draw("during", list_of(member_of(@mutations ++ [:snapshot]), max_length: 3))
        outcome = draw("outcome", member_of([{:ok, :capacity}, {:error, :owner_set}]))
        test = self()
        tag = make_ref()

        for kind <- before, do: :ok = Storage.locked(pool, fn -> :ok end, 1000, kind)

        observation =
          Task.async(fn ->
            Storage.observe(
              pool,
              fn -> :ok end,
              fn _token ->
                send(test, {tag, :reading})

                receive do
                  {^tag, :go} -> outcome
                end
              end,
              200
            )
          end)

        assert_receive {^tag, :reading}, 2000
        for kind <- during, do: :ok = Storage.locked(pool, fn -> :ok end, 1000, kind)
        send(observation.pid, {tag, :go})
        result = Task.await(observation, 5000)

        if Enum.any?(during, &(&1 != :snapshot)),
          do: assert(result == {:error, :storage_busy}),
          else: assert(result == outcome)
      end,
      test_cases: 100
    )
  end
end
