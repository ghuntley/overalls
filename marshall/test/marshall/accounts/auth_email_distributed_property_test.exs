defmodule Marshall.Accounts.AuthEmailDistributedPropertyTest do
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen
  require Marshall.CommittedFixtureCleanup, as: Cleanup
  alias Marshall.CommittedMailFixture, as: Fixture
  alias Marshall.ConcurrentSMTPFixture, as: SMTP
  alias Marshall.Repo
  @fixtures Path.expand("../../fixtures/tls", __DIR__)
  @moduletag :distributed
  @moduletag timeout: 180_000

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

  for {crash?, phase, name} <- [
        {false, :pre_ack,
         "generated committed mail contention sends once and independently erases payload"},
        {true, :pre_ack,
         "generated mail owner crashes release committed row and preserve uncertain retry identity"},
        {true, :post_ack,
         "generated post-ack mail owner crashes preserve pending identity until retry commits"}
      ] do
    # @cc [owner:ghuntley,label:verification;concurrency] mail-three-independent-workers
    # Each history MUST use three independent Marshall BEAMs with separate real
    # PostgreSQL pools. The second worker MUST demonstrably wait on the first
    # worker's outbox row; the third MUST observe committed pending state before
    # release and terminal erased state afterward. An intentional peer crash
    # MUST be observed independently of the interrupted RPC.
    if phase == :post_ack do
      @tag :post_ack
    end

    # Real three/four-BEAM cases measured 8-14s each; 100 cases require more
    # than the old 180s aggregate. Every existing boot/RPC/SMTP deadline remains.
    # At hegel-erlang 44b4c8e / engine 0.43.7, CI derandomizes (one fixed seed for
    # every property: hegel_ex sets no database key; HEGEL_SEED overrides it),
    # disables the example database and only suppresses TooSlow; shrinking/blob replay remain.
    @tag timeout: 1_800_000
    property name, profile: :ci, test_cases: 100 do
      crash? = unquote(crash?)
      phase = unquote(phase)

      replays = draw("replays", integer(1..3))
      ordering = draw("ordering", member_of([[0, 1, 2], [1, 2, 0], [2, 0, 1]]))
      unboxed(fn -> history(crash?, replays, ordering, phase) end)
    end
  end

  # @cc [owner:ghuntley,label:verification;recovery] mail-retry-sender-rotation-identity
  # A retry after an accepted SMTP attempt loses its database commit MUST retain
  # the delivery's Message-ID even when the successor's sender domain changes.
  # The separate committed observer MUST still see pending ciphertext before retry.
  @tag :sender_rotation
  # This also boots four real BEAMs per case. Keep all 100 cases under the same
  # pinned CI settings and finite aggregate as the crash histories above.
  @tag timeout: 1_800_000
  property "generated pending mail retries retain Message-ID across sender-domain rotation",
    profile: :ci,
    test_cases: 100 do
    replays = draw("replays", integer(1..3))
    ordering = draw("ordering", member_of([[0, 1, 2], [1, 2, 0], [2, 0, 1]]))

    sender_domain =
      draw("sender_domain", member_of(["retry.example.test", "alternate.example.test"]))

    unboxed(fn -> history(true, replays, ordering, :post_ack, sender_domain) end)
  end

  @spec history(
          boolean(),
          pos_integer(),
          [non_neg_integer()],
          :pre_ack | :post_ack,
          String.t() | nil
        ) :: :ok
  defp history(crash?, replays, ordering, phase, sender_domain \\ nil) do
    server_id = make_ref()
    supervisor_id = make_ref()

    server =
      Overalls.HegelFixtures.start_supervised!(
        {SMTP,
         [
           owner: self(),
           mode: :implicit,
           cert: Path.join(@fixtures, "localhost.pem"),
           key: Path.join(@fixtures, "localhost.key")
         ]},
        id: server_id
      )

    supervisor = Overalls.HegelFixtures.start_supervised!(Task.Supervisor, id: supervisor_id)
    peers = Enum.map(1..3, fn number -> start_peer(number, server) end)
    [first, second, third] = Enum.map(ordering, &Enum.at(peers, &1))
    assert length(Enum.uniq(Enum.map(peers, & &1.node))) == 3
    refute node() in Enum.map(peers, & &1.node)
    fixture = Fixture.enqueue()
    Hegel.on_cleanup(fn -> cleanup_case(peers, fixture) end)
    on_exit(:committed_mail_history_rows, fn -> cleanup_case(peers, fixture) end)

    Cleanup.protect Enum.map(peers, & &1.controller) do
      assert fixture.jobs != []
      pending = snapshot(third, fixture.id)
      assert pending.status == :pending
      assert is_binary(pending.ciphertext_digest)
      fence = make_ref()

      left =
        Task.Supervisor.async_nolink(supervisor, fn ->
          if phase == :post_ack,
            do: deliver_before_commit(first, fixture.id, fence),
            else: deliver(first, fixture.id)
        end)

      assert_receive {:smtp_accepted, 1, handler}, 5000
      assert_receive {:smtp_data, 1, ^handler, identity}, 5000
      assert is_map(identity)
      assert identity.token == fixture.token_digest

      if is_nil(sender_domain) do
        assert identity.message_id == "<#{fixture.id}@overalls.invalid>"
      else
        # Rotation's identity oracle compares the actual first and retry
        # messages; it does not depend on the namespace chosen by the repair.
        assert String.starts_with?(identity.message_id, "<#{fixture.id}@")
        assert String.ends_with?(identity.message_id, ">")
      end

      if phase == :post_ack do
        send(handler, :release)
        assert await_commit_gate(first, fence) == {:entered, true, true, true}
        # The separate pool still sees pending ciphertext after actual SMTP
        # acceptance and the uncommitted status/payload write.
        assert snapshot(third, fixture.id) == pending
      end

      if is_binary(sender_domain) do
        sender = {"Overalls", "no-reply@" <> sender_domain}

        assert :peer.call(second.controller, Application, :put_env, [
                 :marshall,
                 :mail_from,
                 sender
               ]) == :ok

        assert :peer.call(second.controller, Application, :fetch_env!, [:marshall, :mail_from]) ==
                 sender
      end

      right = Task.Supervisor.async_nolink(supervisor, fn -> deliver(second, fixture.id) end)
      await_row_wait(first.database_name, second.database_name)
      assert snapshot(third, fixture.id) == pending
      assert SMTP.connections(server) == 1

      if crash? do
        reference = Process.monitor(first.controller)
        # halt, unlike peer.stop, skips orderly application shutdown.
        try do
          :peer.call(first.controller, :erlang, :halt, [137], 5000)
        catch
          :exit, _ -> :ok
        end

        assert_receive {:DOWN, ^reference, :process, _, {:exit_status, 137}}, 5000
        if phase == :pre_ack, do: assert_receive({:smtp_closed, 1}, 5000)
        assert Task.await(left, 5000) == :peer_interrupted
        assert Task.await(right, 15_000) == {:ok, :delivered}
        assert_receive {:smtp_accepted, 2, retry_handler}, 1000
        assert_receive {:smtp_data, 2, ^retry_handler, retry_identity}, 1000
        assert retry_identity == identity
        assert SMTP.connections(server) == 2
      else
        send(handler, :release)
        assert Task.await(left, 15_000) == {:ok, :delivered}
        assert Task.await(right, 15_000) == {:ok, :delivered}
        assert SMTP.connections(server) == 1
      end

      assert snapshot(third, fixture.id) == %{status: :delivered, ciphertext_digest: nil}

      if crash? do
        replacement = start_peer(4, server)

        Cleanup.protect [replacement.controller] do
          refute replacement.node in Enum.map(peers, & &1.node)
          terminal_replays(replacement, fixture.id, replays, server)
        after
          stop_peer!(replacement)
        end
      else
        terminal_replays(third, fixture.id, replays, server)
      end

      :ok
    after
      Cleanup.run(
        fn ->
          SMTP.release(server)
          Enum.each(peers, &stop_peer!/1)
          # Only after every remote worker is retired may its coordinator stop.
          :ok = stop_supervised(supervisor_id)
          Fixture.cleanup(fixture)
        end,
        fn ->
          :ok = stop_supervised(server_id)
        end
      )
    end

    :ok
  end

  @spec start_peer(pos_integer(), pid()) :: peer()
  defp start_peer(number, server) do
    name = "marshall_committed_mail_#{number}_#{System.unique_integer([:positive])}"

    controller =
      Overalls.HegelFixtures.start_supervised!(%{
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

    on_exit({:committed_mail_peer, controller}, fn -> stop_controller!(controller) end)

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

  @spec deliver_before_commit(peer(), String.t(), reference()) :: call_result()
  defp deliver_before_commit(peer, id, fence) do
    try do
      case :peer.call(
             peer.controller,
             Fixture,
             :deliver_before_commit,
             [id, fence],
             20_000
           ) do
        {:ok, status} when status in [:delivered, :expired, :pending] -> {:ok, status}
        {:error, :delivery_failed} -> {:error, :delivery_failed}
        _ -> flunk("Mail peer returned an invalid gated delivery result")
      end
    catch
      :exit, _ -> :peer_interrupted
    end
  end

  @spec await_commit_gate(peer(), reference(), non_neg_integer()) ::
          {:entered, boolean(), boolean(), boolean()}
  defp await_commit_gate(peer, fence, attempts \\ 100)

  defp await_commit_gate(_peer, _fence, 0),
    do: flunk("Mail owner did not reach its uncommitted post-ACK gate")

  defp await_commit_gate(peer, fence, attempts) do
    case :peer.call(peer.controller, Fixture, :commit_gate, [fence], 5000) do
      {:entered, transaction?, delivered?, erased?} = observation
      when is_boolean(transaction?) and is_boolean(delivered?) and is_boolean(erased?) ->
        observation

      :waiting ->
        receive do
        after
          20 -> await_commit_gate(peer, fence, attempts - 1)
        end

      _ ->
        flunk("Mail peer returned an invalid commit-gate observation")
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

  @spec terminal_replays(peer(), String.t(), pos_integer(), pid()) :: :ok
  defp terminal_replays(peer, id, replays, server) do
    assert snapshot(peer, id) == %{status: :delivered, ciphertext_digest: nil}
    connections = SMTP.connections(server)
    Enum.each(1..replays, fn _ -> assert deliver(peer, id) == {:ok, :delivered} end)
    assert snapshot(peer, id) == %{status: :delivered, ciphertext_digest: nil}
    assert SMTP.connections(server) == connections
    refute_receive {:smtp_accepted, _, _}
    refute_receive {:smtp_data, _, _, _}
    :ok
  end

  # @cc [owner:ghuntley,label:verification;security] distributed-mail-case-cleanup
  # Every case and replay MUST retire its exact peer processes before deleting
  # only the captured outbox, token and job identities. Forced ExUnit exit MUST
  # retain the same ordered fallback; partial peer startup MUST remain owned.
  @spec cleanup_case([peer()], Fixture.fixture()) :: :ok
  defp cleanup_case(peers, fixture) do
    Enum.each(peers, &stop_peer!/1)
    unboxed(fn -> Fixture.cleanup(fixture) end)
  end

  @spec stop_peer!(peer()) :: :ok
  defp stop_peer!(peer), do: stop_controller!(peer.controller)

  @spec stop_controller!(pid()) :: :ok
  defp stop_controller!(controller) do
    reference = Process.monitor(controller)

    try do
      :peer.stop(controller)
    catch
      :exit, {:noproc, _} -> :ok
      :exit, :noproc -> :ok
    end

    receive do
      {:DOWN, ^reference, :process, ^controller, _} -> :ok
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
