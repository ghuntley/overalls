defmodule Marshall.Compute.DistributedAdmissionTest do
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen
  require Marshall.CommittedFixtureCleanup, as: Cleanup
  import Marshall.ComputeFixtures

  alias Marshall.Compute.{
    Ledger,
    NetworkAddress,
    Operation,
    Reservation,
    VirtualMachine,
    WorkloadPlacement
  }

  alias Marshall.Repo

  @moduletag :distributed
  @moduletag timeout: 120_000

  # @cc [owner:ghuntley,label:verification] committed-fixture-suite-preservation
  # Every journey MUST restore its complete pre-test row inventory, including
  # historical rows. ExUnit reports this independent teardown check separately
  # from a body failure; it MUST NOT replace the original assertion.
  setup do
    {before, images_before} =
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        {Marshall.CommittedFixtureInventory.snapshot(), Cleanup.fixture_image_ids()}
      end)

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        # This serial/manual-Oban interval owns only the fixture image IDs absent
        # before the test. VM cleanup leaves image disposal to this boundary.
        Cleanup.images!(Cleanup.fixture_image_ids() -- images_before)
        Marshall.CommittedFixtureInventory.assert_restored!(before)
      end)
    end)

    :ok
  end

  # @cc [owner:ghuntley,label:verification] admission-three-independent-peers
  # Race fixtures MUST use three distinct BEAM nodes with independent Repo pools
  # and shared committed PostgreSQL state; the parent runner is not a peer.
  setup_all do
    # Separate BEAMs, Repo pools and Cedar handles share only PostgreSQL. The
    # parent test node is not counted among the three control-plane instances.
    peers =
      Enum.map([:marshall_admission_1, :marshall_admission_2, :marshall_admission_3], fn name ->
        peer =
          start_supervised!(%{
            id: name,
            start:
              {:peer, :start_link,
               [
                 %{
                   name: String.to_atom("#{name}_#{System.pid()}"),
                   connection: :standard_io,
                   args: [~c"+S", ~c"2:2", ~c"+SDcpu", ~c"1", ~c"+SDio", ~c"1"],
                   wait_boot: 30_000
                 }
               ]},
            restart: :temporary
          })

        node = :peer.call(peer, :erlang, :node, [])
        :ok = :peer.call(peer, :code, :add_paths, [:code.get_path()])

        config =
          for {app, _, _} <- Application.loaded_applications(),
              app not in [:kernel, :stdlib, :elixir, :logger],
              do: {app, Application.get_all_env(app)}

        :ok = :peer.call(peer, Application, :put_all_env, [config, [persistent: true]])

        repo_config =
          Application.fetch_env!(:marshall, Repo)
          |> Keyword.put(:pool, DBConnection.ConnectionPool)
          |> Keyword.put(:pool_size, 4)

        :ok =
          :peer.call(peer, Application, :put_env, [
            :marshall,
            Repo,
            repo_config,
            [persistent: true]
          ])

        :ok =
          :peer.call(peer, Application, :put_env, [:logger, :level, :error, [persistent: true]])

        {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:marshall], 30_000)
        {peer, node}
      end)

    assert length(Enum.uniq(Enum.map(peers, &elem(&1, 1)))) == 3
    %{peers: Enum.map(peers, &elem(&1, 0))}
  end

  setup context do
    if context[:uncertain_admission] do
      unless Node.alive?() do
        {:ok, _} = Node.start(:marshall_uncertain_observer, :shortnames)
        on_exit(fn -> Node.stop() end)
      end

      Enum.each(context.peers, &connect_admission_observer/1)
    end

    :ok
  end

  test "three nodes serialize team name collisions and creator retries", %{peers: peers} do
    unboxed(fn ->
      actors = for _ <- peers, do: user()
      name = "team-race-" <> binary_part(Ash.UUID.generate(), 0, 8)
      caller = self()

      try do
        tasks =
          for {peer, actor} <- Enum.zip(peers, actors) do
            Task.async(fn ->
              send(caller, {:team_create_ready, self()})
              receive do: (:create -> :ok)

              :peer.call(
                peer,
                Marshall.Teams,
                :create_team,
                [%{name: name, idempotency_key: "same-key"}, [actor: actor]],
                30_000
              )
            end)
          end

        ready =
          for _ <- tasks do
            assert_receive {:team_create_ready, pid}, 5_000
            pid
          end

        Enum.each(ready, &send(&1, :create))

        results = Task.await_many(tasks, 35_000)
        assert [{:ok, team}] = Enum.filter(results, &match?({:ok, _}, &1))
        assert Enum.count(results, &match?({:error, _}, &1)) == 2
        assert [%{id: id}] = Ledger.read!(Marshall.Teams.Team, name: name)
        assert id == team.id

        assert [%{user_id: owner_id, role: :owner}] =
                 Ledger.read!(Marshall.Teams.TeamMember, team_id: team.id)

        assert owner_id == team.created_by_id
        owner = Enum.find(actors, &(&1.id == owner_id))
        receipts = Ledger.read!(Marshall.Accounts.AdminEvent, target_id: team.id)
        assert Enum.sort(Enum.map(receipts, & &1.kind)) == [:team_create, :team_membership_change]
        assert Enum.all?(receipts, &(&1.actor_id == owner.id))

        retries =
          peers
          |> Enum.map(fn peer ->
            Task.async(fn ->
              :peer.call(
                peer,
                Marshall.Teams,
                :create_team,
                [%{name: name, idempotency_key: Ash.UUID.generate()}, [actor: owner]],
                30_000
              )
            end)
          end)
          |> Task.await_many(35_000)

        for result <- retries, do: assert({:ok, %{id: ^id}} = result)
        assert Ledger.read!(Marshall.Accounts.AdminEvent, target_id: team.id) == receipts
        assert [_] = Ledger.read!(Marshall.Teams.Team.Version, version_source_id: team.id)
      after
        cleanup_team_creation(name, actors)
      end
    end)
  end

  @spec cleanup_team_creation(String.t(), [Marshall.Accounts.User.t()]) :: :ok
  defp cleanup_team_creation(name, actors) do
    for team <- Ledger.history!(Marshall.Teams.Team, name: name) do
      params = [Ecto.UUID.dump!(team.id)]

      Ecto.Adapters.SQL.query!(
        Repo,
        "UPDATE teams SET archived_at = clock_timestamp() AT TIME ZONE 'UTC' WHERE id = $1",
        params
      )

      Ecto.Adapters.SQL.query!(
        Repo,
        "DELETE FROM account_admin_events WHERE target_id = $1",
        params
      )

      Ecto.Adapters.SQL.query!(
        Repo,
        "DELETE FROM team_members_versions WHERE version_source_id IN (SELECT id FROM team_members WHERE team_id = $1)",
        params
      )

      Ecto.Adapters.SQL.query!(Repo, "DELETE FROM team_members WHERE team_id = $1", params)

      Ecto.Adapters.SQL.query!(
        Repo,
        "DELETE FROM teams_versions WHERE version_source_id = $1",
        params
      )

      Ecto.Adapters.SQL.query!(Repo, "DELETE FROM teams WHERE id = $1", params)
    end

    for actor <- actors do
      Ecto.Adapters.SQL.query!(Repo, "DELETE FROM users WHERE id = $1", [
        Ecto.UUID.dump!(actor.id)
      ])
    end

    :ok
  end

  # @cc [owner:ghuntley,label:verification] remembered-race-failure-cleanup
  # A failed lock assertion MUST release its gate and drain both real operations
  # before removing fixture rows, so delayed issuance cannot leave an orphan.
  test "remembered login exchange and Sign out everywhere serialize in both orders on three nodes",
       %{peers: [first, second, third]} do
    supervisor = start_supervised!(Task.Supervisor)

    unboxed(fn ->
      admin = Marshall.PasskeyFixture.elevate(Marshall.PasskeyFixture.user(true))
      account = Marshall.PasskeyFixture.user()

      Cleanup.protect [first, second, third] do
        for order <- [:exchange_first, :revoke_first] do
          {:ok, token, _} =
            AshAuthentication.Jwt.token_for_user(account, %{"purpose" => "remember_me"},
              purpose: :remember_me
            )

          gate = System.unique_integer([:positive])
          Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_lock($1)", [gate])

          if order == :revoke_first,
            do: Marshall.RememberedLoginFixture.install_revoke_gate(account.id, gate)

          try do
            {first_result, {second_result, :ok}} =
              with_remember_operation(
                supervisor,
                first,
                gate,
                fn ->
                  if order == :exchange_first,
                    do:
                      :peer.call(
                        first,
                        Marshall.RememberedLoginFixture,
                        :exchange,
                        [token, gate],
                        30_000
                      ),
                    else:
                      :peer.call(
                        first,
                        Marshall.RememberedLoginFixture,
                        :revoke,
                        [admin, account.id],
                        30_000
                      )
                end,
                fn ->
                  holder = await_remember_gate(gate)

                  with_remember_operation(
                    supervisor,
                    second,
                    gate,
                    fn ->
                      if order == :exchange_first,
                        do:
                          :peer.call(
                            second,
                            Marshall.RememberedLoginFixture,
                            :revoke,
                            [admin, account.id],
                            30_000
                          ),
                        else:
                          :peer.call(
                            second,
                            Marshall.RememberedLoginFixture,
                            :exchange,
                            [token, 0],
                            30_000
                          )
                    end,
                    fn -> await_remember_blocker(holder) end
                  )
                end
              )

            if order == :exchange_first do
              assert {:ok, issued} = first_result
              assert {:ok, %{revoked: _}} = second_result

              assert :error =
                       :peer.call(third, Marshall.Accounts.Login, :verify, [
                         issued.__metadata__.token,
                         account
                       ])
            else
              assert {:ok, %{revoked: _}} = first_result
              assert {:error, _} = second_result
            end

            for peer <- [first, second, third],
                do:
                  assert(
                    {:error, _} =
                      :peer.call(
                        peer,
                        Marshall.RememberedLoginFixture,
                        :exchange,
                        [token, 0],
                        30_000
                      )
                  )
          after
            Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_unlock($1)", [gate])

            if order == :revoke_first,
              do: Marshall.RememberedLoginFixture.remove_revoke_gate(account.id)
          end
        end
      after
        for actor <- [account, admin] do
          Marshall.PasskeyFixture.cleanup(actor)

          Ecto.Adapters.SQL.query!(
            Repo,
            "DELETE FROM account_admin_events WHERE actor_id=$1 OR target_id=$1",
            [Ecto.UUID.dump!(actor.id)]
          )

          Ecto.Adapters.SQL.query!(Repo, "DELETE FROM users WHERE id=$1", [
            Ecto.UUID.dump!(actor.id)
          ])
        end
      end
    end)
  end

  # @cc [owner:ghuntley,label:verification] magic-sign-in-revocation-orders
  # The magic-link sign-in race MUST run real sign-in and revocation actions on
  # independent BEAMs. Gates pause the sign-in inside its transaction and after
  # its commit but before any post-commit credential store, so the issuance
  # window is exercised deterministically. A revocation arriving during an
  # in-flight sign-in MUST wait on production locks; committed outcomes MUST
  # be read from the database, not from response copies: issuance ordered
  # before revocation is completed-then-revoked, MFA reset and retirement
  # ordered first refuse the sign-in, and global session revocation ordered
  # first admits the fresh email sign-in preserved by ADR-0123.
  test "magic-link sign-in and account revocation serialize in both orders on three nodes",
       %{peers: [first, second, third]} do
    supervisor = start_supervised!(Task.Supervisor)

    unboxed(fn ->
      [bootstrap] = Ledger.read!(Marshall.Accounts.AdminBootstrap, id: "installation")
      unless bootstrap.completed, do: Ledger.update!(bootstrap, :complete, %{})

      strategy = AshAuthentication.Info.strategy!(Marshall.Accounts.User, :magic_link)

      try do
        for revoke_kind <- [:revoke_sessions, :reset_mfa, :delete_user],
            order <- [:sign_in_first, :revoke_first] do
          {account, admin, fresh_user_id} =
            race_magic_link_sign_in(
              supervisor,
              {first, second, third},
              revoke_kind,
              order,
              strategy
            )

          for id <- Enum.reject([account.id, admin.id, fresh_user_id], &is_nil/1) |> Enum.uniq() do
            Cleanup.subscription_reviews!([id])

            Cleanup.jobs!(
              "args->'primary_key'->>'id' IN (SELECT id::text FROM account_user_deletions WHERE user_id = $1)",
              [Ecto.UUID.dump!(id)]
            )

            Marshall.PasskeyFixture.cleanup(%Marshall.Accounts.User{id: id})

            Ecto.Adapters.SQL.query!(
              Repo,
              "DELETE FROM account_admin_events WHERE actor_id=$1 OR target_id=$1",
              [Ecto.UUID.dump!(id)]
            )

            Ecto.Adapters.SQL.query!(
              Repo,
              "DELETE FROM account_user_deletions WHERE user_id=$1",
              [Ecto.UUID.dump!(id)]
            )

            Ecto.Adapters.SQL.query!(Repo, "DELETE FROM users WHERE id=$1", [
              Ecto.UUID.dump!(id)
            ])
          end
        end
      after
        unless bootstrap.completed do
          Ecto.Adapters.SQL.query!(
            Repo,
            "UPDATE account_admin_bootstrap SET completed=false WHERE id='installation'",
            [],
            log: false
          )
        end
      end
    end)
  end

  @spec race_magic_link_sign_in(
          pid(),
          {pid(), pid(), pid()},
          :revoke_sessions | :reset_mfa | :delete_user,
          :sign_in_first | :revoke_first,
          AshAuthentication.Strategy.MagicLink.t()
        ) :: {Marshall.Accounts.User.t(), Marshall.Accounts.User.t(), String.t() | nil}
  defp race_magic_link_sign_in(supervisor, {first, second, third}, revoke_kind, order, strategy) do
    admin = Marshall.PasskeyFixture.elevate(Marshall.PasskeyFixture.user(true))
    account = Marshall.PasskeyFixture.user()
    email = to_string(account.email)
    {:ok, magic} = AshAuthentication.Strategy.MagicLink.request_token_for(strategy, account)

    # Global session revocation only flips user/remember_me tokens, so the
    # revoke gate needs an existing browser token to pause inside its UPDATE.
    if revoke_kind == :revoke_sessions,
      do: {:ok, _, _} = AshAuthentication.Jwt.token_for_user(account, %{}, purpose: :remember_me)

    gate_before = System.unique_integer([:positive])
    gate_after = System.unique_integer([:positive])
    Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_lock($1)", [gate_before])
    Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_lock($1)", [gate_after])

    if order == :revoke_first,
      do: Marshall.RememberedLoginFixture.install_revoke_gate(account.id, gate_before)

    sign_in = fn peer ->
      gates = if order == :revoke_first, do: {0, 0}, else: {gate_before, gate_after}

      :peer.call(peer, Marshall.RememberedLoginFixture, :sign_in, [magic, gates], 30_000)
    end

    revoke = fn peer ->
      case revoke_kind do
        :revoke_sessions ->
          :peer.call(peer, Marshall.RememberedLoginFixture, :revoke, [admin, account.id], 30_000)

        :reset_mfa ->
          :peer.call(
            peer,
            Marshall.RememberedLoginFixture,
            :reset_mfa,
            [admin, account.id],
            30_000
          )

        :delete_user ->
          :peer.call(
            peer,
            Marshall.RememberedLoginFixture,
            :retire,
            [admin, account.id, email],
            30_000
          )
      end
    end

    try do
      {signed_in, revoked} =
        case order do
          :sign_in_first ->
            # The revocation MUST wait on the sign-in's held locks, then commit
            # while the sign-in is parked after its commit but before any
            # post-commit credential store.
            {sign_in_result, {revoke_result, :ok}} =
              with_remember_operation(
                supervisor,
                first,
                gate_after,
                fn -> sign_in.(first) end,
                fn ->
                  holder = await_remember_gate(gate_before)

                  nested =
                    with_remember_operation(
                      supervisor,
                      second,
                      gate_before,
                      fn ->
                        revoke.(second)
                      end,
                      fn ->
                        await_remember_blocker(holder)
                      end
                    )

                  await_remember_gate(gate_after)
                  nested
                end
              )

            {sign_in_result, revoke_result}

          :revoke_first ->
            {revoke_result, {sign_in_result, :ok}} =
              with_remember_operation(
                supervisor,
                first,
                gate_before,
                fn -> revoke.(first) end,
                fn ->
                  holder = await_remember_gate(gate_before)

                  with_remember_operation(
                    supervisor,
                    second,
                    gate_before,
                    fn ->
                      sign_in.(second)
                    end,
                    fn ->
                      await_remember_blocker(holder)
                    end
                  )
                end
              )

            {sign_in_result, revoke_result}
        end

      case order do
        :sign_in_first ->
          assert {:ok, issued} = signed_in
          session = Ash.Resource.get_metadata(issued, :token)
          assert is_binary(session)
          %{token: remembered} = Ash.Resource.get_metadata(issued, :remember_me)
          assert is_binary(remembered)
          assert {:ok, _} = revoked

          # A sign-in committed before the revocation is included in it: the
          # issued session and remembered credentials are dead on an
          # independent replica, and no live browser credential for the
          # account remains committed.
          assert :error =
                   :peer.call(third, Marshall.Accounts.Login, :verify, [session, account], 30_000)

          assert %{rows: [[0]]} =
                   Ecto.Adapters.SQL.query!(
                     Repo,
                     "SELECT count(*) FROM tokens WHERE subject = $1 AND purpose IN ('user', 'remember_me')",
                     ["user?id=#{account.id}"]
                   )

          {:ok, %{"jti" => session_jti}} = AshAuthentication.Jwt.peek(session)
          {:ok, %{"jti" => remembered_jti}} = AshAuthentication.Jwt.peek(remembered)

          assert %{rows: [["revocation"], ["revocation"]]} =
                   Ecto.Adapters.SQL.query!(
                     Repo,
                     "SELECT purpose FROM tokens WHERE jti = ANY($1) ORDER BY 1",
                     [[session_jti, remembered_jti]]
                   )

        :revoke_first ->
          assert {:ok, _} = revoked

          if revoke_kind == :revoke_sessions do
            # ADR-0123 preserves intentional fresh email sign-in: the
            # magic-link credential is not a session token, so a sign-in
            # ordered after global revocation completes and is valid.
            assert {:ok, issued} = signed_in
            session = Ash.Resource.get_metadata(issued, :token)
            assert is_binary(session)

            assert {:ok, _, _} =
                     :peer.call(
                       third,
                       Marshall.Accounts.Login,
                       :verify,
                       [session, account],
                       30_000
                     )
          else
            assert {:error, _} = signed_in
          end
      end

      # The ordering boundary also preserves refresh: a brand-new magic link
      # still completes after every settled outcome.
      {:ok, fresh_magic} =
        AshAuthentication.Strategy.MagicLink.request_token_for_identity(strategy, email)

      assert {:ok, refreshed} =
               :peer.call(
                 third,
                 Marshall.RememberedLoginFixture,
                 :sign_in,
                 [
                   fresh_magic,
                   {0, 0}
                 ],
                 30_000
               )

      {:ok, %{"jti" => fresh_magic_jti}} = AshAuthentication.Jwt.peek(fresh_magic)
      {:ok, %{"jti" => magic_jti}} = AshAuthentication.Jwt.peek(magic)
      Ecto.Adapters.SQL.query!(Repo, "DELETE FROM tokens WHERE jti = $1", [fresh_magic_jti])
      Ecto.Adapters.SQL.query!(Repo, "DELETE FROM tokens WHERE jti = $1", [magic_jti])

      case revoke_kind do
        :delete_user ->
          assert refreshed.id != account.id
          assert [:user_delete] == delete_event_kinds(account.id)
          {account, admin, refreshed.id}

        _ ->
          assert refreshed.id == account.id
          {account, admin, nil}
      end
    after
      Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_unlock($1)", [gate_before])
      Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_unlock($1)", [gate_after])

      if order == :revoke_first,
        do: Marshall.RememberedLoginFixture.remove_revoke_gate(account.id)
    end
  end

  @spec delete_event_kinds(String.t()) :: [atom()]
  defp delete_event_kinds(id) do
    Ledger.read!(Marshall.Accounts.AdminEvent, target_id: id)
    |> Enum.map(& &1.kind)
  end

  # @cc [owner:ghuntley,label:verification] signout-exchange-ordering
  # Ordinary controller sign-out (a browser holding only a remember cookie)
  # MUST serialize with an in-flight remembered exchange on independent BEAMs:
  # an exchange committed first survives as an independent browser login while
  # its credential is then revoked; a committed sign-out fences the later
  # exchange into refusal. Observations MUST come from committed rows.
  test "controller sign-out and remembered login exchange serialize in both orders on three nodes",
       %{peers: [first, second, third]} do
    supervisor = start_supervised!(Task.Supervisor)

    unboxed(fn ->
      account = Marshall.PasskeyFixture.user()
      strategy = AshAuthentication.Info.strategy!(Marshall.Accounts.User, :remember_me)
      cookie_name = to_string(strategy.cookie_name)

      Cleanup.protect [first, second, third] do
        for order <- [:exchange_first, :sign_out_first] do
          {:ok, remember, _} =
            AshAuthentication.Jwt.token_for_user(account, %{"purpose" => "remember_me"},
              purpose: :remember_me
            )

          {:ok, %{"jti" => remember_jti}} = AshAuthentication.Jwt.peek(remember)

          gate = System.unique_integer([:positive])
          Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_lock($1)", [gate])

          if order == :sign_out_first,
            do: Marshall.RememberedLoginFixture.install_revoke_gate(account.id, gate)

          exchange = fn peer, g ->
            :peer.call(peer, Marshall.RememberedLoginFixture, :exchange, [remember, g], 30_000)
          end

          sign_out = fn peer ->
            :peer.call(
              peer,
              Marshall.RememberedLoginFixture,
              :sign_out,
              [cookie_name, remember],
              30_000
            )
          end

          try do
            case order do
              :exchange_first ->
                {exchange_result, {sign_out_result, :ok}} =
                  with_remember_operation(
                    supervisor,
                    first,
                    gate,
                    fn -> exchange.(first, gate) end,
                    fn ->
                      holder = await_remember_gate(gate)

                      with_remember_operation(
                        supervisor,
                        second,
                        gate,
                        fn ->
                          sign_out.(second)
                        end,
                        fn ->
                          await_remember_blocker(holder)
                        end
                      )
                    end
                  )

                assert {:ok, issued} = exchange_result
                session = Ash.Resource.get_metadata(issued, :token)
                assert is_binary(session)
                assert %Plug.Conn{status: 302} = sign_out_result

                # Ordinary sign-out revokes the supplied remember credential
                # after the in-flight exchange committed; the exchanged
                # independent browser login remains valid on another replica.
                assert %{rows: [["revocation"]]} =
                         Ecto.Adapters.SQL.query!(
                           Repo,
                           "SELECT purpose FROM tokens WHERE jti = $1",
                           [remember_jti]
                         )

                assert {:ok, _, _} =
                         :peer.call(
                           third,
                           Marshall.Accounts.Login,
                           :verify,
                           [session, account],
                           30_000
                         )

              :sign_out_first ->
                {sign_out_result, {exchange_result, :ok}} =
                  with_remember_operation(
                    supervisor,
                    first,
                    gate,
                    fn -> sign_out.(first) end,
                    fn ->
                      holder = await_remember_gate(gate)

                      with_remember_operation(
                        supervisor,
                        second,
                        gate,
                        fn ->
                          exchange.(second, 0)
                        end,
                        fn ->
                          await_remember_blocker(holder)
                        end
                      )
                    end
                  )

                assert %Plug.Conn{status: 302} = sign_out_result
                assert {:error, _} = exchange_result

                assert %{rows: [["revocation"]]} =
                         Ecto.Adapters.SQL.query!(
                           Repo,
                           "SELECT purpose FROM tokens WHERE jti = $1",
                           [remember_jti]
                         )
            end

            for peer <- [first, second, third],
                do:
                  assert(
                    {:error, _} =
                      :peer.call(
                        peer,
                        Marshall.RememberedLoginFixture,
                        :exchange,
                        [
                          remember,
                          0
                        ],
                        30_000
                      )
                  )
          after
            Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_unlock($1)", [gate])

            if order == :sign_out_first,
              do: Marshall.RememberedLoginFixture.remove_revoke_gate(account.id)
          end
        end
      after
        Marshall.PasskeyFixture.cleanup(account)

        Ecto.Adapters.SQL.query!(Repo, "DELETE FROM users WHERE id=$1", [
          Ecto.UUID.dump!(account.id)
        ])
      end
    end)
  end

  @typep remembered_outcome ::
           {:ok, term()}
           | {:raised, :error | :exit | :throw, term(), Exception.stacktrace()}

  @spec with_remember_operation(pid(), pid(), integer(), (-> term()), (-> result)) ::
          {term(), result}
        when result: term()
  defp with_remember_operation(supervisor, peer, gate, operation, body) do
    task = Task.Supervisor.async_nolink(supervisor, operation)
    receipt = make_ref()

    body_result =
      try do
        {:ok, body.()}
      catch
        kind, reason -> {:raised, kind, reason, __STACKTRACE__}
      after
        try do
          Ecto.Adapters.SQL.query!(Repo, "SELECT pg_advisory_unlock($1)", [gate])
        after
          # A distinct receipt keeps the single drain result available outside
          # after, including when the leading-only gate assertion failed.
          send(self(), {receipt, drain_remember_operation(supervisor, peer, task)})
        end
      end

    receive do
      {^receipt, task_result} ->
        result = remember_result!(body_result)
        {remember_result!(task_result), result}
    end
  end

  @spec drain_remember_operation(pid(), pid(), Task.t()) :: remembered_outcome()
  defp drain_remember_operation(supervisor, peer, task) do
    try do
      {:ok, Task.await(task, 35_000)}
    catch
      kind, reason ->
        stacktrace = __STACKTRACE__
        Task.Supervisor.terminate_child(supervisor, task.pid)
        # An RPC failure must stop this owned peer before deleting fixture rows.
        # Peers are shared by setup_all, so this abort also fails later peer users;
        # such a run cannot be accepted as passing distributed verification.
        :peer.stop(peer)
        {:raised, kind, reason, stacktrace}
    end
  end

  @spec remember_result!(remembered_outcome()) :: term()
  defp remember_result!({:ok, result}), do: result

  defp remember_result!({:raised, kind, reason, stacktrace}),
    do: :erlang.raise(kind, reason, stacktrace)

  @spec await_remember_gate(integer(), non_neg_integer()) :: integer()
  defp await_remember_gate(gate, attempts \\ 100)

  defp await_remember_gate(_gate, 0),
    do: flunk("remember exchange did not reach its committed gate")

  defp await_remember_gate(gate, attempts) do
    case Ecto.Adapters.SQL.query!(
           Repo,
           "SELECT pid FROM pg_locks WHERE locktype='advisory' AND objid=$1 AND NOT granted",
           [gate]
         ).rows do
      [[pid]] ->
        pid

      [] ->
        Process.sleep(20)
        await_remember_gate(gate, attempts - 1)
    end
  end

  @spec await_remember_blocker(integer(), non_neg_integer()) :: :ok
  defp await_remember_blocker(holder, attempts \\ 100)

  defp await_remember_blocker(_holder, 0),
    do: flunk("opposing replica did not wait on the account lock")

  defp await_remember_blocker(holder, attempts) do
    case Ecto.Adapters.SQL.query!(
           Repo,
           "SELECT count(*) FROM pg_stat_activity WHERE $1 = ANY(pg_blocking_pids(pid))",
           [holder]
         ).rows do
      [[count]] when count > 0 ->
        :ok

      _ ->
        Process.sleep(20)
        await_remember_blocker(holder, attempts - 1)
    end
  end

  test "three nodes consume one passkey challenge once and share revocation", %{peers: peers} do
    unboxed(fn ->
      actor = Marshall.PasskeyFixture.elevate(Marshall.PasskeyFixture.user(true))
      {:ok, challenge} = Marshall.PasskeyFixture.action(actor, :begin_verify)

      payload =
        Marshall.PasskeyFixture.assertion(challenge, actor.__metadata__.test_authenticator)

      input =
        Ash.ActionInput.for_action(
          Marshall.Accounts.User,
          :security,
          %{operation: :finish_verify, payload: payload},
          actor: actor
        )

      Cleanup.protect peers do
        results =
          peers
          |> Task.async_stream(fn peer -> :peer.call(peer, Ash, :run_action, [input], 30_000) end,
            max_concurrency: 3,
            timeout: 35_000
          )
          |> Enum.map(fn {:ok, result} -> result end)

        assert Enum.count(results, &match?({:ok, %{verified: true}}, &1)) == 1
        assert Enum.count(results, &match?({:error, _}, &1)) == 2

        for peer <- peers,
            do: assert(:peer.call(peer, Marshall.Accounts.Security, :recent?, [actor]))

        :ok =
          AshAuthentication.TokenResource.Actions.revoke(
            Marshall.Accounts.Token,
            actor.__metadata__.token
          )

        for peer <- peers,
            do: refute(:peer.call(peer, Marshall.Accounts.Security, :recent?, [actor]))
      after
        Marshall.PasskeyFixture.cleanup(actor)

        Ecto.Adapters.SQL.query!(Repo, "DELETE FROM account_admin_events WHERE actor_id=$1", [
          Ecto.UUID.dump!(actor.id)
        ])

        Ecto.Adapters.SQL.query!(Repo, "DELETE FROM users WHERE id=$1", [
          Ecto.UUID.dump!(actor.id)
        ])
      end
    end)
  end

  test "retirement fences concurrent admission and cleanup resumes on every replica", %{
    peers: peers
  } do
    unboxed(fn ->
      fixture = host_fixture()
      owner = Marshall.PasskeyFixture.user()
      admin = Marshall.PasskeyFixture.verified_session(Marshall.PasskeyFixture.user(true))
      {:ok, _} = Marshall.Compute.provision(request(), actor: owner)

      deletion =
        Ash.ActionInput.for_action(
          Marshall.Accounts.User,
          :delete_user,
          %{user_id: owner.id, confirmation: to_string(owner.email)},
          actor: admin
        )

      Cleanup.protect peers do
        tasks =
          for {peer, index} <- Enum.with_index(peers) do
            Task.async(fn ->
              if index == 0,
                do: :peer.call(peer, Ash, :run_action, [deletion]),
                else: :peer.call(peer, Marshall.Compute, :provision, [request(), [actor: owner]])
            end)
          end

        [{:ok, receipt} | _] = Enum.map(tasks, &Task.await(&1, 30_000))

        for peer <- peers do
          assert {:error, _} =
                   :peer.call(peer, Marshall.Compute, :provision, [request(), [actor: owner]])

          assert {:ok, %{complete: false}} =
                   :peer.call(peer, Marshall.Accounts.DeleteUserMachines, :run, [
                     %{arguments: %{primary_key: %{"id" => receipt.id}}},
                     [],
                     %{actor: Marshall.Authorization.SystemActor.compute()}
                   ])
        end

        owned = Ledger.read!(VirtualMachine, owner_id: owner.id)
        assert length(owned) in 1..2
        assert Enum.all?(owned, &(&1.desired_state == :deleted))

        assert Enum.count(
                 Ledger.read!(Operation, requested_by_id: admin.id),
                 &(&1.kind == :delete)
               ) == length(owned)
      after
        Cleanup.subscription_reviews!([owner.id])

        Cleanup.jobs!(
          "args->'primary_key'->>'id' IN (SELECT id::text FROM account_user_deletions WHERE user_id=$1)",
          [Ecto.UUID.dump!(owner.id)]
        )

        Ecto.Adapters.SQL.query!(Repo, "DELETE FROM account_user_deletions WHERE user_id=$1", [
          Ecto.UUID.dump!(owner.id)
        ])

        Ecto.Adapters.SQL.query!(
          Repo,
          "DELETE FROM account_admin_events WHERE actor_id=$1 OR target_id=$2",
          [Ecto.UUID.dump!(admin.id), Ecto.UUID.dump!(owner.id)]
        )

        cleanup(fixture.host.id, owner.id)
        Marshall.PasskeyFixture.cleanup(admin)

        Ecto.Adapters.SQL.query!(Repo, "DELETE FROM users WHERE id=$1", [
          Ecto.UUID.dump!(admin.id)
        ])
      end
    end)
  end

  test "three nodes retry one failed job with one durable audit receipt", %{peers: peers} do
    unboxed(fn ->
      admin =
        Ash.Seed.seed!(Marshall.Accounts.User, %{
          email: "job-race-#{Ash.UUID.generate()}@example.test",
          administrator: true
        })
        |> Marshall.PasskeyFixture.verified_session()

      job = %{} |> Oban.Job.new(worker: "Marshall.TestWorker", max_attempts: 1) |> Oban.insert!()

      Ecto.Adapters.SQL.query!(
        Repo,
        "UPDATE oban_jobs SET state='discarded', attempt=1 WHERE id=$1",
        [job.id]
      )

      request = %{id: job.id, request_id: Ash.UUID.generate()}

      Cleanup.protect peers do
        results =
          peers
          |> Task.async_stream(
            fn peer ->
              :peer.call(
                peer,
                Marshall.Administration,
                :retry_job,
                [request, [actor: admin]],
                30_000
              )
            end,
            max_concurrency: 3,
            timeout: 35_000
          )
          |> Enum.map(fn {:ok, result} -> result end)

        assert Enum.all?(results, &match?({:ok, %{accepted: true}}, &1))
        assert %{state: "available", max_attempts: 2} = Repo.get!(Oban.Job, job.id)
        assert [_] = Ledger.read!(Marshall.Administration.AuditEvent, actor_id: admin.id)

        assert %{rows: [[1]]} =
                 Ecto.Adapters.SQL.query!(
                   Repo,
                   "SELECT count(*) FROM admin_job_events WHERE job_id=$1 AND state='available' AND attempt=1",
                   [job.id]
                 )
      after
        # Delete only this committed fixture, including history retained by raw pruning.
        Cleanup.jobs!(
          "id=$1",
          [job.id]
        )

        Ecto.Adapters.SQL.query!(Repo, "DELETE FROM admin_job_events WHERE job_id=$1", [job.id])
        Ecto.Adapters.SQL.query!(Repo, "DELETE FROM admin_job_snapshots WHERE id=$1", [job.id])

        Ecto.Adapters.SQL.query!(Repo, "DELETE FROM admin_audit_events WHERE actor_id=$1", [
          Ecto.UUID.dump!(admin.id)
        ])

        Marshall.PasskeyFixture.cleanup(admin)

        Ecto.Adapters.SQL.query!(Repo, "DELETE FROM users WHERE id=$1", [
          Ecto.UUID.dump!(admin.id)
        ])
      end
    end)
  end

  test "three nodes cannot demote every administrator with stale principals", %{peers: peers} do
    unboxed(fn ->
      admins =
        Enum.map(1..3, fn _ ->
          Ash.Seed.seed!(Marshall.Accounts.User, %{
            email: "admin-race-#{Ash.UUID.generate()}@example.test",
            administrator: true
          })
          |> Marshall.PasskeyFixture.verified_session()
        end)

      ids = Enum.map(admins, & &1.id)

      try do
        results =
          peers
          |> Enum.with_index()
          |> Task.async_stream(
            fn {peer, index} ->
              actor = Enum.at(admins, index)
              target = Enum.at(admins, rem(index + 1, 3))

              input =
                Ash.ActionInput.for_action(
                  Marshall.Accounts.User,
                  :set_administrator,
                  %{user_id: target.id, administrator: false},
                  actor: actor
                )

              :peer.call(peer, Ash, :run_action, [input], 30_000)
            end,
            max_concurrency: 3,
            timeout: 35_000
          )
          |> Enum.map(fn {:ok, result} -> result end)

        succeeded = Enum.count(results, &match?({:ok, _}, &1))
        assert succeeded in 1..2

        for peer <- peers do
          authority =
            Enum.map(admins, fn admin ->
              :peer.call(peer, Marshall.Authorization.Cedar, :allowed?, [
                admin,
                "admin_accounts",
                Marshall.Authorization.Cedar.entity("ControlPlane", "marshall")
              ])
            end)

          assert Enum.count(authority, & &1) == 3 - succeeded
        end

        assert %{rows: [[^succeeded]]} =
                 Ecto.Adapters.SQL.query!(
                   Repo,
                   "SELECT count(*) FROM account_admin_events WHERE target_id = ANY($1)",
                   [Enum.map(ids, &Ecto.UUID.dump!/1)]
                 )
      after
        binary_ids = Enum.map(ids, &Ecto.UUID.dump!/1)

        Ecto.Adapters.SQL.query!(
          Repo,
          "DELETE FROM account_admin_events WHERE target_id = ANY($1)",
          [binary_ids]
        )

        Enum.each(admins, &Marshall.PasskeyFixture.cleanup/1)
        Ecto.Adapters.SQL.query!(Repo, "DELETE FROM users WHERE id = ANY($1)", [binary_ids])
      end
    end)
  end

  test "three nodes race for two slots without overcommit or a reservation/job gap", %{
    peers: peers
  } do
    unboxed(fn ->
      fixture = host_fixture()
      actor = user()

      Cleanup.protect peers do
        results = race(peers, Enum.map(1..9, fn _ -> request() end), actor)
        accepted = for {:ok, vm} <- results, do: vm
        rejected = for {:error, error} <- results, do: error
        assert length(accepted) == 2
        assert length(rejected) == 7
        assert Enum.all?(rejected, &(Exception.message(&1) =~ "insufficient_capacity"))
        reservations = Ledger.read!(Reservation, host_id: fixture.host.id)
        assert Enum.sum(Enum.map(reservations, & &1.vcpu)) == 4
        assert length(Ledger.read!(VirtualMachine, host_id: fixture.host.id)) == 2
        assert length(Ledger.read!(Operation, requested_by_id: actor.id)) == 2
        job_ids = Enum.map(Ledger.read!(Operation, requested_by_id: actor.id), & &1.id)

        %{rows: [[count]]} =
          Ecto.Adapters.SQL.query!(
            Repo,
            "SELECT count(*) FROM oban_jobs WHERE args->'primary_key'->>'id' = ANY($1)",
            [job_ids]
          )

        assert count == 2
        assert length(Enum.uniq_by(Ledger.read!(NetworkAddress), &{&1.profile, &1.slot})) == 2
      after
        cleanup(fixture.host.id, actor.id)
      end
    end)
  end

  test "three nodes racing distinct requests for one name create one durable allocation", %{
    peers: peers
  } do
    unboxed(fn ->
      fixture = host_fixture()
      actor = user()
      name = "race-" <> String.replace(Ash.UUID.generate(), "-", "")

      Cleanup.protect peers do
        results = race(peers, Enum.map(1..6, fn _ -> request(%{name: name}) end), actor)
        assert [{:ok, vm}] = Enum.filter(results, &match?({:ok, _}, &1))
        assert vm.name == name
        assert length(Enum.filter(results, &match?({:error, _}, &1))) == 5
        for {:error, error} <- results, do: assert(Exception.message(error) =~ "name_unavailable")
        assert length(Ledger.read!(Reservation, host_id: fixture.host.id)) == 1
        assert length(Ledger.read!(Operation, requested_by_id: actor.id)) == 1
      after
        cleanup(fixture.host.id, actor.id)
      end
    end)
  end

  test "three nodes serialize full disk startup holds against physical headroom beyond legacy caps",
       %{
         peers: peers
       } do
    unboxed(fn ->
      fixture = host_fixture()
      actor = user()
      gib = 1_073_741_824

      Cleanup.protect peers do
        pool =
          Ledger.create!(Marshall.Compute.StoragePool, :enroll, %{
            host_id: fixture.host.id,
            name: "zfs-guests",
            backend: :zfs,
            filesystem_id: "zfs:123:456",
            zpool_guid: "123",
            dataset_guid: "456",
            dataset: "tank/lilly",
            overhead_bytes: gib
          })

        storage = %{
          backend: :zfs,
          zpool_guid: "123",
          dataset_guid: "456",
          dataset: "tank/lilly",
          used_bytes: gib,
          logical_used_bytes: 10 * gib,
          quota_bytes: 100 * gib,
          compression_ratio: 10.0
        }

        snapshot = %{
          id: pool.id,
          total_bytes: 100 * gib,
          free_bytes: 99 * gib,
          allocations: %{},
          storage: storage
        }

        unavailable = %{
          hd(fixture.report.pools)
          | total_bytes: 0,
            free_bytes: 0,
            storage: %{hd(fixture.report.pools).storage | quota_bytes: nil}
        }

        report = %{
          fixture.report
          | sequence: 2,
            effective_cores: 32,
            effective_memory_bytes: 64 * gib,
            capacity: capacity(32, 64 * gib),
            pools: [unavailable, snapshot]
        }

        assert {:ok, :ok} =
                 Marshall.Compute.HostReports.ingest(fixture.host.id, fixture.epoch, report)

        results =
          race(
            peers,
            Enum.map(1..9, fn _ -> request(%{vcpu: 1, disk_bytes: 16 * gib}) end),
            actor
          )

        accepted = for {:ok, vm} <- results, do: vm
        rejected = for {:error, error} <- results, do: error
        assert length(accepted) == 5
        assert Enum.all?(accepted, &(&1.pool_id == pool.id))
        assert length(rejected) == 4
        assert Enum.all?(rejected, &(Exception.message(&1) =~ "insufficient_capacity"))
        reservations = Ledger.read!(Reservation, host_id: fixture.host.id)
        assert Enum.sum(Enum.map(reservations, & &1.disk_bytes)) == 85 * gib

        snapshot = %{
          snapshot
          | storage: %{storage | compression_ratio: 100.0, logical_used_bytes: 100 * gib}
        }

        report = %{report | sequence: 3, sampled_at: Ledger.now(), pools: [unavailable, snapshot]}

        assert {:ok, :ok} =
                 Marshall.Compute.HostReports.ingest(fixture.host.id, fixture.epoch, report)

        assert Enum.all?(
                 race(
                   peers,
                   Enum.map(1..3, fn _ -> request(%{vcpu: 1, disk_bytes: 16 * gib}) end),
                   actor
                 ),
                 &match?({:error, _}, &1)
               )

        assert length(Ledger.read!(Reservation, host_id: fixture.host.id)) == 5
      after
        cleanup(fixture.host.id, actor.id)
      end
    end)
  end

  test "SSH receipts and cross-key revocation serialize across three nodes", %{peers: peers} do
    unboxed(fn ->
      fixture = host_fixture()
      actor = user()
      system = Marshall.Authorization.SystemActor.compute()
      {gateway_token, _} = Marshall.SSH.Token.issue(:gateway)

      {:ok, gateway} =
        Marshall.SSH.configure_gateway(
          %{name: "race-#{Ash.UUID.generate()}", token: gateway_token},
          actor: system
        )

      keys =
        for _ <- 1..2 do
          public =
            "ssh-ed25519 " <>
              Base.encode64(
                <<11::32, "ssh-ed25519", 32::32, :crypto.strong_rand_bytes(32)::binary>>
              )

          {:ok, key} = Marshall.SSH.add_key(%{public_key: public}, actor: actor)

          {:ok, session} =
            Marshall.SSH.open_session(%{gateway_token: gateway_token, public_key: public},
              actor: system
            )

          {key, session}
        end

      [{key_a, session_a}, {key_b, session_b}] = keys

      payload = fn session, text ->
        {:ok, command} = OverallsProtocol.SSHCommand.parse(text)

        %{
          gateway_token: gateway_token,
          session_token: session.session_token,
          command: command |> Jason.encode!() |> Jason.decode!()
        }
      end

      call = fn peer, params ->
        :peer.call(peer, Marshall.SSH, :execute, [params, [actor: system]], 30_000)
      end

      Cleanup.protect peers do
        params = payload.(session_a, "new --image #{image_id()} --request-id repeated")

        replies =
          peers
          |> Enum.map(fn peer -> Task.async(fn -> call.(peer, params) end) end)
          |> Enum.map(&Task.await(&1, 35_000))

        assert [{:ok, receipt}] = Enum.uniq(replies)
        assert receipt.status == "accepted"
        assert length(Ledger.read!(Marshall.SSH.Request, user_id: actor.id)) == 1
        assert length(Ledger.read!(Operation, requested_by_id: actor.id)) == 1

        removals = [
          payload.(session_a, "ssh-key remove #{key_b.id}"),
          payload.(session_b, "ssh-key remove #{key_a.id}")
        ]

        replies =
          Enum.zip(peers, removals)
          |> Enum.map(fn {peer, request} -> Task.async(fn -> call.(peer, request) end) end)
          |> Enum.map(&Task.await(&1, 35_000))

        assert length(Enum.filter(replies, &match?({:ok, _}, &1))) == 1
        assert length(Enum.filter(replies, &match?({:error, _}, &1))) == 1
        assert length(Ledger.read!(Marshall.SSH.Key, user_id: actor.id)) == 1
      after
        Repo.transaction(fn ->
          for {table, where, id} <- [
                {"ssh_requests", "user_id = $1", actor.id},
                {"ssh_sessions", "gateway_id = $1", gateway.id},
                {"ssh_keys_versions",
                 "version_source_id IN (SELECT id FROM ssh_keys WHERE user_id = $1)", actor.id},
                {"ssh_keys", "user_id = $1", actor.id},
                {"ssh_gateways", "id = $1", gateway.id}
              ] do
            Ecto.Adapters.SQL.query!(Repo, "DELETE FROM #{table} WHERE #{where}", [
              Ecto.UUID.dump!(id)
            ])
          end
        end)

        cleanup(fixture.host.id, actor.id)
      end
    end)
  end

  test "the same key arriving at three nodes has one durable result", %{peers: peers} do
    unboxed(fn ->
      fixture = host_fixture()
      actor = user()

      Cleanup.protect peers do
        params = request()
        results = race(peers, List.duplicate(params, 9), actor)
        assert Enum.all?(results, &match?({:ok, _}, &1))
        assert length(Enum.uniq(Enum.map(results, fn {:ok, vm} -> vm.id end))) == 1
        assert length(Ledger.read!(Reservation, host_id: fixture.host.id)) == 1
        assert length(Ledger.read!(Operation, requested_by_id: actor.id)) == 1
      after
        cleanup(fixture.host.id, actor.id)
      end
    end)
  end

  # @cc [owner:ghuntley,label:verification;recovery] lost-admission-response-keeps-durable-result
  # After the actual committing worker or owned BEAM dies before returning a response,
  # concurrent same-key retries on three independent nodes MUST return the
  # original VM, including archived history, with no added allocation rows.
  # Changed-shape retries MUST refuse while preserving that same row inventory.
  #
  # The input domain is finite: 3 repeat counts x 3 origins x 3 changed shapes,
  # and a :node loss replaces the origin with a fresh owned BEAM, so origin does
  # not vary that branch. 6fad4d347 moved this from 2 generated cases to the
  # ADR-0191 default of 100, which in CI meant 100 cases x 4 histories, two with
  # a fresh peer each, against a 300 s budget it could not meet. Its own
  # exploration review sends true finite matrices to ordinary tests that
  # enumerate every value, so this test runs every point of the domain once:
  # 54 surviving-worker histories and 18 fresh-peer histories. That is a
  # superset of anything 100 random draws could reach, and costs fewer peers.
  # The 72 histories took 82 s locally; 600 s leaves room for a loaded runner.
  @tag timeout: 600_000
  @tag uncertain_admission: true
  test "lost post-commit admission replies replay across three nodes", %{peers: peers} do
    changes = [%{vcpu: 1}, %{memory_bytes: 1_073_741_824}, %{disk_bytes: 4_294_967_296}]

    histories =
      for repeats <- 1..3,
          changed <- changes,
          {loss, origin} <- [{:worker, 0}, {:worker, 1}, {:worker, 2}, {:node, nil}],
          archived <- [false, true],
          do: {repeats, changed, loss, origin, archived}

    for {repeats, changed, loss, origin, archived} <- histories do
      unboxed(fn ->
        origin_peer =
          if loss == :node, do: start_owned_admission_peer(), else: Enum.fetch!(peers, origin)

        fixture = host_fixture()
        actor = user()
        params = request()
        owned_peers = Enum.uniq([origin_peer | peers])
        receipt = make_ref()

        Cleanup.protect owned_peers do
          worker =
            :peer.call(
              origin_peer,
              Marshall.UncertainAdmissionFixture,
              :start,
              [self(), receipt, params, actor],
              30_000
            )

          monitor = Process.monitor(worker)
          assert_receive {^receipt, :committed, ^worker, vm_id}, 30_000
          refute_receive {^receipt, :returned, _id}, 0
          assert [%{id: ^vm_id} = vm] = Ledger.read!(VirtualMachine, owner_id: actor.id)
          assert [%{vm_id: ^vm_id}] = Ledger.read!(Reservation, vm_id: vm_id)

          assert [%{vm_id: ^vm_id, kind: :provision}] =
                   Ledger.read!(Operation, requested_by_id: actor.id)

          case loss do
            :worker ->
              assert true = :peer.call(origin_peer, Process, :exit, [worker, :kill], 30_000)
              assert_receive {:DOWN, ^monitor, :process, ^worker, :killed}, 10_000

            :node ->
              peer_monitor = Process.monitor(origin_peer)
              catch_exit(:peer.call(origin_peer, :erlang, :halt, [137], 30_000))

              assert_receive {:DOWN, ^peer_monitor, :process, ^origin_peer, {:exit_status, 137}},
                             10_000

              assert_receive {:DOWN, ^monitor, :process, ^worker, :noconnection}, 10_000
          end

          refute_receive {^receipt, :returned, _id}, 0

          if archived, do: assert(:ok = Ledger.archive!(vm, :archive))
          committed = Marshall.CommittedFixtureInventory.snapshot()

          for _ <- 1..repeats do
            results = race(peers, List.duplicate(params, 9), actor)
            assert Enum.all?(results, &match?({:ok, %{id: ^vm_id}}, &1))
            Marshall.CommittedFixtureInventory.assert_restored!(committed)
          end

          for peer <- peers do
            assert {:error, error} =
                     :peer.call(
                       peer,
                       Marshall.Compute,
                       :provision,
                       [Map.merge(params, changed), [actor: actor]],
                       30_000
                     )

            assert Exception.message(error) =~ "idempotency_conflict"
            Marshall.CommittedFixtureInventory.assert_restored!(committed)
          end
        after
          cleanup(fixture.host.id, actor.id)
        end
      end)
    end
  end

  test "three nodes allocate distinct addresses across different hosts", %{peers: peers} do
    unboxed(fn ->
      first = host_fixture()
      second = host_fixture()
      actor = user()

      Cleanup.protect peers do
        results = race(peers, Enum.map(1..9, fn _ -> request() end), actor)
        accepted = for {:ok, vm} <- results, do: vm
        assert length(accepted) == 4
        assert length(Enum.uniq_by(accepted, & &1.host_id)) == 2
        addresses = Ledger.read!(NetworkAddress)
        assert Enum.sort(Enum.map(addresses, & &1.slot)) == [2, 3, 4, 5]
        assert Enum.all?(addresses, &(&1.profile == :standard))
      after
        cleanup(first.host.id, actor.id)
        cleanup(second.host.id, actor.id)
      end
    end)
  end

  test "an AshOban insert failure rolls back VM, reservation, operation and audit", _context do
    unboxed(fn ->
      fixture = host_fixture()
      actor = user()

      Cleanup.protect do
        assert_raise Ash.Error.Unknown, fn ->
          Repo.transaction(fn ->
            Ecto.Adapters.SQL.query!(Repo, """
            CREATE FUNCTION pg_temp.reject_compute_job() RETURNS trigger LANGUAGE plpgsql AS
            $$ BEGIN RAISE EXCEPTION 'injected job insert failure'; END $$
            """)

            Ecto.Adapters.SQL.query!(Repo, """
            CREATE TRIGGER reject_compute_job BEFORE INSERT ON oban_jobs
            FOR EACH ROW WHEN (NEW.queue = 'provisioning') EXECUTE FUNCTION pg_temp.reject_compute_job()
            """)

            Marshall.Compute.provision(request(), actor: actor)
          end)
        end

        assert [] == Ledger.read!(VirtualMachine, host_id: fixture.host.id)
        assert [] == Ledger.read!(Reservation, host_id: fixture.host.id)
        assert [] == Ledger.read!(Operation, requested_by_id: actor.id)
        assert [] == Ledger.read!(VirtualMachine.Version)
        assert [] == Ledger.read!(NetworkAddress)
      after
        cleanup(fixture.host.id, actor.id)
      end
    end)
  end

  # @cc [owner:ghuntley,label:verification;concurrency] admission-generated-commit-set
  # Every injected insert failure MUST preserve the complete committed row
  # inventory; a later success MUST create one linked admission set, and replay
  # or conflict MUST NOT add another row to that set.
  @tag timeout: 300_000
  property "injected insert failures preserve the admission commit set", test_cases: 100 do
    tables =
      draw(
        "tables",
        shuffle([
          "compute_virtual_machines",
          "compute_virtual_machines_versions",
          "agent_roots",
          "agent_threads",
          "agent_audit_events",
          "ingress_endpoints",
          "ingress_endpoints_versions",
          "compute_workload_placements",
          "compute_reservations",
          "compute_network_addresses",
          "compute_operations",
          "oban_jobs"
        ])
      )

    for vcpu <- [1, 2], table <- tables do
      unboxed(fn ->
        fixture = host_fixture()
        actor = user()
        params = request(%{vcpu: vcpu})

        Cleanup.protect do
          before = Marshall.CommittedFixtureInventory.snapshot()

          failed =
            try do
              Repo.transaction(fn ->
                Ecto.Adapters.SQL.query!(Repo, """
                CREATE FUNCTION pg_temp.reject_admission_insert() RETURNS trigger LANGUAGE plpgsql AS
                $$ BEGIN RAISE EXCEPTION 'injected admission insert failure'; END $$
                """)

                Ecto.Adapters.SQL.query!(Repo, """
                CREATE TRIGGER reject_admission_insert BEFORE INSERT ON #{table}
                FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_admission_insert()
                """)

                Marshall.Compute.provision(params, actor: actor)
              end)
            rescue
              error -> {:raised, error}
            end

          if table == "oban_jobs" do
            assert match?({:raised, %Ash.Error.Unknown{}}, failed)
            assert inspect(failed) =~ "Marshall.Compute.Operation.enqueue"
          else
            assert inspect(failed) =~ "injected admission insert failure"
          end

          Marshall.CommittedFixtureInventory.assert_restored!(before)

          refreshed = %{
            fixture.report
            | sequence: fixture.report.sequence + 1,
              sampled_at: Ledger.now()
          }

          assert {:ok, :ok} =
                   Marshall.Compute.HostReports.ingest(
                     fixture.host.id,
                     fixture.epoch,
                     refreshed
                   )

          assert {:ok, vm} = Marshall.Compute.provision(params, actor: actor)
          vm_id = vm.id
          assert [%{id: ^vm_id}] = Ledger.read!(VirtualMachine, owner_id: actor.id)

          assert [%{id: placement_id, vm_id: ^vm_id}] =
                   Ledger.read!(WorkloadPlacement, vm_id: vm_id)

          assert [%{vm_id: ^vm_id, placement_id: ^placement_id}] =
                   Ledger.read!(Reservation, vm_id: vm_id)

          assert [%{vm_id: ^vm_id}] = Ledger.read!(NetworkAddress, vm_id: vm_id)

          assert [%{id: root_id, vm_id: ^vm_id, owner_id: owner_id}] =
                   Ledger.read!(Marshall.Agents.Root, vm_id: vm_id)

          assert owner_id == actor.id

          assert [%{id: thread_id, root_id: ^root_id}] =
                   Ledger.read!(Marshall.Agents.Thread, root_id: root_id)

          assert [%{vm_id: ^vm_id, thread_id: ^thread_id, kind: :agent_registered}] =
                   Ledger.read!(Marshall.Agents.AuditEvent, vm_id: vm_id)

          assert [%{vm_id: ^vm_id}] = Ledger.read!(Marshall.Ingress.Endpoint, vm_id: vm_id)

          assert [
                   %{
                     id: operation_id,
                     vm_id: ^vm_id,
                     placement_id: ^placement_id,
                     kind: :provision
                   }
                 ] =
                   Ledger.read!(Operation, requested_by_id: actor.id)

          assert [
                   %{
                     version_source_id: ^vm_id,
                     version_action_name: :allocate,
                     version_action_type: :create,
                     changes: changes
                   }
                 ] =
                   Ledger.read!(VirtualMachine.Version, version_source_id: vm_id)

          assert changes["owner_id"] == actor.id

          assert [%{args: %{"primary_key" => %{"id" => ^operation_id}}}] =
                   Oban.Testing.all_enqueued(
                     repo: Repo,
                     worker: Marshall.Compute.Workers.Dispatch
                   )

          committed = Marshall.CommittedFixtureInventory.snapshot()
          assert {:ok, %{id: ^vm_id}} = Marshall.Compute.provision(params, actor: actor)

          assert {:error, error} =
                   Marshall.Compute.provision(%{params | vcpu: 3}, actor: actor)

          assert Exception.message(error) =~ "idempotency_conflict"
          Marshall.CommittedFixtureInventory.assert_restored!(committed)
        after
          cleanup(fixture.host.id, actor.id)
        end
      end)
    end
  end

  test "session retries and revocation share authority across all three nodes", %{peers: peers} do
    unboxed(fn ->
      fixture = host_fixture()
      actor = user()

      Cleanup.protect peers do
        {:ok, vm} = Marshall.Compute.provision(request(), actor: actor)
        {:ok, credential} = Marshall.Compute.Credentials.rotate(fixture.host.id, 3600)
        message = %{session_id: Ash.UUID.generate(), machine_id: fixture.host.machine_id}

        responses =
          peers
          |> Enum.map(fn peer ->
            Task.async(fn ->
              :peer.call(
                peer,
                Marshall.Compute.ProvisionerControl,
                :open_execution,
                [credential.token, message],
                30_000
              )
            end)
          end)
          |> Task.await_many(40_000)

        assert Enum.all?(responses, &match?({:ok, _}, &1))
        assert length(Enum.uniq(responses)) == 1
        [{:ok, session} | _] = responses

        exchange = %{
          session_id: message.session_id,
          epoch: session["epoch"],
          report: nil,
          acknowledgements: [],
          outcomes: []
        }

        for peer <- peers do
          assert {:ok, %{"commands" => [%{"vm_id" => id}]}} =
                   :peer.call(
                     peer,
                     Marshall.Compute.ProvisionerControl,
                     :exchange_execution,
                     [credential.token, exchange],
                     30_000
                   )

          assert id == vm.id
        end

        assert {:ok, :ok} =
                 :peer.call(
                   hd(peers),
                   Marshall.Compute.Credentials,
                   :revoke,
                   [fixture.host.id],
                   30_000
                 )

        for peer <- peers do
          assert {:error, :unauthorized} =
                   :peer.call(
                     peer,
                     Marshall.Compute.ProvisionerControl,
                     :exchange_execution,
                     [credential.token, exchange],
                     30_000
                   )
        end

        assert [%{compute_held: true, disk_held: true}] = Ledger.read!(Reservation, vm_id: vm.id)
      after
        cleanup(fixture.host.id, actor.id)
      end
    end)
  end

  test "three nodes serialize restart reservations against new provisioning after confirmed stop",
       %{peers: peers} do
    unboxed(fn ->
      machine = "sha256:" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
      fixture = host_fixture(%{machine_id: machine})
      actor = user()

      Cleanup.protect peers do
        {:ok, vm} = Marshall.Compute.provision(request(), actor: actor)
        {:ok, _other} = Marshall.Compute.provision(request(), actor: actor)

        {:ok, stop} =
          Marshall.Compute.lifecycle(%{vm_id: vm.id, kind: :stop, idempotency_key: "stop"},
            actor: actor
          )

        assert Enum.all?(Ledger.read!(Reservation, host_id: fixture.host.id), & &1.compute_held)
        {:ok, credential} = Marshall.Compute.Credentials.rotate(fixture.host.id, 3600)
        nonce = Ash.UUID.generate()

        {:ok, session} =
          :peer.call(
            hd(peers),
            Marshall.Compute.ProvisionerControl,
            :open_execution,
            [credential.token, %{session_id: nonce, machine_id: machine}],
            30_000
          )

        event = %{
          id: Ash.UUID.generate(),
          vm_id: vm.id,
          placement_id: stop.placement_id,
          execution_epoch: stop.execution_epoch,
          operation_id: stop.id,
          generation: stop.generation,
          sequence: 1,
          state: :stopped,
          compute_empty: true,
          disk_present: true,
          cleanup_complete: false,
          reason: :none
        }

        {:ok, _} =
          :peer.call(
            List.last(peers),
            Marshall.Compute.ProvisionerControl,
            :exchange_execution,
            [
              credential.token,
              %{
                session_id: nonce,
                epoch: session["epoch"],
                report: fixture.report,
                acknowledgements: [stop.id],
                outcomes: [event]
              }
            ],
            30_000
          )

        calls =
          for index <- 1..9 do
            if rem(index, 3) == 0,
              do:
                {:lifecycle, %{vm_id: vm.id, kind: :start, idempotency_key: "restart-#{index}"}},
              else: {:provision, request()}
          end

        results =
          calls
          |> Enum.with_index()
          |> Enum.map(fn {{action, params}, index} ->
            Task.async(fn ->
              result =
                :peer.call(
                  Enum.at(peers, rem(index, 3)),
                  Marshall.Compute,
                  action,
                  [params, [actor: actor]],
                  30_000
                )

              {action, result}
            end)
          end)
          |> Task.await_many(40_000)

        reservations = Ledger.read!(Reservation, host_id: fixture.host.id)
        held = Enum.filter(reservations, & &1.compute_held)
        assert Enum.sum(Enum.map(held, & &1.vcpu)) == 4
        assert Enum.sum(Enum.map(held, & &1.memory_bytes)) == 2 * (vm.memory_bytes + 67_108_864)
        restarted = Enum.any?(results, &match?({:lifecycle, {:ok, _}}, &1))
        provisioned = Enum.count(results, &match?({:provision, {:ok, _}}, &1))
        assert (restarted and provisioned == 0) or (not restarted and provisioned == 1)

        assert Enum.all?(
                 for({_action, {:error, error}} <- results, do: error),
                 &(Exception.message(&1) =~ "insufficient_capacity")
               )
      after
        cleanup(fixture.host.id, actor.id)
      end
    end)
  end

  test "a lifecycle job failure rolls back intent, cancellation, reservation and audit",
       _context do
    unboxed(fn ->
      fixture = host_fixture()
      actor = user()

      Cleanup.protect do
        {:ok, vm} = Marshall.Compute.provision(request(), actor: actor)
        [original] = Ledger.read!(Operation, vm_id: vm.id)
        before_versions = Ledger.read!(VirtualMachine.Version)

        assert_raise Ash.Error.Unknown, fn ->
          Repo.transaction(fn ->
            Ecto.Adapters.SQL.query!(Repo, """
            CREATE FUNCTION pg_temp.reject_lifecycle_job() RETURNS trigger LANGUAGE plpgsql AS
            $$ BEGIN RAISE EXCEPTION 'injected lifecycle job insert failure'; END $$
            """)

            Ecto.Adapters.SQL.query!(Repo, """
            CREATE TRIGGER reject_lifecycle_job BEFORE INSERT ON oban_jobs
            FOR EACH ROW WHEN (NEW.queue = 'provisioning') EXECUTE FUNCTION pg_temp.reject_lifecycle_job()
            """)

            Marshall.Compute.lifecycle(%{vm_id: vm.id, kind: :stop, idempotency_key: "rollback"},
              actor: actor
            )
          end)
        end

        assert [%{generation: 1, desired_state: :running}] =
                 Ledger.read!(VirtualMachine, id: vm.id)

        assert [^original] = Ledger.read!(Operation, vm_id: vm.id)
        assert before_versions == Ledger.read!(VirtualMachine.Version)
        assert [%{compute_held: true, disk_held: true}] = Ledger.read!(Reservation, vm_id: vm.id)
      after
        cleanup(fixture.host.id, actor.id)
      end
    end)
  end

  test "sharing retries and revocation stay authoritative across three nodes", %{peers: peers} do
    unboxed(fn ->
      fixture = host_fixture()
      owner = user()
      member = user()
      {:ok, vm} = Marshall.Compute.provision(request(), actor: owner)

      request = %{
        vm_id: vm.id,
        email: to_string(member.email),
        role: :manager,
        idempotency_key: Ash.UUID.generate()
      }

      Cleanup.protect peers do
        results =
          for index <- 0..8 do
            Task.async(fn ->
              :peer.call(
                Enum.at(peers, rem(index, 3)),
                Marshall.Access,
                :set_access,
                [request, [actor: owner]],
                30_000
              )
            end)
          end
          |> Task.await_many(40_000)

        assert Enum.all?(results, &match?({:ok, _}, &1))
        assert length(Enum.uniq(Enum.map(results, fn {:ok, change} -> change.id end))) == 1
        assert length(Ledger.read!(Marshall.Access.Grant, vm_id: vm.id)) == 1

        assert {:ok, _} =
                 :peer.call(hd(peers), Marshall.Access, :set_access, [
                   %{request | role: :revoked, idempotency_key: Ash.UUID.generate()},
                   [actor: owner]
                 ])

        for peer <- peers do
          assert {:ok, _} =
                   :peer.call(peer, Marshall.Access, :set_access, [request, [actor: owner]])

          assert {:error, _} =
                   :peer.call(peer, Marshall.Compute, :get_vm, [%{vm_id: vm.id}, [actor: member]])
        end

        assert Ledger.read!(Marshall.Access.Grant, vm_id: vm.id) == []
        assert length(Ledger.read!(Marshall.Access.Change, vm_id: vm.id)) == 2
      after
        cleanup(fixture.host.id, owner.id)

        Ecto.Adapters.SQL.query!(Repo, "DELETE FROM users WHERE id = $1", [
          Ecto.UUID.dump!(member.id)
        ])
      end
    end)
  end

  test "a lifecycle request waiting on a VM rechecks a manager revoked under that lock", %{
    peers: [peer | _]
  } do
    unboxed(fn ->
      fixture = host_fixture()
      owner = user()
      manager = user()
      {:ok, vm} = Marshall.Compute.provision(request(), actor: owner)

      access = %{
        vm_id: vm.id,
        email: to_string(manager.email),
        role: :manager,
        idempotency_key: Ash.UUID.generate()
      }

      {:ok, _} = Marshall.Access.set_access(access, actor: owner)

      Cleanup.protect [peer] do
        {:ok, task} =
          Ledger.transaction(fn ->
            Ledger.lock!(VirtualMachine, vm.id)
            tag = "access-waiter-" <> Ash.UUID.generate()

            task =
              Task.async(fn ->
                :peer.call(
                  peer,
                  Marshall.AccessRace,
                  :lifecycle,
                  [
                    tag,
                    %{vm_id: vm.id, kind: :stop, idempotency_key: Ash.UUID.generate()},
                    manager
                  ],
                  30_000
                )
              end)

            wait_for_access_lock(tag, System.monotonic_time(:millisecond) + 5000)

            assert {:ok, _} =
                     Marshall.Access.set_access(
                       %{access | role: :revoked, idempotency_key: Ash.UUID.generate()},
                       actor: owner
                     )

            task
          end)

        assert {:error, error} = Task.await(task, 35_000)
        assert Exception.message(error) =~ "forbidden"

        assert [%{generation: 1, desired_state: :running}] =
                 Ledger.read!(VirtualMachine, id: vm.id)

        assert length(Ledger.read!(Operation, vm_id: vm.id)) == 1
      after
        cleanup(fixture.host.id, owner.id)

        Ecto.Adapters.SQL.query!(Repo, "DELETE FROM users WHERE id = $1", [
          Ecto.UUID.dump!(manager.id)
        ])
      end
    end)
  end

  defp wait_for_access_lock(tag, deadline) do
    Ecto.Adapters.SQL.query!(Repo, "SELECT pg_stat_clear_snapshot()", [], log: false)

    %{rows: [[waiting]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE application_name = $1 AND wait_event_type = 'Lock')",
        [tag],
        log: false
      )

    unless waiting do
      assert System.monotonic_time(:millisecond) < deadline, "manager did not reach the VM lock"

      receive do
      after
        10 -> wait_for_access_lock(tag, deadline)
      end
    end
  end

  test "three control planes accept a retried host report once", %{
    peers: peers
  } do
    unboxed(fn ->
      fixture = host_fixture()
      actor = user()

      Cleanup.protect peers do
        report = %{fixture.report | sequence: 2}

        results =
          peers
          |> Enum.flat_map(fn peer ->
            for _ <- 1..3 do
              Task.async(fn ->
                :peer.call(
                  peer,
                  Marshall.Compute.HostReports,
                  :ingest,
                  [fixture.host.id, fixture.epoch, report],
                  30_000
                )
              end)
            end
          end)
          |> Task.await_many(40_000)

        assert Enum.count(results, &(&1 == {:ok, :ok})) == 1
        assert Enum.count(results, &(&1 == {:error, :stale_report})) == 8
        [host] = Ledger.read!(Marshall.Compute.Host, id: fixture.host.id)
        assert host.report_sequence == 2
      after
        cleanup(fixture.host.id, actor.id)
      end
    end)
  end

  test "three nodes share mail cooldown, serialize SMTP delivery and roll back failed enqueue",
       %{peers: peers} do
    unboxed(fn ->
      alias Marshall.Accounts.{AuthEmail, AuthEmails, User}
      actor = user()
      email = to_string(actor.email)
      strategy = AshAuthentication.Info.strategy!(User, :magic_link)

      {:ok, token} =
        AshAuthentication.Strategy.MagicLink.request_token_for_identity(strategy, email)

      {:ok, claims} = AshAuthentication.Jwt.peek(token)
      fingerprint = :crypto.hash(:sha256, token) |> Base.encode16(case: :lower)

      try do
        assert {:error, :mail_enqueue_failed} =
                 Repo.transaction(fn ->
                   Ecto.Adapters.SQL.query!(Repo, """
                   CREATE FUNCTION pg_temp.reject_auth_email_job() RETURNS trigger LANGUAGE plpgsql AS
                   $$ BEGIN RAISE EXCEPTION 'injected auth email job failure'; END $$
                   """)

                   Ecto.Adapters.SQL.query!(Repo, """
                   CREATE TRIGGER reject_auth_email_job BEFORE INSERT ON oban_jobs
                   FOR EACH ROW WHEN (NEW.worker = 'Marshall.Accounts.Workers.DeliverAuthEmail')
                   EXECUTE FUNCTION pg_temp.reject_auth_email_job()
                   """)

                   case AuthEmails.enqueue(email, token) do
                     :ok -> :ok
                     {:error, reason} -> Repo.rollback(reason)
                   end
                 end)

        assert [] == Ledger.read!(AuthEmail, token_fingerprint: fingerprint)

        assert {:ok, [_]} =
                 AshAuthentication.TokenResource.Actions.get_token(
                   Marshall.Accounts.Token,
                   %{"jti" => claims["jti"], "purpose" => "magic_link"}
                 )

        results =
          peers
          |> Enum.map(fn peer ->
            Task.async(fn -> :peer.call(peer, AuthEmails, :enqueue, [email, token], 30_000) end)
          end)
          |> Task.await_many(40_000)

        assert results == [:ok, :ok, :ok]
        assert [record] = Ledger.read!(AuthEmail, token_fingerprint: fingerprint)

        assert %{rows: [[1]]} =
                 Ecto.Adapters.SQL.query!(
                   Repo,
                   "SELECT count(*) FROM oban_jobs WHERE worker = 'Marshall.Accounts.Workers.DeliverAuthEmail' AND args->'primary_key'->>'id' = $1",
                   [record.id]
                 )

        race_auth_delivery(peers, record)
      after
        Cleanup.jobs!(
          "worker = 'Marshall.Accounts.Workers.DeliverAuthEmail' AND args->'primary_key'->>'id' IN (SELECT id::text FROM account_auth_emails WHERE token_fingerprint = $1)",
          [fingerprint]
        )

        Ecto.Adapters.SQL.query!(
          Repo,
          "DELETE FROM account_auth_emails WHERE token_fingerprint = $1",
          [fingerprint]
        )

        Ecto.Adapters.SQL.query!(Repo, "DELETE FROM tokens WHERE jti = $1", [claims["jti"]])

        Ecto.Adapters.SQL.query!(Repo, "DELETE FROM users WHERE id = $1", [
          Ecto.UUID.dump!(actor.id)
        ])
      end
    end)
  end

  defp race_auth_delivery(peers, record) do
    fixtures = Path.expand("../../fixtures/tls", __DIR__)

    server =
      start_supervised!(
        {Marshall.SMTPFixture,
         [
           mode: :implicit,
           owner: self(),
           cert: Path.join(fixtures, "localhost.pem"),
           key: Path.join(fixtures, "localhost.key")
         ]}
      )

    {:ok, smtp, _} =
      Marshall.Mailer.Config.from_env(%{
        "MARSHALL_SMTP_HOST" => "localhost",
        "MARSHALL_SMTP_PORT" => to_string(Marshall.SMTPFixture.port(server)),
        "MARSHALL_SMTP_USERNAME" => "test-user",
        "MARSHALL_SMTP_PASSWORD" => "test-password",
        "MARSHALL_MAIL_FROM" => "noreply@example.test",
        "MARSHALL_SMTP_CA_CERTFILE" => Path.join(fixtures, "ca.pem")
      })

    original =
      Enum.map(peers, fn peer ->
        {peer, :peer.call(peer, Application, :fetch_env!, [:marshall, Marshall.Mailer])}
      end)

    try do
      for peer <- peers,
          do: :peer.call(peer, Application, :put_env, [:marshall, Marshall.Mailer, smtp])

      results =
        peers
        |> Enum.map(fn peer ->
          Task.async(fn ->
            :peer.call(
              peer,
              Oban.Testing,
              :perform_job,
              [
                Marshall.Accounts.Workers.DeliverAuthEmail,
                %{"primary_key" => %{"id" => record.id}},
                [repo: Repo]
              ],
              30_000
            )
          end)
        end)
        |> Task.await_many(40_000)

      assert Enum.all?(results, fn result ->
               match?({:ok, %{status: :delivered}}, result) or match?({:cancel, _}, result)
             end)

      assert count_auth_messages(0) == 1

      assert [%{status: :delivered, encrypted_payload: nil}] =
               Ledger.read!(Marshall.Accounts.AuthEmail, id: record.id)
    after
      for {peer, config} <- original,
          do: :peer.call(peer, Application, :put_env, [:marshall, Marshall.Mailer, config])
    end
  end

  defp count_auth_messages(count) do
    receive do
      {:smtp_message, _} -> count_auth_messages(count + 1)
    after
      0 -> count
    end
  end

  test "three nodes serialize drain with provisioning, starts, duplicate workers and deletion", %{
    peers: peers
  } do
    unboxed(fn ->
      alias Marshall.Compute.{Drains, Host, HostDrain}
      fixture = host_fixture()
      actor = user()
      id = Ash.UUID.generate()

      Cleanup.protect peers do
        {:ok, vm} = Marshall.Compute.provision(request(), actor: actor)

        calls = [
          {Drains, :request, [fixture.host.id, id, "cluster-test"]},
          {Marshall.Compute, :lifecycle,
           [%{vm_id: vm.id, kind: :start, idempotency_key: "start-race"}, [actor: actor]]},
          {Marshall.Compute, :provision, [request(), [actor: actor]]}
        ]

        results =
          Enum.zip(peers, calls)
          |> Enum.map(fn {peer, {module, action, args}} ->
            Task.async(fn -> :peer.call(peer, module, action, args, 30_000) end)
          end)
          |> Task.await_many(40_000)

        assert {:ok, %{id: ^id}} = hd(results)

        assert [%{maintenance_mode: :draining, enabled: false}] =
                 Ledger.read!(Host, id: fixture.host.id)

        assert [drain] = Ledger.read!(HostDrain, id: id)

        for peer <- peers do
          assert {:error, _} =
                   :peer.call(peer, Marshall.Compute, :provision, [request(), [actor: actor]])

          assert {:error, _} =
                   :peer.call(peer, Marshall.Compute, :lifecycle, [
                     %{vm_id: vm.id, kind: :start, idempotency_key: Ash.UUID.generate()},
                     [actor: actor]
                   ])

          assert {:ok, %{id: ^id}} =
                   :peer.call(peer, Drains, :request, [fixture.host.id, id, "cluster-test"])
        end

        workers =
          Enum.map(peers, fn peer ->
            Task.async(fn ->
              :peer.call(
                peer,
                Oban.Testing,
                :perform_job,
                [
                  Marshall.Compute.Workers.AdvanceDrain,
                  %{"primary_key" => %{"id" => drain.id}},
                  [repo: Repo]
                ],
                30_000
              )
            end)
          end)

        deleting =
          Task.async(fn ->
            :peer.call(hd(peers), Marshall.Compute, :lifecycle, [
              %{vm_id: vm.id, kind: :delete, idempotency_key: "delete-during-drain"},
              [actor: actor]
            ])
          end)

        assert [:ok, :ok, :ok, {:ok, deletion}] = Task.await_many(workers ++ [deleting], 40_000)
        vms = Ledger.read!(VirtualMachine, host_id: fixture.host.id)
        stops = Ledger.read!(Operation, host_drain_id: id)
        assert length(Enum.uniq_by(stops, & &1.vm_id)) == length(stops)
        assert length(stops) in [length(vms), length(vms) - 1]

        assert Enum.all?(
                 vms,
                 &(&1.desired_state == if(&1.id == vm.id, do: :deleted, else: :stopped))
               )

        assert Enum.all?(stops, &(&1.vm_id != vm.id or &1.generation < deletion.generation))
        assert Enum.all?(Ledger.read!(Reservation, host_id: fixture.host.id), & &1.compute_held)

        assert {:ok, 0} = :peer.call(List.last(peers), Drains, :advance, [id])

        assert [%{generation: generation, desired_state: :deleted}] =
                 Ledger.read!(VirtualMachine, id: vm.id)

        assert generation == deletion.generation
      after
        cleanup(fixture.host.id, actor.id)
      end
    end)
  end

  test "failed drain enqueue and failed continuation roll back the whole host batch" do
    unboxed(fn ->
      alias Marshall.Compute.{Drains, Host, HostDrain, HostReports}
      fixture = host_fixture()
      actor = user()
      id = Ash.UUID.generate()

      Cleanup.protect do
        assert {:error, :injected} =
                 Repo.transaction(fn ->
                   reject_maintenance_jobs()

                   assert {:error, :operator_operation_failed_verify_output} =
                            Drains.request(fixture.host.id, id, "failure-test")

                   Repo.rollback(:injected)
                 end)

        assert [%{maintenance_mode: :normal, enabled: true}] =
                 Ledger.read!(Host, id: fixture.host.id)

        assert [] = Ledger.read!(HostDrain, id: id)

        report = %{
          fixture.report
          | effective_cores: 100,
            effective_memory_bytes: 100_000_000_000,
            capacity: capacity(100, 100_000_000_000),
            sequence: 2,
            sampled_at: Ledger.now(),
            pools: [
              %{
                hd(fixture.report.pools)
                | total_bytes: 100_000_000_000,
                  free_bytes: 100_000_000_000,
                  storage: %{hd(fixture.report.pools).storage | quota_bytes: 100_000_000_000}
              }
            ]
        }

        {:ok, :ok} = HostReports.ingest(fixture.host.id, fixture.epoch, report)
        for _ <- 1..21, do: assert({:ok, _} = Marshall.Compute.provision(request(), actor: actor))
        {:ok, _} = Drains.request(fixture.host.id, id, "failure-test")

        assert_raise DBConnection.ConnectionError, fn ->
          Repo.transaction(fn ->
            reject_maintenance_jobs()
            Drains.advance(id)
          end)
        end

        assert [] = Ledger.read!(Operation, host_drain_id: id)

        assert Enum.all?(
                 Ledger.read!(VirtualMachine, host_id: fixture.host.id),
                 &(&1.generation == 1 and &1.desired_state == :running)
               )

        assert %{success: 2, failure: 0} =
                 Oban.drain_queue(queue: :maintenance, with_recursion: true)

        assert length(Ledger.read!(Operation, host_drain_id: id)) == 21
      after
        cleanup(fixture.host.id, actor.id)
      end
    end)
  end

  @tag :tmp_dir
  test "three operators recover one enrollment and one immediate rotation", %{
    peers: peers,
    tmp_dir: directory
  } do
    File.chmod!(directory, 0o700)

    input = %{
      "version" => 3,
      "name" => "prepare-#{Ash.UUID.generate()}",
      "architecture" => "x86_64",
      "machine_id" => "sha256:" <> Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
      "overhead_cores" => 1,
      "overhead_memory_bytes" => 1024,
      "credential_ttl_seconds" => 157_680_000,
      "pools" => [
        %{
          "name" => "guests",
          "overhead_bytes" => 100,
          "storage" => %{
            "backend" => "zfs",
            "zpool_guid" => "1",
            "dataset_guid" => "2",
            "dataset" => "tank/lilly"
          }
        }
      ]
    }

    request = Path.join(directory, "request.json")
    File.write!(request, JSON.encode!(input))
    File.chmod!(request, 0o600)
    actor = unboxed(fn -> user() end)

    run = fn kind, operation ->
      peers
      |> Enum.with_index()
      |> Enum.map(fn {peer, index} ->
        Task.async(fn ->
          :peer.call(
            peer,
            Marshall.Compute.EnrollmentPreparation,
            :prepare_file,
            [operation, kind, request, Path.join(directory, "#{kind}-#{index}.json")],
            30_000
          )
        end)
      end)
      |> Task.await_many(40_000)
    end

    Cleanup.protect peers do
      results = run.(:prepare, Ash.UUID.generate())
      assert [{:ok, first}] = Enum.uniq(results)
      results = run.(:rotate, Ash.UUID.generate())
      assert [{:ok, rotated}] = Enum.uniq(results)
      refute first.credential_id == rotated.credential_id

      unboxed(fn ->
        assert [_] = Ledger.read!(Marshall.Compute.HostCredential, host_id: first.host_id)

        assert [_first, _rotation] =
                 Ledger.read!(Marshall.Compute.EnrollmentOperation, host_id: first.host_id)

        assert {:error, :credential_inactive} =
                 Marshall.Compute.Enrollment.verify_file(Path.join(directory, "prepare-0.json"))

        assert {:ok, _} =
                 Marshall.Compute.Enrollment.verify_file(Path.join(directory, "rotate-0.json"))
      end)
    after
      unboxed(fn ->
        for host <- Ledger.read!(Marshall.Compute.Host, name: input["name"]) do
          Ecto.Adapters.SQL.query!(
            Repo,
            "DELETE FROM compute_enrollment_operations WHERE host_id = $1",
            [Ecto.UUID.dump!(host.id)]
          )

          cleanup(host.id, actor.id)
        end
      end)
    end
  end

  for force <- [false, true] do
    @tag force_cancellation: force
    test "three Marshall nodes race cancellation/restoration against handoff, cancel first=#{force}",
         %{
           peers: peers,
           force_cancellation: force_cancellation
         } do
      unboxed(fn ->
        alias Marshall.Compute.{
          Host,
          Relocation,
          RelocationCapacity,
          RelocationCoordinator,
          RelocationImports,
          RelocationReceives,
          RelocationSources,
          Credentials,
          ProvisionerControl
        }

        source = host_fixture()
        owner = user()
        {:ok, vm} = Marshall.Compute.provision(request(), actor: owner)
        destination = host_fixture()

        Cleanup.protect peers do
          [initial] = Ledger.read!(Operation, vm_id: vm.id)
          Ledger.update!(initial, :complete, %{})
          vm = Ledger.intent!(vm, %{desired_state: :stopped})
          vm = Ledger.update!(vm, :observe, %{observed_state: :stopped})
          [hold] = Ledger.read!(Reservation, placement_id: vm.current_placement_id)
          Ledger.update!(hold, :release_compute, %{})

          {:ok, relocation} =
            Ledger.transaction(fn ->
              hosts =
                Host
                |> Ledger.read!()
                |> Enum.sort_by(& &1.id)
                |> Enum.map(&Ledger.lock!(Host, &1.id))

              vm = Ledger.lock!(VirtualMachine, vm.id)
              RelocationCapacity.reserve_locked!(vm, hosts, owner, Ash.UUID.generate())
            end)

          relocation =
            Ledger.update!(relocation, :record_key, %{
              destination_public_key: transfer_endpoint()["host_key"]
            })

          sessions =
            for endpoint <- [source, destination] do
              {:ok, credential} = Credentials.rotate(endpoint.host.id, 3600)

              {:ok, session} =
                ProvisionerControl.open_execution(
                  credential.token,
                  %{session_id: Ash.UUID.generate(), machine_id: endpoint.host.machine_id}
                )

              {credential.token,
               %{session_id: session["session_id"], epoch: session["epoch"], results: []}}
            end

          [{source_token, source_message}, {target_token, target_message}] = sessions

          {:ok, %{"commands" => [wire]}} =
            RelocationSources.exchange(source_token, source_message)

          {:ok, command} = OverallsProtocol.RelocationSource.command(wire)

          result = %{
            id: command.id,
            descriptor:
              Map.put(command.intent, :stream, %{
                source_dataset_guid: "100",
                to_guid: "200"
              })
          }

          {:ok, _} =
            RelocationSources.exchange(source_token, %{source_message | results: [result]})

          receipt = Map.put(result, :dataset_guid, "300")

          {:ok, _} =
            RelocationReceives.exchange(target_token, %{target_message | results: [receipt]})

          {:ok, %{"commands" => [_]}} = RelocationImports.exchange(target_token, target_message)

          {:ok, _} =
            RelocationImports.exchange(target_token, %{target_message | results: [receipt]})

          Ledger.update!(destination.host, :report, %{reported_at: Ledger.now()})

          if force_cancellation do
            assert {:ok, _} =
                     Marshall.Compute.cancel_relocation(%{relocation_id: relocation.id},
                       actor: owner
                     )
          end

          results =
            for n <- 0..11 do
              peer = Enum.at(peers, rem(n, 3))

              Task.async(fn ->
                if rem(n, 2) == 0 do
                  {:cancel,
                   :peer.call(
                     peer,
                     Marshall.Compute,
                     :cancel_relocation,
                     [%{relocation_id: relocation.id}, [actor: owner]],
                     30_000
                   )}
                else
                  {:advance,
                   :peer.call(peer, RelocationCoordinator, :advance, [relocation.id], 30_000)}
                end
              end)
            end
            |> Task.await_many(40_000)

          [retained] = Ledger.read!(Relocation, id: relocation.id)
          [current] = Ledger.read!(VirtualMachine, id: vm.id)

          if retained.cancellation_requested_at do
            assert retained.committed_at == nil and retained.activation_operation_id == nil
            assert current.current_placement_id == vm.current_placement_id

            assert current.execution_epoch == vm.execution_epoch and
                     current.generation == vm.generation

            assert [] == Ledger.read!(Operation, relocation_id: relocation.id)

            assert Enum.all?(results, fn
                     {:cancel, {:ok, value}} ->
                       value.cancellation_requested_at == retained.cancellation_requested_at

                     {:advance, {:ok, :cancelling}} ->
                       true

                     _ ->
                       false
                   end)

            assert {:ok, %{"commands" => [revocation_wire]}} =
                     Marshall.Compute.RelocationRevocations.exchange(source_token, source_message)

            assert {:ok, %{"commands" => [destination_wire]}} =
                     Marshall.Compute.RelocationDestinationRevocations.exchange(
                       target_token,
                       target_message
                     )

            {:ok, destination_revoke} =
              OverallsProtocol.RelocationDestinationRevocation.command(destination_wire)

            destination_result =
              Map.take(destination_revoke, [:id, :placement_id, :execution_epoch])

            assert Enum.all?(
                     relocation_calls(
                       peers,
                       Marshall.Compute.RelocationDestinationRevocations,
                       :exchange,
                       [target_token, %{target_message | results: [destination_result]}]
                     ),
                     &match?({:ok, %{"acknowledgements" => [_]}}, &1)
                   )

            assert [%{destination_revoked_at: destination_confirmed, finished_at: nil}] =
                     Ledger.read!(Relocation, id: relocation.id)

            assert destination_confirmed != nil

            for endpoint <- [:source_relocation_id, :destination_relocation_id] do
              assert [%{released_at: nil}] =
                       Ledger.read!(Marshall.Compute.TransferSlot, [{endpoint, relocation.id}])
            end

            {:ok, revocation} = OverallsProtocol.RelocationRevocation.command(revocation_wire)
            revoked = Map.take(revocation, [:id, :placement_id, :execution_epoch])

            receipts =
              relocation_calls(peers, Marshall.Compute.RelocationRevocations, :exchange, [
                source_token,
                %{source_message | results: [revoked]}
              ])

            assert Enum.all?(receipts, &match?({:ok, %{"acknowledgements" => [_]}}, &1))

            assert [%{source_revoked_at: confirmed, activation_operation_id: nil}] =
                     Ledger.read!(Relocation, id: relocation.id)

            assert confirmed != nil

            assert Enum.all?(
                     relocation_calls(peers, RelocationCoordinator, :advance, [relocation.id]),
                     &(&1 == {:ok, :restoring_source})
                   )

            assert [%{kind: :stop} = fence] =
                     Ledger.read!(Operation, relocation_id: relocation.id)

            for endpoint <- [:source_relocation_id, :destination_relocation_id] do
              assert [%{released_at: released}] =
                       Ledger.read!(Marshall.Compute.TransferSlot, [{endpoint, relocation.id}])

              assert released != nil
            end

            assert fence.placement_id == relocation.source_placement_id and
                     fence.execution_epoch == relocation.destination_epoch

            source_execution =
              Map.merge(source_message, %{report: nil, acknowledgements: [], outcomes: []})

            assert {:ok, %{"commands" => [_]}} =
                     ProvisionerControl.exchange_execution(source_token, source_execution)

            stopped = %{
              id: Ash.UUID.generate(),
              vm_id: vm.id,
              placement_id: fence.placement_id,
              execution_epoch: fence.execution_epoch,
              generation: fence.generation,
              operation_id: fence.id,
              sequence: 1,
              state: :stopped,
              compute_empty: true,
              disk_present: true,
              cleanup_complete: false,
              reason: :none
            }

            assert {:ok, _} =
                     ProvisionerControl.exchange_execution(source_token, %{
                       source_execution
                       | outcomes: [stopped]
                     })

            assert Enum.all?(
                     relocation_calls(peers, RelocationCoordinator, :advance, [relocation.id]),
                     &(&1 == {:ok, :source_restored_pending_cleanup})
                   )

            assert [%{source_restored_at: restored, committed_at: nil, finished_at: nil}] =
                     Ledger.read!(Relocation, id: relocation.id)

            assert restored != nil

            holds_before_cleanup = Ledger.read!(Marshall.Compute.Reservation, vm_id: vm.id)

            assert {:ok, %{"commands" => [cleanup_wire]}} =
                     Marshall.Compute.RelocationSnapshotCleanups.exchange(
                       source_token,
                       source_message
                     )

            {:ok, cleanup} = OverallsProtocol.RelocationSnapshotCleanup.command(cleanup_wire)
            cleanup_result = Map.take(cleanup, [:id, :placement_id, :execution_epoch])

            assert Enum.all?(
                     relocation_calls(
                       peers,
                       Marshall.Compute.RelocationSnapshotCleanups,
                       :exchange,
                       [source_token, %{source_message | results: [cleanup_result]}]
                     ),
                     &match?({:ok, %{"acknowledgements" => [_]}}, &1)
                   )

            assert [%{source_snapshots_cleaned_at: cleaned, finished_at: nil}] =
                     Ledger.read!(Relocation, id: relocation.id)

            assert cleaned != nil

            assert holds_before_cleanup ==
                     Ledger.read!(Marshall.Compute.Reservation, vm_id: vm.id)

            assert {:ok, %{"commands" => [_]}} =
                     Marshall.Compute.RelocationDestinationCleanups.exchange(
                       target_token,
                       target_message
                     )

            assert Enum.all?(
                     relocation_calls(
                       peers,
                       Marshall.Compute.RelocationDestinationCleanups,
                       :exchange,
                       [target_token, %{target_message | results: [destination_result]}]
                     ),
                     &match?({:ok, %{"acknowledgements" => [_]}}, &1)
                   )

            completions =
              relocation_calls(peers, RelocationCoordinator, :advance, [relocation.id])

            assert Enum.count(completions, &(&1 == {:ok, :cancelled})) == 1
            assert Enum.all?(completions, &(&1 in [{:ok, :cancelled}, {:ok, :finished}]))
            [finished] = Ledger.read!(Relocation, id: relocation.id)
            assert finished.finished_at != nil and finished.committed_at == nil

            [source_hold] =
              Ledger.read!(Reservation, placement_id: relocation.source_placement_id)

            [destination_hold] =
              Ledger.read!(Reservation, placement_id: relocation.destination_placement_id)

            assert source_hold.disk_held
            refute destination_hold.disk_held or destination_hold.compute_held

            assert source_hold.temporary_disk_bytes == 0 and
                     destination_hold.temporary_disk_bytes == 0
          else
            assert retained.committed_at != nil and retained.activation_operation_id != nil
            assert current.current_placement_id == relocation.destination_placement_id
            assert current.execution_epoch == relocation.destination_epoch
            assert [_] = Ledger.read!(Operation, relocation_id: relocation.id)

            assert Enum.all?(results, fn
                     {:cancel, {:error, error}} ->
                       Exception.message(error) =~ "relocation_committed"

                     {:advance, {:ok, :committed}} ->
                       true

                     _ ->
                       false
                   end)
          end

          assert retained.finished_at == nil

          if retained.committed_at != nil do
            assert Enum.all?(Ledger.read!(Reservation, vm_id: vm.id), & &1.disk_held)
          end
        after
          cleanup_relocation_fixture(vm, destination.host.id)
          cleanup(source.host.id, owner.id)
          cleanup(destination.host.id, owner.id)
        end
      end)
    end
  end

  test "late snapshot receipts on three nodes serialize on the archived VM row", %{peers: peers} do
    unboxed(fn ->
      alias Marshall.Compute.{
        Host,
        Relocation,
        RelocationCapacity,
        RelocationSnapshotCleanups,
        Credentials,
        ProvisionerControl
      }

      source = host_fixture()
      owner = user()
      {:ok, vm} = Marshall.Compute.provision(request(), actor: owner)
      destination = host_fixture()

      Cleanup.protect peers do
        [initial] = Ledger.read!(Operation, vm_id: vm.id)
        Ledger.update!(initial, :complete, %{})
        vm = Ledger.update!(vm, :observe, %{observed_state: :running})

        {:ok, relocation} =
          Ledger.transaction(fn ->
            hosts =
              Host
              |> Ledger.read!()
              |> Enum.sort_by(& &1.id)
              |> Enum.map(&Ledger.lock!(Host, &1.id))

            vm = Ledger.lock!(VirtualMachine, vm.id)
            RelocationCapacity.reserve_locked!(vm, hosts, owner, Ash.UUID.generate())
          end)

        assert {:ok, _} =
                 Marshall.Compute.lifecycle(
                   %{vm_id: vm.id, kind: :delete, idempotency_key: Ash.UUID.generate()},
                   actor: owner
                 )

        {:ok, credential} = Credentials.rotate(source.host.id, 3600)

        {:ok, session} =
          ProvisionerControl.open_execution(
            credential.token,
            %{session_id: Ash.UUID.generate(), machine_id: source.host.machine_id}
          )

        message = %{session_id: session["session_id"], epoch: session["epoch"], results: []}

        assert {:ok, %{"commands" => [_]}} =
                 RelocationSnapshotCleanups.exchange(credential.token, message)

        # This fixture isolates receipt serialization, not physical deletion. The
        # complete Delete flow is exercised by RelocationSourcesTest and native tests.
        assert {:ok, :ok} =
                 Ledger.transaction(fn ->
                   for id <- Enum.sort([source.host.id, destination.host.id]),
                       do: Ledger.lock!(Host, id)

                   vm = Ledger.lock!(VirtualMachine, vm.id)
                   relocation = Ledger.lock!(Relocation, relocation.id)
                   Ledger.update!(relocation, :finish_deletion, %{finished_at: Ledger.now()})
                   Ledger.archive!(vm, :archive)
                 end)

        assert [] == Ledger.read!(VirtualMachine, id: vm.id)
        holds = Ledger.read!(Reservation, vm_id: vm.id) |> Enum.sort_by(& &1.id)

        result = %{
          id: relocation.id,
          placement_id: relocation.source_placement_id,
          execution_epoch: relocation.source_epoch
        }

        request = %{message | results: [result]}

        assert {:ok, task} =
                 Ledger.transaction(fn ->
                   # Only the destination host and VM are held here. The source receipt
                   # acquires its own source host first, so its observed wait must be on VM.
                   Ledger.lock!(Host, destination.host.id)
                   archived = Ledger.lock_history!(VirtualMachine, vm.id)
                   assert archived.archived_at != nil

                   %{rows: [[backend]]} =
                     Ecto.Adapters.SQL.query!(Repo, "SELECT pg_backend_pid()", [], log: false)

                   task =
                     Task.async(fn ->
                       :peer.call(
                         hd(peers),
                         RelocationSnapshotCleanups,
                         :exchange,
                         [credential.token, request],
                         30_000
                       )
                     end)

                   wait_for_retained_vm_lock(backend, System.monotonic_time(:millisecond) + 5000)

                   assert [%{source_snapshots_cleaned_at: nil}] =
                            Ledger.read!(Relocation, id: relocation.id)

                   task
                 end)

        assert {:ok, %{"commands" => [], "acknowledgements" => [_]}} = Task.await(task, 30_000)
        [first] = Ledger.read!(Relocation, id: relocation.id)
        assert first.source_snapshots_cleaned_at != nil

        for peer <- peers do
          assert {:ok, %{"commands" => [], "acknowledgements" => [_]}} =
                   :peer.call(peer, RelocationSnapshotCleanups, :exchange, [
                     credential.token,
                     request
                   ])
        end

        assert [^first] = Ledger.read!(Relocation, id: relocation.id)
        assert holds == Ledger.read!(Reservation, vm_id: vm.id) |> Enum.sort_by(& &1.id)
        assert [] == Ledger.read!(VirtualMachine, id: vm.id)
      after
        cleanup_relocation_fixture(vm, destination.host.id)
        cleanup(source.host.id, owner.id)
        cleanup(destination.host.id, owner.id)
      end
    end)
  end

  defp wait_for_retained_vm_lock(backend, deadline) do
    Ecto.Adapters.SQL.query!(Repo, "SELECT pg_stat_clear_snapshot()", [], log: false)

    %{rows: [[waiting]]} =
      Ecto.Adapters.SQL.query!(
        Repo,
        "SELECT EXISTS (SELECT 1 FROM pg_stat_activity WHERE $1 = ANY(pg_blocking_pids(pid)) AND wait_event_type = 'Lock')",
        [backend],
        log: false
      )

    unless waiting do
      assert System.monotonic_time(:millisecond) < deadline,
             "late receipt did not lock the archived VM"

      receive do
      after
        10 -> wait_for_retained_vm_lock(backend, deadline)
      end
    end
  end

  for deletion_phase <- [:before_handoff, :after_handoff, :racing_handoff] do
    @tag deletion_phase: deletion_phase
    test "three nodes serialize logical Delete #{deletion_phase} with handoff", %{
      peers: peers,
      deletion_phase: phase
    } do
      unboxed(fn ->
        alias Marshall.Compute.{
          Host,
          Relocation,
          RelocationCapacity,
          RelocationCoordinator,
          RelocationImports,
          RelocationReceives,
          RelocationSources,
          Credentials,
          ProvisionerControl
        }

        source = host_fixture()
        owner = user()
        {:ok, vm} = Marshall.Compute.provision(request(), actor: owner)
        destination = host_fixture()

        Cleanup.protect peers do
          [initial] = Ledger.read!(Operation, vm_id: vm.id)
          Ledger.update!(initial, :complete, %{})
          vm = Ledger.intent!(vm, %{desired_state: :stopped})
          vm = Ledger.update!(vm, :observe, %{observed_state: :stopped})
          [hold] = Ledger.read!(Reservation, placement_id: vm.current_placement_id)
          Ledger.update!(hold, :release_compute, %{})

          {:ok, relocation} =
            Ledger.transaction(fn ->
              hosts =
                Host
                |> Ledger.read!()
                |> Enum.sort_by(& &1.id)
                |> Enum.map(&Ledger.lock!(Host, &1.id))

              vm = Ledger.lock!(VirtualMachine, vm.id)
              RelocationCapacity.reserve_locked!(vm, hosts, owner, Ash.UUID.generate())
            end)

          relocation =
            Ledger.update!(relocation, :record_key, %{
              destination_public_key: transfer_endpoint()["host_key"]
            })

          sessions =
            for endpoint <- [source, destination] do
              {:ok, credential} = Credentials.rotate(endpoint.host.id, 3600)

              {:ok, session} =
                ProvisionerControl.open_execution(
                  credential.token,
                  %{session_id: Ash.UUID.generate(), machine_id: endpoint.host.machine_id}
                )

              {credential.token,
               %{session_id: session["session_id"], epoch: session["epoch"], results: []}}
            end

          [{source_token, source_message}, {target_token, target_message}] = sessions

          {:ok, %{"commands" => [wire]}} =
            RelocationSources.exchange(source_token, source_message)

          {:ok, command} = OverallsProtocol.RelocationSource.command(wire)

          result = %{
            id: command.id,
            descriptor:
              Map.put(command.intent, :stream, %{
                source_dataset_guid: "100",
                to_guid: "200"
              })
          }

          {:ok, _} =
            RelocationSources.exchange(source_token, %{source_message | results: [result]})

          receipt = Map.put(result, :dataset_guid, "300")

          {:ok, _} =
            RelocationReceives.exchange(target_token, %{target_message | results: [receipt]})

          {:ok, %{"commands" => [_]}} = RelocationImports.exchange(target_token, target_message)

          {:ok, _} =
            RelocationImports.exchange(target_token, %{target_message | results: [receipt]})

          Ledger.update!(destination.host, :report, %{reported_at: Ledger.now()})

          args = %{vm_id: vm.id, kind: :delete, idempotency_key: Ash.UUID.generate()}
          if phase == :before_handoff, do: Marshall.Compute.lifecycle(args, actor: owner)

          if phase == :after_handoff do
            assert {:ok, :committed} = RelocationCoordinator.advance(relocation.id)
          end

          tasks =
            for n <- 0..11 do
              peer = Enum.at(peers, rem(n, 3))

              Task.async(fn ->
                if rem(n, 2) == 0,
                  do:
                    :peer.call(peer, Marshall.Compute, :lifecycle, [args, [actor: owner]], 30_000),
                  else: :peer.call(peer, RelocationCoordinator, :advance, [relocation.id], 30_000)
              end)
            end

          results = Task.await_many(tasks, 40_000)
          assert Enum.any?(results, &match?({:ok, %Operation{kind: :delete}}, &1))
          assert {:ok, deletion} = Marshall.Compute.lifecycle(args, actor: owner)
          [current] = Ledger.read!(VirtualMachine, id: vm.id)
          [retained] = Ledger.read!(Relocation, id: relocation.id)

          assert retained.deletion_operation_id == deletion.id and
                   retained.deletion_requested_at != nil

          assert current.desired_state == :deleted and current.generation == deletion.generation
          assert current.current_placement_id == deletion.placement_id
          assert current.execution_epoch == deletion.execution_epoch

          assert [^deletion] =
                   Ledger.read!(Operation,
                     vm_id: vm.id,
                     requested_by_id: owner.id,
                     request_key: args.idempotency_key
                   )

          assert {:ok, :deleting} = RelocationCoordinator.advance(relocation.id)
          assert [] == Ledger.read!(Operation, relocation_id: relocation.id, kind: :start)

          if retained.committed_at do
            assert retained.cancellation_requested_at == nil
            assert current.current_placement_id == relocation.destination_placement_id

            assert [%{status: :cancelled}] =
                     Ledger.read!(Operation, id: retained.activation_operation_id)
          else
            assert retained.cancellation_requested_at != nil
            assert retained.activation_operation_id == nil
            assert current.current_placement_id == relocation.source_placement_id
          end

          assert Enum.all?(Ledger.read!(Reservation, vm_id: vm.id), & &1.disk_held)
          assert [_] = Ledger.read!(Marshall.Compute.NetworkAddress, vm_id: vm.id)
        after
          cleanup_relocation_fixture(vm, destination.host.id)
          cleanup(source.host.id, owner.id)
          cleanup(destination.host.id, owner.id)
        end
      end)
    end
  end

  test "three Marshall nodes race handoff, cleanup receipts and source retirement", %{
    peers: peers
  } do
    unboxed(fn ->
      alias Marshall.Compute.{
        Host,
        Relocation,
        RelocationCapacity,
        RelocationCoordinator,
        RelocationImports,
        RelocationReceives,
        RelocationSources,
        Credentials,
        ProvisionerControl
      }

      source = host_fixture()
      owner = user()
      {:ok, vm} = Marshall.Compute.provision(request(), actor: owner)
      destination = host_fixture()

      Cleanup.protect peers do
        [initial] = Ledger.read!(Operation, vm_id: vm.id)
        Ledger.update!(initial, :complete, %{})
        vm = Ledger.intent!(vm, %{desired_state: :stopped})
        vm = Ledger.update!(vm, :observe, %{observed_state: :stopped})
        [hold] = Ledger.read!(Reservation, placement_id: vm.current_placement_id)
        Ledger.update!(hold, :release_compute, %{})

        {:ok, relocation} =
          Ledger.transaction(fn ->
            hosts =
              Host
              |> Ledger.read!()
              |> Enum.sort_by(& &1.id)
              |> Enum.map(&Ledger.lock!(Host, &1.id))

            vm = Ledger.lock!(VirtualMachine, vm.id)
            RelocationCapacity.reserve_locked!(vm, hosts, owner, Ash.UUID.generate())
          end)

        relocation =
          Ledger.update!(relocation, :record_key, %{
            destination_public_key: transfer_endpoint()["host_key"]
          })

        sessions =
          for endpoint <- [source, destination] do
            {:ok, credential} = Credentials.rotate(endpoint.host.id, 3600)

            {:ok, session} =
              ProvisionerControl.open_execution(
                credential.token,
                %{session_id: Ash.UUID.generate(), machine_id: endpoint.host.machine_id}
              )

            {credential.token,
             %{session_id: session["session_id"], epoch: session["epoch"], results: []}}
          end

        [{source_token, source_message}, {target_token, target_message}] = sessions
        {:ok, %{"commands" => [wire]}} = RelocationSources.exchange(source_token, source_message)
        {:ok, command} = OverallsProtocol.RelocationSource.command(wire)

        result = %{
          id: command.id,
          descriptor:
            Map.put(command.intent, :stream, %{
              source_dataset_guid: "100",
              to_guid: "200"
            })
        }

        {:ok, _} = RelocationSources.exchange(source_token, %{source_message | results: [result]})
        receipt = Map.put(result, :dataset_guid, "300")

        {:ok, _} =
          RelocationReceives.exchange(target_token, %{target_message | results: [receipt]})

        {:ok, %{"commands" => [_]}} = RelocationImports.exchange(target_token, target_message)

        {:ok, _} =
          RelocationImports.exchange(target_token, %{target_message | results: [receipt]})

        Ledger.update!(destination.host, :report, %{reported_at: Ledger.now()})

        results =
          for n <- 0..8 do
            peer = Enum.at(peers, rem(n, 3))

            Task.async(fn ->
              :peer.call(peer, RelocationCoordinator, :advance, [relocation.id], 30_000)
            end)
          end
          |> Task.await_many(40_000)

        assert Enum.all?(results, &(&1 == {:ok, :committed}))
        [current] = Ledger.read!(VirtualMachine, id: vm.id)
        [committed] = Ledger.read!(Relocation, id: relocation.id)
        assert current.execution_epoch == 2 and current.generation == vm.generation + 1
        assert current.current_placement_id == relocation.destination_placement_id
        assert current.desired_state == :stopped

        assert [%{id: activation_id, kind: :stop}] =
                 Ledger.read!(Operation, relocation_id: relocation.id)

        assert committed.activation_operation_id == activation_id

        %{rows: [[1]]} =
          Ecto.Adapters.SQL.query!(
            Repo,
            "SELECT count(*) FROM oban_jobs WHERE args->'primary_key'->>'id' = $1",
            [activation_id]
          )

        assert Enum.all?(
                 Ledger.read!(Reservation, vm_id: vm.id),
                 &(&1.disk_held and not &1.compute_held)
               )

        physical = %{
          id: Ash.UUID.generate(),
          vm_id: vm.id,
          placement_id: current.current_placement_id,
          execution_epoch: current.execution_epoch,
          generation: current.generation,
          operation_id: activation_id,
          sequence: 1,
          state: :stopped,
          compute_empty: true,
          disk_present: true,
          cleanup_complete: false,
          reason: :none
        }

        target_execution =
          Map.merge(target_message, %{report: nil, acknowledgements: [], outcomes: [physical]})

        assert {:ok, _} = ProvisionerControl.exchange_execution(target_token, target_execution)
        [activated_vm] = Ledger.read!(VirtualMachine, id: vm.id)

        assert Enum.all?(
                 relocation_calls(peers, RelocationCoordinator, :advance, [relocation.id]),
                 &(&1 == {:ok, :committed})
               )

        assert [_] = Ledger.read!(Marshall.Compute.CleanupRequest, id: relocation.id)

        assert {:ok, %{"commands" => [cleanup_wire]}} =
                 Marshall.Compute.RelocationCleanup.exchange(source_token, source_message)

        {:ok, cleanup_command} = OverallsProtocol.RelocationCleanup.command(cleanup_wire)
        cleanup_result = Map.drop(cleanup_command, [:expires_at])

        receipts =
          relocation_calls(peers, Marshall.Compute.RelocationCleanup, :exchange, [
            source_token,
            %{source_message | results: [cleanup_result]}
          ])

        assert Enum.all?(receipts, &match?({:ok, %{"acknowledgements" => [_]}}, &1))

        assert Enum.all?(
                 relocation_calls(peers, RelocationCoordinator, :advance, [relocation.id]),
                 &(&1 == {:ok, :committed})
               )

        assert [deletion] = Ledger.read!(Operation, relocation_id: relocation.id, kind: :delete)

        source_execution =
          Map.merge(source_message, %{report: nil, acknowledgements: [], outcomes: []})

        assert {:ok, %{"commands" => [_]}} =
                 ProvisionerControl.exchange_execution(source_token, source_execution)

        removed = %{
          physical
          | id: Ash.UUID.generate(),
            placement_id: relocation.source_placement_id,
            execution_epoch: relocation.source_epoch,
            generation: deletion.generation,
            operation_id: deletion.id,
            state: :deleted,
            disk_present: false,
            cleanup_complete: true
        }

        assert {:ok, _} =
                 ProvisionerControl.exchange_execution(source_token, %{
                   source_execution
                   | outcomes: [removed]
                 })

        assert Enum.all?(
                 relocation_calls(peers, RelocationCoordinator, :advance, [relocation.id]),
                 &(&1 == {:ok, :committed})
               )

        assert [%{finished_at: nil}] = Ledger.read!(Relocation, id: relocation.id)

        assert [%{disk_held: true}] =
                 Ledger.read!(Reservation, placement_id: relocation.source_placement_id)

        assert {:ok, %{"commands" => [retirement_wire]}} =
                 Marshall.Compute.RelocationKeyRetirement.exchange(target_token, target_message)

        {:ok, retirement} = OverallsProtocol.RelocationKeyRetirement.command(retirement_wire)
        retired = Map.take(retirement, [:id, :placement_id, :execution_epoch])

        receipts =
          relocation_calls(peers, Marshall.Compute.RelocationKeyRetirement, :exchange, [
            target_token,
            %{target_message | results: [retired]}
          ])

        assert Enum.all?(receipts, &match?({:ok, %{"acknowledgements" => [_]}}, &1))

        assert Enum.all?(
                 relocation_calls(peers, RelocationCoordinator, :advance, [relocation.id]),
                 &(&1 in [{:ok, :committed}, {:ok, :finished}])
               )

        assert [%{disk_held: false, compute_held: false, temporary_disk_bytes: 0}] =
                 Ledger.read!(Reservation, placement_id: relocation.source_placement_id)

        assert [%{disk_held: true}] =
                 Ledger.read!(Reservation, placement_id: relocation.destination_placement_id)

        assert [^activated_vm] = Ledger.read!(VirtualMachine, id: vm.id)
        assert [%{finished_at: finished}] = Ledger.read!(Relocation, id: relocation.id)
        assert finished != nil
      after
        cleanup_relocation_fixture(vm, destination.host.id)
        cleanup(source.host.id, owner.id)
        cleanup(destination.host.id, owner.id)
      end
    end)
  end

  @tag relocation_revocation_race: true
  test "public relocation rechecks a manager revoked while waiting for host locks", %{
    peers: [peer | _]
  } do
    unboxed(fn ->
      source = host_fixture()
      owner = user()
      manager = user()
      {:ok, vm} = Marshall.Compute.provision(request(), actor: owner)
      [initial] = Ledger.read!(Operation, vm_id: vm.id)
      Ledger.update!(initial, :complete, %{})
      vm = Ledger.update!(vm, :observe, %{observed_state: :running})
      destination = host_fixture()

      grant = %{
        vm_id: vm.id,
        email: to_string(manager.email),
        role: :manager,
        idempotency_key: Ash.UUID.generate()
      }

      Cleanup.protect [peer] do
        assert {:ok, _} = Marshall.Access.set_access(grant, actor: owner)

        assert {:ok, task} =
                 Ledger.transaction(fn ->
                   Ledger.lock!(Marshall.Compute.Host, source.host.id)

                   %{rows: [[backend]]} =
                     Ecto.Adapters.SQL.query!(Repo, "SELECT pg_backend_pid()", [], log: false)

                   task =
                     Task.async(fn ->
                       :peer.call(
                         peer,
                         Marshall.Compute,
                         :relocate,
                         [
                           %{vm_id: vm.id, idempotency_key: Ash.UUID.generate()},
                           [actor: manager]
                         ],
                         30_000
                       )
                     end)

                   # The remote action has completed its first authorization check and is
                   # blocked on our host row, before it can acquire the VM lock.
                   wait_for_retained_vm_lock(backend, System.monotonic_time(:millisecond) + 5000)

                   assert {:ok, _} =
                            Marshall.Access.set_access(
                              %{grant | role: :revoked, idempotency_key: Ash.UUID.generate()},
                              actor: owner
                            )

                   task
                 end)

        assert {:error, error} = Task.await(task, 30_000)
        assert Exception.message(error) =~ "forbidden"
        assert Ledger.read!(Marshall.Compute.Relocation, vm_id: vm.id) == []
        assert length(Ledger.read!(Marshall.Compute.WorkloadPlacement, vm_id: vm.id)) == 1
      after
        cleanup_relocation_fixture(vm, destination.host.id)
        cleanup(source.host.id, owner.id)
        cleanup(destination.host.id, owner.id)

        Ecto.Adapters.SQL.query!(Repo, "DELETE FROM users WHERE id = $1", [
          Ecto.UUID.dump!(manager.id)
        ])
      end
    end)
  end

  for same_key <- [true, false] do
    @tag admission_same_key: same_key
    test "three nodes admit one relocation through the public action, same key #{same_key}", c do
      unboxed(fn ->
        source = host_fixture()
        owner = user()
        {:ok, vm} = Marshall.Compute.provision(request(), actor: owner)
        [initial] = Ledger.read!(Operation, vm_id: vm.id)
        Ledger.update!(initial, :complete, %{})
        vm = Ledger.update!(vm, :observe, %{observed_state: :running})
        destination = host_fixture()
        key = Ash.UUID.generate()

        Cleanup.protect c.peers do
          results =
            for n <- 0..8 do
              peer = Enum.at(c.peers, rem(n, 3))

              params = %{
                vm_id: vm.id,
                idempotency_key: if(c.admission_same_key, do: key, else: Ash.UUID.generate())
              }

              Task.async(fn ->
                :peer.call(peer, Marshall.Compute, :relocate, [params, [actor: owner]], 30_000)
              end)
            end
            |> Task.await_many(40_000)

          accepted = for {:ok, relocation} <- results, do: relocation
          assert length(accepted) == if(c.admission_same_key, do: 9, else: 1)
          assert length(Enum.uniq_by(accepted, & &1.id)) == 1
          assert [_] = Ledger.read!(Marshall.Compute.Relocation, vm_id: vm.id)
          assert length(Ledger.read!(Marshall.Compute.WorkloadPlacement, vm_id: vm.id)) == 2
          assert length(Ledger.read!(Reservation, vm_id: vm.id)) == 2
          relocation = hd(accepted)

          assert [_] =
                   Ledger.read!(Marshall.Compute.TransferSlot,
                     source_relocation_id: relocation.id
                   )

          assert [_] =
                   Ledger.read!(Marshall.Compute.TransferSlot,
                     destination_relocation_id: relocation.id
                   )

          %{rows: [[count]]} =
            Ecto.Adapters.SQL.query!(
              Repo,
              "SELECT count(*) FROM oban_jobs WHERE args->'primary_key'->>'id' = $1",
              [relocation.id]
            )

          assert count == 2
          [retained] = Ledger.read!(VirtualMachine, id: vm.id)

          assert retained.current_placement_id == vm.current_placement_id and
                   retained.generation == vm.generation

          assert Enum.all?(results, fn
                   {:ok, _} -> true
                   {:error, error} -> Exception.message(error) =~ "relocation_in_progress"
                 end)
        after
          cleanup_relocation_fixture(vm, destination.host.id)
          cleanup(source.host.id, owner.id)
          cleanup(destination.host.id, owner.id)
        end
      end)
    end
  end

  for same_key <- [true, false] do
    @tag relocation_retry_race: true
    test "three nodes refuse cold retry of an uncertain memory restore, same key #{same_key}", %{
      peers: peers
    } do
      unboxed(fn ->
        alias Marshall.Compute.{Relocation, RelocationCoordinator, RelocationRetry}
        source = host_fixture()
        owner = user()
        {:ok, vm} = Marshall.Compute.provision(request(), actor: owner)
        destination = host_fixture()

        Cleanup.protect peers do
          activation_state = if(unquote(same_key), do: :failed, else: :unknown)

          {r, _token, _session} =
            failed_relocation_activation(vm, owner, source, destination, activation_state)

          key = Ash.UUID.generate()
          operations = Enum.sort_by(Ledger.read!(Operation, vm_id: vm.id), & &1.id)
          reservations = Enum.sort_by(Ledger.read!(Reservation, vm_id: vm.id), & &1.id)
          [before_vm] = Ledger.read!(VirtualMachine, id: vm.id)
          [before_relocation] = Ledger.read!(Relocation, id: r.id)
          [activation] = Ledger.read!(Operation, id: r.activation_operation_id)
          assert activation.kind == :resume
          assert activation.command_snapshot["checkpoint"] == before_vm.current_checkpoint

          results =
            for n <- 0..8 do
              params = %{
                relocation_id: r.id,
                idempotency_key: if(unquote(same_key), do: key, else: Ash.UUID.generate())
              }

              peer = Enum.at(peers, rem(n, 3))

              Task.async(fn ->
                :peer.call(
                  peer,
                  Marshall.Compute,
                  :retry_relocation,
                  [params, [actor: owner]],
                  30_000
                )
              end)
            end
            |> Task.await_many(40_000)

          assert Enum.all?(results, fn
                   {:error, error} -> Exception.message(error) =~ "relocation_retry_unavailable"
                   _ -> false
                 end)

          assert [] == Ledger.read!(RelocationRetry, relocation_id: r.id)
          assert operations == Enum.sort_by(Ledger.read!(Operation, vm_id: vm.id), & &1.id)
          assert reservations == Enum.sort_by(Ledger.read!(Reservation, vm_id: vm.id), & &1.id)
          assert [before_vm] == Ledger.read!(VirtualMachine, id: vm.id)
          assert [before_relocation] == Ledger.read!(Relocation, id: r.id)
          assert [] == Ledger.read!(Marshall.Compute.CleanupRequest, id: r.id)

          assert Enum.all?(
                   relocation_calls(peers, RelocationCoordinator, :advance, [r.id]),
                   &(&1 == {:ok, :committed})
                 )

          assert operations == Enum.sort_by(Ledger.read!(Operation, vm_id: vm.id), & &1.id)
          assert reservations == Enum.sort_by(Ledger.read!(Reservation, vm_id: vm.id), & &1.id)

          if unquote(same_key) do
            [current] = Ledger.read!(VirtualMachine, id: vm.id)
            assert current == before_vm
            assert current.current_checkpoint != nil
          else
            [deleting | coordinators] = peers

            tasks = [
              Task.async(fn ->
                :peer.call(
                  deleting,
                  Marshall.Compute,
                  :lifecycle,
                  [
                    %{vm_id: vm.id, kind: :delete, idempotency_key: Ash.UUID.generate()},
                    [actor: owner]
                  ],
                  30_000
                )
              end)
              | Enum.map(coordinators, fn peer ->
                  Task.async(fn ->
                    :peer.call(peer, RelocationCoordinator, :advance, [r.id], 30_000)
                  end)
                end)
            ]

            assert [{:ok, _} | _] = Task.await_many(tasks, 40_000)
            assert [] == Ledger.read!(RelocationRetry, relocation_id: r.id)
            [deleted] = Ledger.read!(Relocation, id: r.id)
            assert deleted.deletion_requested_at != nil
            [delete] = Ledger.read!(Operation, vm_id: vm.id, kind: :delete)
            assert delete.placement_id == r.destination_placement_id
            assert delete.execution_epoch == r.destination_epoch
            assert delete.generation == r.activation_generation + 1
          end

          assert [] == Ledger.read!(Operation, relocation_id: r.id, kind: :start)
          [current] = Ledger.read!(VirtualMachine, id: vm.id)
          assert current.current_placement_id == r.destination_placement_id
          assert current.execution_epoch == r.destination_epoch
          assert Enum.all?(Ledger.read!(Reservation, vm_id: vm.id), & &1.disk_held)
        after
          cleanup_relocation_fixture(vm, destination.host.id)
          cleanup(destination.host.id, owner.id)
          cleanup(source.host.id, owner.id)
        end
      end)
    end
  end

  # @cc [owner:ghuntley,label:verification] retry-race-reaches-committed-authority
  # The retry refusal race MUST reach handoff through real control exchanges and
  # the coordinator, including probe, source pause evidence and full-copy receipt.
  # Synthetic physical receipts establish application test state only, not native
  # execution acceptance. Retry calls themselves MUST run on three independent peers.
  defp failed_relocation_activation(vm, owner, source, destination, activation_state) do
    alias Marshall.Compute.{
      Credentials,
      ProvisionerControl,
      Relocation,
      RelocationCoordinator,
      RelocationImports,
      RelocationReceives,
      RelocationSources
    }

    [initial] = Ledger.read!(Operation, vm_id: vm.id)
    Ledger.update!(initial, :complete, %{})
    Ledger.update!(vm, :observe, %{observed_state: :running})

    {:ok, r} =
      Marshall.Compute.relocate(%{vm_id: vm.id, idempotency_key: Ash.UUID.generate()},
        actor: owner
      )

    Ledger.update!(r, :record_key, %{destination_public_key: transfer_endpoint()["host_key"]})

    [{source_token, source_session}, {target_token, target_session}] =
      for endpoint <- [source, destination] do
        {:ok, credential} = Credentials.rotate(endpoint.host.id, 3600)

        {:ok, session} =
          ProvisionerControl.open_execution(
            credential.token,
            %{session_id: Ash.UUID.generate(), machine_id: endpoint.host.machine_id}
          )

        {credential.token,
         %{session_id: session["session_id"], epoch: session["epoch"], results: []}}
      end

    # ADR-0199: connectivity proof, then physical pause, then one coherent copy.
    [prepared] = Ledger.read!(Relocation, id: r.id)
    [running] = Ledger.read!(VirtualMachine, id: vm.id)
    Marshall.RelocationProbeFixture.applied!(prepared, running)

    for endpoint <- [source, destination],
        do: Ledger.update!(endpoint.host, :report, %{reported_at: Ledger.now()})

    assert {:ok, :stopping} = RelocationCoordinator.advance(r.id)
    [stopping] = Ledger.read!(Relocation, id: r.id)
    [stop] = Ledger.read!(Operation, id: stopping.source_stop_operation_id)
    assert stop.kind == :pause
    relocation_execution_receipt(source_token, source_session, vm.id, stop, :paused)

    {:ok, %{"commands" => [wire]}} = RelocationSources.exchange(source_token, source_session)
    {:ok, command} = OverallsProtocol.RelocationSource.command(wire)

    result = %{
      id: command.id,
      descriptor: Map.put(command.intent, :stream, %{source_dataset_guid: "100", to_guid: "201"})
    }

    {:ok, _} = RelocationSources.exchange(source_token, %{source_session | results: [result]})
    receipt = Map.put(result, :dataset_guid, "300")
    {:ok, _} = RelocationReceives.exchange(target_token, %{target_session | results: [receipt]})

    for endpoint <- [source, destination],
        do: Ledger.update!(endpoint.host, :report, %{reported_at: Ledger.now()})

    {:ok, %{"commands" => [_]}} = RelocationImports.exchange(target_token, target_session)
    {:ok, _} = RelocationImports.exchange(target_token, %{target_session | results: [receipt]})
    assert {:ok, :committed} = RelocationCoordinator.advance(r.id)

    [committed] = Ledger.read!(Relocation, id: r.id)
    [activation] = Ledger.read!(Operation, id: committed.activation_operation_id)

    relocation_execution_receipt(
      target_token,
      target_session,
      vm.id,
      activation,
      activation_state
    )

    assert [] == Ledger.read!(Marshall.Compute.ReadinessRequest, id: activation.id)

    assert {:ok, %{relocation: %{retryable: false, phase: :activation_failed}}} =
             Marshall.Compute.get_vm(%{vm_id: vm.id}, actor: owner)

    {committed, target_token, target_session}
  end

  @spec relocation_execution_receipt(
          String.t(),
          map(),
          String.t(),
          Operation.t(),
          :paused | :stopped | :running | :failed | :unknown
        ) :: term()
  defp relocation_execution_receipt(token, session, vm_id, operation, state) do
    [current] = Ledger.read!(VirtualMachine, id: vm_id)

    outcome = %{
      id: Ash.UUID.generate(),
      vm_id: vm_id,
      placement_id: operation.placement_id,
      execution_epoch: operation.execution_epoch,
      generation: operation.generation,
      operation_id: operation.id,
      sequence: current.outcome_sequence + 1,
      state: state,
      compute_empty: state in [:paused, :stopped, :failed],
      disk_present: true,
      cleanup_complete: false,
      reason:
        if(state == :failed,
          do: :execution_failed,
          else: if(state == :unknown, do: :unknown, else: :none)
        )
    }

    outcome =
      if state in [:paused, :running],
        do: Map.put(outcome, :checkpoint, relocation_checkpoint(current)),
        else: outcome

    assert {:ok, _} =
             Marshall.Compute.ProvisionerControl.exchange_execution(
               token,
               Map.merge(session, %{report: nil, acknowledgements: [], outcomes: [outcome]})
             )
  end

  @spec relocation_checkpoint(VirtualMachine.t()) :: OverallsProtocol.Checkpoint.t()
  defp relocation_checkpoint(vm) do
    %{
      id: "11111111-1111-4111-8111-111111111111",
      memory_bytes: vm.memory_bytes,
      state_bytes: 4096,
      compatibility: "sha256:" <> String.duplicate("a", 64),
      memory_sha256: "sha256:" <> String.duplicate("b", 64),
      state_sha256: "sha256:" <> String.duplicate("c", 64),
      manifest_sha256: "sha256:" <> String.duplicate("d", 64),
      dataset_guid: "81",
      snapshot_guid: "82"
    }
  end

  defp relocation_calls(peers, module, function, arguments) do
    for n <- 0..8 do
      peer = Enum.at(peers, rem(n, 3))
      Task.async(fn -> :peer.call(peer, module, function, arguments, 30_000) end)
    end
    |> Task.await_many(40_000)
  end

  defp cleanup_relocation_fixture(vm, destination) do
    # Break this fixture's cyclic evidence links only during committed test teardown.
    # Production cancellation must retain these records and perform physical cleanup.
    {:ok, _} =
      Repo.transaction(fn ->
        vm_id = Ecto.UUID.dump!(vm.id)
        Cleanup.relocation_history!(vm.id)

        Cleanup.jobs!(
          """
          args->'primary_key'->>'id' IN (
            SELECT id::text FROM compute_operations WHERE vm_id = $1 UNION ALL
            SELECT id::text FROM compute_relocations WHERE vm_id = $1 UNION ALL
            SELECT id::text FROM compute_source_permit_requests WHERE relocation_id IN
              (SELECT id FROM compute_relocations WHERE vm_id = $1) UNION ALL
            SELECT id::text FROM compute_probe_requests WHERE relocation_id IN
              (SELECT id FROM compute_relocations WHERE vm_id = $1))
          """,
          [vm_id]
        )

        Ecto.Adapters.SQL.query!(
          Repo,
          """
          UPDATE compute_relocations SET committed_at = NULL, import_request_id = NULL,
            activation_operation_id = NULL, activation_generation = NULL,
            source_stop_operation_id = NULL, source_stop_generation = NULL, source_preflight_request_id = NULL,
            cancellation_stop_operation_id = NULL, cancellation_stop_generation = NULL,
            cancellation_start_operation_id = NULL, cancellation_start_generation = NULL,
            source_restored_at = NULL, source_snapshot_cleanup_offered_at = NULL,
            source_snapshots_cleaned_at = NULL, deletion_requested_at = NULL,
            deletion_operation_id = NULL WHERE vm_id = $1
          """,
          [vm_id]
        )

        for sql <- [
              "DELETE FROM compute_relocation_retries WHERE vm_id = $1",
              "DELETE FROM compute_cleanup_requests WHERE id IN (SELECT id FROM compute_relocations WHERE vm_id = $1)",
              "DELETE FROM compute_readiness_requests WHERE vm_id = $1",
              "DELETE FROM compute_physical_outcomes WHERE vm_id = $1",
              "DELETE FROM compute_operations WHERE vm_id = $1",
              "DELETE FROM compute_probe_requests WHERE relocation_id IN (SELECT id FROM compute_relocations WHERE vm_id = $1)",
              "DELETE FROM compute_source_permit_requests WHERE relocation_id IN (SELECT id FROM compute_relocations WHERE vm_id = $1)",
              "DELETE FROM compute_transfer_slots WHERE source_relocation_id IN (SELECT id FROM compute_relocations WHERE vm_id = $1) OR destination_relocation_id IN (SELECT id FROM compute_relocations WHERE vm_id = $1)",
              "DELETE FROM compute_relocations WHERE vm_id = $1"
            ],
            do: Ecto.Adapters.SQL.query!(Repo, sql, [vm_id])

        Ecto.Adapters.SQL.query!(
          Repo,
          "UPDATE compute_virtual_machines SET current_placement_id = $2 WHERE id = $1",
          [vm_id, Ecto.UUID.dump!(vm.current_placement_id)]
        )

        for table <- ["compute_reservations", "compute_workload_placements"],
            do:
              Ecto.Adapters.SQL.query!(
                Repo,
                "DELETE FROM #{table} WHERE vm_id = $1 AND host_id = $2",
                [vm_id, Ecto.UUID.dump!(destination)]
              )
      end)
  end

  defp reject_maintenance_jobs do
    Ecto.Adapters.SQL.query!(Repo, """
    CREATE OR REPLACE FUNCTION pg_temp.reject_maintenance_job() RETURNS trigger LANGUAGE plpgsql AS
    $$ BEGIN RAISE EXCEPTION 'injected maintenance job failure'; END $$
    """)

    Ecto.Adapters.SQL.query!(Repo, """
    CREATE TRIGGER reject_maintenance_job BEFORE INSERT ON oban_jobs
    FOR EACH ROW WHEN (NEW.queue = 'maintenance') EXECUTE FUNCTION pg_temp.reject_maintenance_job()
    """)
  end

  test "three nodes serialize resize retries and competing lifecycle intent", %{peers: peers} do
    unboxed(fn ->
      fixture = host_fixture()
      actor = user()
      {:ok, vm} = Marshall.Compute.provision(request(), actor: actor)
      [initial] = Ledger.read!(Operation, vm_id: vm.id)

      event = %{
        id: Ash.UUID.generate(),
        vm_id: vm.id,
        placement_id: vm.current_placement_id,
        execution_epoch: vm.execution_epoch,
        operation_id: initial.id,
        generation: vm.generation,
        sequence: 1,
        state: :running,
        compute_empty: false,
        disk_present: true,
        cleanup_complete: false,
        reason: :none
      }

      {:ok, _} =
        Ledger.transaction(fn ->
          Ledger.lock!(Marshall.Compute.Host, fixture.host.id)
          Marshall.Compute.Outcomes.ingest_locked!(fixture.host.id, [event])
        end)

      args = %{
        vm_id: vm.id,
        expected_generation: 1,
        idempotency_key: Ash.UUID.generate(),
        vcpu: 1,
        memory_bytes: vm.memory_bytes,
        disk_bytes: vm.disk_bytes + 1_073_741_824
      }

      Cleanup.protect peers do
        results =
          for n <- 0..8 do
            peer = Enum.at(peers, rem(n, 3))

            Task.async(fn ->
              :peer.call(peer, Marshall.Compute, :resize, [args, [actor: actor]], 30_000)
            end)
          end
          |> Task.await_many(40_000)

        assert Enum.all?(results, &match?({:ok, _}, &1))
        assert length(Enum.uniq(Enum.map(results, fn {:ok, r} -> r.id end))) == 1
        assert [%{generation: 2}] = Ledger.read!(VirtualMachine, id: vm.id)
        assert length(Ledger.read!(Operation, vm_id: vm.id)) == 2

        competing =
          for {peer, index} <- Enum.with_index(peers) do
            Task.async(fn ->
              :peer.call(
                peer,
                Marshall.Compute,
                :lifecycle,
                [%{vm_id: vm.id, kind: :stop, idempotency_key: "race-#{index}"}, [actor: actor]],
                30_000
              )
            end)
          end
          |> Task.await_many(40_000)

        assert Enum.all?(competing, &match?({:error, _}, &1))

        assert [%{pending_disk_bytes: 1_073_741_824, startup_compute_held: true}] =
                 Ledger.read!(Reservation, vm_id: vm.id)
      after
        cleanup(fixture.host.id, actor.id)
      end
    end)
  end

  test "three nodes race resize, fresh admission and stop under one host budget", %{peers: peers} do
    unboxed(fn ->
      fixture = host_fixture()
      actor = user()

      Cleanup.protect peers do
        {:ok, vm} = Marshall.Compute.provision(request(), actor: actor)
        [initial] = Ledger.read!(Operation, vm_id: vm.id)

        {:ok, _} =
          Ledger.transaction(fn ->
            Ledger.lock!(Marshall.Compute.Host, fixture.host.id)

            Marshall.Compute.Outcomes.ingest_locked!(fixture.host.id, [
              %{
                id: Ash.UUID.generate(),
                vm_id: vm.id,
                placement_id: vm.current_placement_id,
                execution_epoch: vm.execution_epoch,
                operation_id: initial.id,
                generation: vm.generation,
                sequence: 1,
                state: :running,
                compute_empty: false,
                disk_present: true,
                cleanup_complete: false,
                reason: :none
              }
            ])
          end)

        actions = [
          {:resize,
           %{
             vm_id: vm.id,
             expected_generation: 1,
             idempotency_key: Ash.UUID.generate(),
             vcpu: 3,
             memory_bytes: vm.memory_bytes,
             disk_bytes: vm.disk_bytes + 1_073_741_824
           }},
          {:provision, request()},
          {:lifecycle, %{vm_id: vm.id, kind: :stop, idempotency_key: Ash.UUID.generate()}}
        ]

        results =
          Enum.zip(peers, actions)
          |> Enum.map(fn {peer, {action, args}} ->
            Task.async(fn ->
              :peer.call(peer, Marshall.Compute, action, [args, [actor: actor]], 30_000)
            end)
          end)
          |> Task.await_many(40_000)

        [resize, admission, stop] = results

        if match?({:ok, _}, resize) do
          assert {:error, _} = admission
          assert {:error, _} = stop
        else
          assert {:ok, _} = stop
          assert {:ok, _} = admission
        end

        held =
          Ledger.read!(Reservation, host_id: fixture.host.id)
          |> Enum.filter(&(&1.compute_held and &1.startup_compute_held))

        assert Enum.sum(Enum.map(held, & &1.vcpu)) <= 4

        assert length(Ledger.read!(Operation, requested_by_id: actor.id)) ==
                 1 + Enum.count(results, &match?({:ok, _}, &1))

        [current] = Ledger.read!(VirtualMachine, id: vm.id)
        assert current.current_placement_id == vm.current_placement_id
        assert current.vcpu == vm.vcpu
      after
        cleanup(fixture.host.id, actor.id)
      end
    end)
  end

  test "three nodes serialize distinct clone admissions and identical retries", %{peers: peers} do
    unboxed(fn ->
      fixture = host_fixture()
      actor = user()
      {:ok, vm} = Marshall.Compute.provision(request(), actor: actor)

      Cleanup.protect peers do
        keys = Enum.map(1..9, fn _ -> Ash.UUID.generate() end)

        results =
          (keys ++ List.duplicate(hd(keys), 6))
          |> Enum.with_index()
          |> Enum.map(fn {key, index} ->
            Task.async(fn ->
              :peer.call(
                Enum.at(peers, rem(index, 3)),
                Marshall.Compute,
                :clone,
                [%{vm_id: vm.id, idempotency_key: key}, [actor: actor]],
                30_000
              )
            end)
          end)
          |> Task.await_many(40_000)

        assert Enum.all?(results, &match?({:ok, _}, &1))
        requests = Ledger.read!(Marshall.Compute.CloneRequest, source_vm_id: vm.id)
        assert length(requests) == 9
        assert Enum.sort(Enum.map(requests, & &1.sequence)) == Enum.to_list(1..9)
        assert length(Enum.uniq_by(requests, & &1.destination_vm_id)) == 9
        assert Enum.all?(requests, &(&1.phase == :queued and not &1.active))
        replay_ids = [hd(results) | Enum.drop(results, 9)] |> Enum.map(fn {:ok, r} -> r.id end)
        assert length(Enum.uniq(replay_ids)) == 1

        for request <- requests do
          %{rows: [[count]]} =
            Ecto.Adapters.SQL.query!(
              Repo,
              "SELECT count(*) FROM oban_jobs WHERE args->'primary_key'->>'id' = $1",
              [request.id]
            )

          assert count == 1
        end

        assert length(Ledger.read!(VirtualMachine, owner_id: actor.id)) == 1
        assert length(Ledger.read!(Operation, vm_id: vm.id)) == 1
      after
        Cleanup.jobs!(
          "args->'primary_key'->>'id' IN (SELECT id::text FROM compute_clone_requests WHERE source_vm_id = $1)",
          [Ecto.UUID.dump!(vm.id)]
        )

        for statement <- [
              "DELETE FROM compute_clone_requests_versions WHERE version_source_id IN (SELECT id FROM compute_clone_requests WHERE source_vm_id = $1)",
              "DELETE FROM compute_clone_requests WHERE source_vm_id = $1"
            ],
            do: Ecto.Adapters.SQL.query!(Repo, statement, [Ecto.UUID.dump!(vm.id)])

        cleanup(fixture.host.id, actor.id)
      end
    end)
  end

  # @cc [owner:ghuntley,label:verification;recovery] uncertain-admission-owned-origin
  # Whole-node fault histories MUST use an independently started Marshall with
  # its own committed Repo pool. Its controller MUST expose the actual abrupt
  # exit status, and MUST NOT restart or replace the three surviving retry nodes.
  @spec start_owned_admission_peer() :: pid()
  defp start_owned_admission_peer do
    peer =
      start_supervised!(%{
        id: {:uncertain_admission_origin, make_ref()},
        start:
          {:peer, :start_link,
           [
             %{
               name: :marshall_uncertain_origin,
               connection: :standard_io,
               peer_down: :crash,
               args: [~c"+S", ~c"2:2", ~c"+SDcpu", ~c"1", ~c"+SDio", ~c"1"],
               wait_boot: 30_000
             }
           ]},
        restart: :temporary
      })

    :ok = :peer.call(peer, :code, :add_paths, [:code.get_path()])

    config =
      for {app, _, _} <- Application.loaded_applications(),
          app not in [:kernel, :stdlib, :elixir, :logger],
          do: {app, Application.get_all_env(app)}

    :ok = :peer.call(peer, Application, :put_all_env, [config, [persistent: true]])

    repo_config =
      Application.fetch_env!(:marshall, Repo)
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 4)

    :ok =
      :peer.call(peer, Application, :put_env, [:marshall, Repo, repo_config, [persistent: true]])

    :ok = :peer.call(peer, Application, :put_env, [:logger, :level, :error, [persistent: true]])
    {:ok, _} = :peer.call(peer, Application, :ensure_all_started, [:marshall], 30_000)
    connect_admission_observer(peer)
    peer
  end

  # @cc [owner:ghuntley,label:verification] admission-observer-native-distribution
  # Commit observations and remote process monitors MUST use an authenticated
  # native node connection. The coordinator MUST NOT count as a retry peer;
  # fixture cookies MUST remain in memory and MUST NOT enter diagnostics.
  @spec connect_admission_observer(pid()) :: :ok
  defp connect_admission_observer(peer) do
    node = :peer.call(peer, :erlang, :node, [])
    cookie = :peer.call(peer, :erlang, :get_cookie, [])
    true = Node.set_cookie(node, cookie)
    true = Node.connect(node)
    :ok
  end

  defp race(peers, requests, actor) do
    requests
    |> Enum.with_index()
    |> Enum.map(fn {params, index} ->
      peer = Enum.at(peers, rem(index, length(peers)))

      Task.async(fn ->
        :peer.call(peer, Marshall.Compute, :provision, [params, [actor: actor]], 30_000)
      end)
    end)
    |> Task.await_many(40_000)
  end

  defp unboxed(fun), do: Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fun)

  @spec cleanup(String.t(), String.t()) :: {:ok, term()} | {:error, term()}
  defp cleanup(host_id, owner_id),
    do: Marshall.CommittedFixtureCleanup.cleanup_compute(host_id, owner_id)
end
