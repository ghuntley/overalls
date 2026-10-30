defmodule Marshall.Accounts.AuthEmailWaitingAuthorityPropertyTest do
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen
  require Marshall.CommittedFixtureCleanup, as: Cleanup
  alias Marshall.CommittedMailFixture, as: Fixture
  alias Marshall.ConcurrentSMTPFixture, as: SMTP
  alias Marshall.Repo
  @fixtures Path.expand("../../fixtures/tls", __DIR__)
  @moduletag :distributed
  # Each generated case boots three fresh Marshall peers: 100 cases measured
  # 594 s per property (about 6 s each, 2026-10-30, 8 schedulers), far above the
  # old 180 s aggregate. Every boot, RPC and SMTP deadline below is unchanged;
  # the CI profile only suppresses Hegel's TooSlow health check.
  @moduletag timeout: 1_800_000
  @type peer :: %{controller: pid(), database_name: String.t(), node: node()}
  @type call_result ::
          {:ok, :delivered | :expired | :pending} | {:error, :delivery_failed} | :peer_interrupted

  setup do
    before = unboxed(&Marshall.CommittedFixtureInventory.snapshot/0)

    on_exit(fn ->
      unboxed(fn -> Marshall.CommittedFixtureInventory.assert_restored!(before) end)
    end)

    :ok
  end

  for {kind, name} <- [
        {:removed,
         "generated waiting mail workers refuse removed stored tokens after SMTP rejection"},
        {:expired,
         "generated waiting mail workers refuse expired stored tokens after SMTP rejection"}
      ] do
    # @cc [owner:ghuntley,label:verification;security] mail-waiter-current-token-authority
    # The second independent worker MUST actually wait on the first worker's
    # outbox lock. If stored token authority changes before the first attempt
    # fails, the waiter MUST expire and erase the still-time-valid outbox without
    # another SMTP connection. Independent peers MUST observe terminal refusal.
    property name, profile: :ci, test_cases: 100 do
      kind = unquote(kind)

      replays = draw("replays", integer(1..3))
      ordering = draw("ordering", member_of([[0, 1, 2], [1, 2, 0], [2, 0, 1]]))
      unboxed(fn -> history(kind, replays, ordering) end)
    end
  end

  @spec history(Fixture.invalidation(), pos_integer(), [non_neg_integer()]) :: :ok
  defp history(kind, replays, ordering) do
    server_id = make_ref()
    supervisor_id = make_ref()

    server =
      start_supervised!(
        {SMTP,
         [
           owner: self(),
           mode: :implicit,
           first_reply: "451 synthetic refusal\r\n",
           cert: Path.join(@fixtures, "localhost.pem"),
           key: Path.join(@fixtures, "localhost.key")
         ]},
        id: server_id
      )

    supervisor = start_supervised!(Task.Supervisor, id: supervisor_id)
    peers = Enum.map(1..3, &start_peer(&1, server))
    [first, second, third] = Enum.map(ordering, &Enum.at(peers, &1))
    assert length(Enum.uniq(Enum.map(peers, & &1.node))) == 3
    refute node() in Enum.map(peers, & &1.node)
    fixture = Fixture.enqueue()

    Cleanup.protect Enum.map(peers, & &1.controller) do
      assert fixture.jobs != []
      pending = snapshot(third, fixture.id)
      assert pending.status == :pending
      assert is_binary(pending.ciphertext_digest)
      assert token_state(third, fixture.jti) == :valid
      assert outbox_time_valid?(third, fixture.id)
      started = System.monotonic_time(:millisecond)
      left = Task.Supervisor.async_nolink(supervisor, fn -> deliver(first, fixture.id) end)
      assert_receive {:smtp_accepted, 1, handler}, 5000
      assert_receive {:smtp_data, 1, ^handler, identity}, 5000
      assert is_map(identity)
      assert identity.token == fixture.token_digest
      assert identity.message_id == "<#{fixture.id}@overalls.invalid>"
      right = Task.Supervisor.async_nolink(supervisor, fn -> deliver(second, fixture.id) end)
      await_row_wait(first.database_name, second.database_name)
      assert snapshot(third, fixture.id) == pending
      assert SMTP.connections(server) == 1
      :ok = :peer.call(third.controller, Fixture, :invalidate_token, [fixture.jti, kind], 5000)
      expected = if kind == :removed, do: :absent, else: :expired
      assert token_state(third, fixture.jti) == expected
      assert outbox_time_valid?(third, fixture.id)
      assert snapshot(third, fixture.id) == pending
      refute_receive {:smtp_closed, 1}, 0
      refute_receive {:smtp_unexpected_close, 1}, 0
      refute_receive {:smtp_gate_timeout, 1}, 0
      send(handler, :release)
      assert_receive {:smtp_reply_sent, 1}, 1000
      assert Task.await(left, 15_000) == {:error, :delivery_failed}
      assert System.monotonic_time(:millisecond) - started < 9_000
      assert Task.await(right, 15_000) == {:ok, :expired}
      assert SMTP.connections(server) == 1
      assert snapshot(third, fixture.id) == %{status: :expired, ciphertext_digest: nil}
      assert token_state(third, fixture.jti) == expected

      for peer <- peers, _ <- 1..replays do
        assert deliver(peer, fixture.id) == {:ok, :expired}
        assert snapshot(peer, fixture.id) == %{status: :expired, ciphertext_digest: nil}
      end

      assert SMTP.connections(server) == 1
      refute_receive {:smtp_accepted, _, _}
      refute_receive {:smtp_data, _, _, _}
      refute_receive {:smtp_closed, 1}, 0
      refute_receive {:smtp_unexpected_close, 1}, 0
      refute_receive {:smtp_gate_timeout, 1}, 0
      :ok
    after
      Cleanup.run(
        fn ->
          SMTP.release(server)
          Enum.each(peers, &stop_peer!/1)
          :ok = stop_supervised(supervisor_id)
          Fixture.cleanup(fixture)
        end,
        fn -> :ok = stop_supervised(server_id) end
      )
    end

    :ok
  end

  @spec token_state(peer(), String.t()) :: Fixture.token_state()
  defp token_state(peer, jti) do
    case :peer.call(peer.controller, Fixture, :token_state, [jti], 5000) do
      state when state in [:valid, :expired, :absent] -> state
      _ -> flunk("Mail peer returned an invalid token state")
    end
  end

  @spec outbox_time_valid?(peer(), String.t()) :: boolean()
  defp outbox_time_valid?(peer, id) do
    case :peer.call(peer.controller, Fixture, :outbox_time_valid?, [id], 5000) do
      value when is_boolean(value) -> value
      _ -> flunk("Mail peer returned an invalid outbox-time observation")
    end
  end

  @spec start_peer(pos_integer(), pid()) :: peer()
  defp start_peer(number, server) do
    name = "marshall_committed_mail_#{number}_#{System.unique_integer([:positive])}"

    controller =
      start_supervised!(%{
        id: make_ref(),
        restart: :temporary,
        start:
          {:peer, :start_link,
           [
             %{
               name: String.to_atom(name),
               connection: :standard_io,
               peer_down: :crash,
               args: [~c"+S", ~c"2:2", ~c"+SDcpu", ~c"1", ~c"+SDio", ~c"1"],
               wait_boot: 30_000
             }
           ]}
      })

    :ok = :peer.call(controller, :code, :add_paths, [:code.get_path()])

    config =
      for {app, _, _} <- Application.loaded_applications(),
          app not in [:kernel, :stdlib, :elixir, :logger],
          do: {app, Application.get_all_env(app)}

    :ok = :peer.call(controller, Application, :put_all_env, [config, [persistent: true]])

    repo =
      Application.fetch_env!(:marshall, Repo)
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 4)
      |> Keyword.put(:parameters, application_name: name)

    :ok =
      :peer.call(controller, Application, :put_env, [:marshall, Repo, repo, [persistent: true]])

    :ok =
      :peer.call(controller, Application, :put_env, [:logger, :level, :error, [persistent: true]])

    {:ok, smtp, _} =
      Marshall.Mailer.Config.from_env(%{
        "MARSHALL_SMTP_HOST" => "localhost",
        "MARSHALL_SMTP_PORT" => to_string(SMTP.port(server)),
        "MARSHALL_SMTP_TLS" => "implicit",
        "MARSHALL_SMTP_USERNAME" => "test-user",
        "MARSHALL_SMTP_PASSWORD" => "test-password",
        "MARSHALL_MAIL_FROM" => "noreply@example.test",
        "MARSHALL_SMTP_CA_CERTFILE" => Path.join(@fixtures, "ca.pem")
      })

    :ok =
      :peer.call(controller, Application, :put_env, [
        :marshall,
        Marshall.Mailer,
        smtp,
        [persistent: true]
      ])

    {:ok, _} = :peer.call(controller, Application, :ensure_all_started, [:marshall], 30_000)

    %{
      controller: controller,
      database_name: name,
      node: :peer.call(controller, :erlang, :node, [])
    }
  end

  @spec deliver(peer(), String.t()) :: call_result()
  defp deliver(peer, id) do
    try do
      case :peer.call(peer.controller, Fixture, :deliver, [id], 20_000) do
        {:ok, status} when status in [:delivered, :expired, :pending] -> {:ok, status}
        {:error, :delivery_failed} -> {:error, :delivery_failed}
        _ -> flunk("Mail peer returned an invalid delivery result")
      end
    catch
      :exit, _ -> :peer_interrupted
    end
  end

  @spec snapshot(peer(), String.t()) :: Fixture.snapshot()
  defp snapshot(peer, id) do
    case :peer.call(peer.controller, Fixture, :snapshot, [id], 20_000) do
      %{status: status, ciphertext_digest: digest} = observation
      when status in [:pending, :delivered, :expired] and (is_binary(digest) or is_nil(digest)) ->
        observation

      _ ->
        flunk("Mail peer returned an invalid snapshot")
    end
  end

  @spec stop_peer!(peer()) :: :ok
  defp stop_peer!(peer) do
    reference = Process.monitor(peer.controller)

    try do
      :peer.stop(peer.controller)
    catch
      :exit, {:noproc, _} -> :ok
      :exit, :noproc -> :ok
    end

    receive do
      {:DOWN, ^reference, :process, _, _} -> :ok
    after
      5000 -> flunk("Mail fixture peer failed to retire before cleanup")
    end
  end

  @spec await_row_wait(String.t(), String.t(), non_neg_integer()) :: :ok
  defp await_row_wait(first, second, attempts \\ 100)

  defp await_row_wait(_, _, 0),
    do: flunk("Second mail worker did not wait on the first outbox row lock")

  defp await_row_wait(first, second, attempts) do
    rows =
      Fixture.query(
        """
        SELECT waiting.pid FROM pg_stat_activity waiting
        JOIN pg_stat_activity held ON held.pid=ANY(pg_blocking_pids(waiting.pid))
        WHERE waiting.application_name=$1 AND held.application_name=$2
          AND waiting.wait_event_type='Lock'
          AND waiting.query LIKE '%account_auth_emails%'
          AND waiting.query LIKE '%FOR UPDATE%'
        """,
        [second, first]
      ).rows

    case rows do
      [[_]] ->
        :ok

      _ ->
        receive do
        after
          20 -> await_row_wait(first, second, attempts - 1)
        end
    end
  end

  @spec unboxed((-> value)) :: value when value: term()
  defp unboxed(function), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, function)
end
