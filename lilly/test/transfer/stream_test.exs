defmodule Lilly.Transfer.StreamTest do
  # Unit coverage of the hostd client (ADR-0183). Real `zfs send`/`receive`
  # streams, cross-host pulls and the root/service-uid split run in the
  # zfs-guest, zfs-transfer and export-endpoint NixOS machine tests.
  use ExUnit.Case, async: true
  alias Lilly.Host.Lock
  alias Lilly.Transfer.Stream
  @moduletag :tmp_dir

  # A loopback listener that never accepts: the TCP handshake completes in
  # its backlog but no SSH banner ever arrives, so an SSH producer stalls
  # until the stream deadline or its owner's death. Loopback works in a
  # network-less build sandbox, where an unroutable address fails at once.
  @unreachable "127.0.0.1"

  setup %{tmp_dir: dir} do
    File.chmod!(dir, 0o700)
    expected = Path.join(dir, "expected")
    File.write!(expected, "lilly-probe-v3 challenge\n")
    {:ok, silent} = :gen_tcp.listen(0, [:binary, ip: {127, 0, 0, 1}, active: false])
    {:ok, port} = :inet.port(silent)
    {:ok, closed} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, refused} = :inet.port(closed)
    :ok = :gen_tcp.close(closed)

    %{
      dir: dir,
      ownership: Path.join(dir, "transfer"),
      expected: expected,
      port: port,
      refused: refused
    }
  end

  defp ssh(c, address, port \\ nil) do
    {:ssh,
     %{
       address: address,
       port: port || c.port,
       source_host: "33333333-4444-4555-8666-777777777777",
       relocation: "22222222-3333-4444-8555-666666666666",
       identity: Path.join(c.dir, "id_ed25519"),
       known_hosts: Path.join(c.dir, "known_hosts"),
       verb: {:probe, "66666666-7777-4888-8999-aaaaaaaaaaaa"}
     }}
  end

  defp compare(c), do: {:compare, c.expected}

  defp eventually(function, deadline) do
    case function.() do
      false ->
        assert System.monotonic_time(:millisecond) < deadline

        receive do
        after
          10 -> eventually(function, deadline)
        end

      value ->
        value
    end
  end

  defp reacquirable(directory) do
    eventually(
      fn ->
        case Lock.acquire(directory) do
          {:ok, lock} -> Lock.release(lock) == :ok
          {:error, _} -> false
        end
      end,
      System.monotonic_time(:millisecond) + 10_000
    )
  end

  test "the stream deadline kills the pipeline and releases the lease", c do
    started = System.monotonic_time(:millisecond)

    assert {:error, :stream_timeout} =
             Stream.run(c.ownership, ssh(c, @unreachable), compare(c), 1000)

    assert System.monotonic_time(:millisecond) - started < 10_000
    assert reacquirable(c.ownership)
  end

  test "a failed side is a closed observation and progress starts at zero", c do
    # Nothing listens on this loopback port, and no key exists: ssh fails.
    owner = self()

    assert {:error, reason} =
             Stream.run(c.ownership, ssh(c, "127.0.0.1", c.refused), compare(c), 10_000, 0, owner)

    # Depending on which side observes the refused SSH connection first, the
    # pipeline reports the producer, children, or consumer failure.  All three
    # are closed observations and must release the lease.
    assert reason in [:stream_producer_failed, :stream_children_failed, :stream_consumer_failed]
    assert_received {:lilly_transfer_progress, ^owner, 0}
    assert reacquirable(c.ownership)
  end

  test "owner death revokes the stream and contention cannot start a second", c do
    task =
      Task.async(fn -> Stream.run(c.ownership, ssh(c, @unreachable), compare(c), 60_000) end)

    try do
      eventually(
        fn -> File.exists?(Path.join(c.ownership, "progress")) end,
        System.monotonic_time(:millisecond) + 10_000
      )

      assert {:error, :stream_busy} =
               Stream.run(c.ownership, ssh(c, @unreachable), compare(c), 1000)

      inode = File.stat!(Path.join(c.ownership, "owner.lock")).inode
      Task.shutdown(task, :brutal_kill)
      assert reacquirable(c.ownership)
      assert File.stat!(Path.join(c.ownership, "owner.lock")).inode == inode
    after
      Task.shutdown(task, :brutal_kill)
    end
  end

  test "out-of-grammar fields are refused by hostd before anything runs", c do
    for producer <- [
          ssh(c, "-oProxyCommand=x"),
          {:ssh, %{elem(ssh(c, @unreachable), 1) | identity: "relative/key"}},
          {:local_send, %{dataset: "-o/x", placement: "11111111-2222-4333-8444-555555555555"}},
          {:local_send, %{dataset: "pool/lilly", placement: "not-a-uuid"}}
        ] do
      assert {:error, :invalid_stream} = Stream.run(c.ownership, producer, compare(c), 1000)
    end

    assert reacquirable(c.ownership)
  end

  test "bad bounds and a held lock fail before contacting hostd", c do
    assert {:error, :invalid_stream} =
             Stream.run(c.ownership, ssh(c, @unreachable), compare(c), 999)

    assert {:error, :invalid_stream} =
             Stream.run(c.ownership, ssh(c, @unreachable), compare(c), 1000, -1)

    refute File.exists?(c.ownership)
    {:ok, lock} = Lock.acquire(c.dir)

    try do
      assert {:error, :invalid_stream} =
               Stream.run(c.ownership, ssh(c, @unreachable), compare(c), 1000)

      refute File.exists?(c.ownership)
    after
      Lock.release(lock)
    end
  end
end
