defmodule MarshallWeb.MFALoginHistoryTest do
  use MarshallWeb.ConnCase, async: false
  import Hegel
  import Hegel.Gen
  import Phoenix.LiveViewTest

  alias Marshall.Accounts.{Login, Security, User, Verification}
  alias Marshall.Compute.Ledger
  alias Marshall.PasskeyFixture, as: Fixture
  # One hundred histories repeatedly mount real LiveViews: each history takes
  # 6-11 s (recorded 2026-10-30 at 8 schedulers; the /admin/users mount alone
  # is about 120 ms), and the full run took 975 s. The aggregate budget keeps
  # load margin above that for an 8-vCPU CI runner; each history retains the
  # default finite SQL ownership timeout.
  @moduletag timeout: 1_800_000

  @typep state :: %{live: boolean(), completed: boolean(), elevated: boolean()}
  @typep operation :: :verify | :uv | :expired | :wrong_session | :expire | :lock | :revoke
  @typep event :: {0 | 1, operation()}

  # @cc [owner:ghuntley,label:verification] subsequent-mfa-login-isolation
  # Histories MUST start with an enrolled account and distinct subsequent logins.
  # Each login's independent model MUST predict browser/export access from its
  # stored login and administrative access from its own passkey proof. Verifying
  # one login MUST NOT elevate another; revoked logins MUST lose mounted reads.

  # @cc [owner:ghuntley,label:verification] subsequent-mfa-history-fixtures
  # Every generated history and replay MUST begin with a fresh SQL sandbox and
  # roll back its users, tokens, passkeys and audit rows before the next history.
  @tag :hegel
  @tag :hegel_case_sandbox
  test "subsequent login histories separate ordinary access from passkey elevation", %{
    conn: conn
  } do
    Hegel.check(
      fn ->
        Marshall.DataCase.isolate_property_case()

        events =
          draw(
            "events",
            list_of(
              tuple(
                {member_of([0, 1]),
                 member_of([:verify, :uv, :expired, :wrong_session, :expire, :lock, :revoke])}
              ),
              max_length: 5
            )
          )

        # Registration plus four fixed ceremonies plus five generated ceremonies
        # fit the independent ten-retained-challenge limit without pruning fixtures.
        assert_history(conn, events)
      end,
      test_cases: 100,
      profile: :ci
    )
  end

  @spec assert_history(Plug.Conn.t(), [event()]) :: :ok
  defp assert_history(conn, events) do
    {enrollment, enrollment_token} = Fixture.login(Fixture.user())
    key = Fixture.register(enrollment)

    :ok =
      AshAuthentication.TokenResource.Actions.revoke(Marshall.Accounts.Token, enrollment_token)

    sessions =
      for _ <- 1..2 do
        {actor, token} = Fixture.login(Security.current(enrollment.id))
        {actor, token, signed_in(conn, actor, token)}
      end

    initial = for _ <- sessions, do: %{live: true, completed: false, elevated: false}
    assert_access(sessions, initial)

    # Every run proves wrong-session refusal then valid use and replay refusal,
    # missing UV and deadline failure on the other still-pending login, successful
    # completion of that login, and completion surviving elevation expiry.
    fixed = [{0, :wrong_session}, {1, :uv}, {1, :expired}, {1, :verify}, {0, :expire}]

    Enum.reduce(fixed ++ events, initial, fn {index, operation}, states ->
      {actor, token, _} = Enum.at(sessions, index)
      {other, _, _} = Enum.at(sessions, 1 - index)
      before = Enum.at(states, index)
      mounted = mount_readers(sessions, states)
      after_event = transition(operation, actor, token, other, key, before)
      states = List.replace_at(states, index, after_event)
      assert_mounted(mounted, states)
      assert_access(sessions, states)
      states
    end)

    :ok
  end

  @spec transition(operation(), User.t(), String.t(), User.t(), map(), state()) :: state()
  defp transition(:revoke, _actor, token, _other, _key, state) do
    :ok = AshAuthentication.TokenResource.Actions.revoke(Marshall.Accounts.Token, token)
    %{state | live: false, elevated: false}
  end

  defp transition(:expire, actor, _token, _other, _key, state) do
    [proof] = Ledger.read!(Verification, id: Security.jti(actor))
    Ledger.update!(proof, :verify, %{elevated_until: Ledger.now()})
    %{state | elevated: false}
  end

  defp transition(:lock, actor, _token, _other, _key, state) do
    result = Fixture.action(actor, :lock)
    assert match?({:ok, %{locked: true}}, result) == state.live
    %{state | elevated: false}
  end

  defp transition(operation, actor, _token, other, key, state) do
    case Fixture.action(actor, :begin_verify) do
      {:ok, challenge} ->
        assert state.live
        payload = Fixture.assertion(challenge, key)

        case operation do
          :wrong_session ->
            assert {:error, _} = Fixture.action(other, :finish_verify, payload)
            assert {:ok, %{verified: true}} = Fixture.action(actor, :finish_verify, payload)
            assert {:error, _} = Fixture.action(actor, :finish_verify, payload)
            %{state | completed: true, elevated: true}

          :verify ->
            assert {:ok, %{verified: true}} = Fixture.action(actor, :finish_verify, payload)
            assert {:error, _} = Fixture.action(actor, :finish_verify, payload)
            %{state | completed: true, elevated: true}

          :uv ->
            assert {:ok, %{error: _}} =
                     Fixture.action(
                       actor,
                       :finish_verify,
                       Fixture.assertion(challenge, key, flags: 1)
                     )

            assert {:error, _} = Fixture.action(actor, :finish_verify, payload)
            state

          :expired ->
            Ecto.Adapters.SQL.query!(
              Marshall.Repo,
              "UPDATE account_passkey_challenges SET expires_at = clock_timestamp() - interval '1 second' WHERE id = $1",
              [Ecto.UUID.dump!(challenge.id)],
              log: false
            )

            assert {:error, _} = Fixture.action(actor, :finish_verify, payload)
            state
        end

      {:error, _} ->
        refute state.live
        state
    end
  end

  @spec mount_readers([{User.t(), String.t(), Plug.Conn.t()}], [state()]) :: [
          Phoenix.LiveViewTest.View.t() | nil
        ]
  defp mount_readers(sessions, states) do
    for {{_, _, conn}, state} <- Enum.zip(sessions, states) do
      if state.live do
        {:ok, view, _} = history_live(conn, "/admin/users")
        view
      end
    end
  end

  @spec assert_mounted([Phoenix.LiveViewTest.View.t() | nil], [state()]) :: :ok
  defp assert_mounted(views, states) do
    for {view, state} <- Enum.zip(views, states), view do
      send(view.pid, :refresh)

      if state.live do
        assert has_element?(view, "#main-content")
        stop_history_view(view.pid)
      else
        assert_redirect(view, "/sign-in")
      end
    end

    :ok
  end

  @spec assert_access([{User.t(), String.t(), Plug.Conn.t()}], [state()]) :: :ok
  defp assert_access(sessions, states) do
    for {{actor, token, conn}, state} <- Enum.zip(sessions, states) do
      allowed = state.live
      assert match?({:ok, _, _}, Login.verify(token, actor)) == allowed

      assert Security.passkey_verified?(Security.jti(actor), actor.id) ==
               state.completed

      assert Security.recent?(actor) == (state.live and state.elevated)
      assert get(conn, "/admin/usage/export").status == if(allowed, do: 200, else: 404)

      for path <- ["/overview", "/admin/users"] do
        if allowed do
          {:ok, view, _} = history_live(conn, path)
          assert has_element?(view, "#main-content")
          stop_history_view(view.pid)
        else
          assert {:error, {:redirect, %{to: "/sign-in"}}} = history_live(conn, path)
        end
      end
    end

    :ok
  end

  # @cc [owner:ghuntley,label:verification] subsequent-mfa-case-view-custody
  # Every successful LiveView mount, including an unexpected success in a refusal
  # assertion, MUST register cleanup before its generated case's SQL owner stops.
  # Cleanup MUST target only the captured PID, tolerate only an already stopped
  # view and retain a finite operation deadline.
  @spec history_live(Plug.Conn.t(), String.t()) ::
          {:ok, %Phoenix.LiveViewTest.View{}, String.t()}
          | {:error, {:redirect | :live_redirect, map()}}
  defp history_live(conn, path) do
    case live(conn, path) do
      {:ok, view, _html} = result ->
        Hegel.on_cleanup(fn -> stop_history_view(view.pid) end)
        result

      {:error, _redirect} = result ->
        result
    end
  end

  @spec stop_history_view(pid()) :: :ok
  defp stop_history_view(pid) do
    GenServer.stop(pid, :normal, 5_000)
  catch
    :exit, {:noproc, _} -> :ok
  end

  @spec signed_in(Plug.Conn.t(), User.t(), String.t()) :: Plug.Conn.t()
  defp signed_in(conn, actor, token) do
    conn
    |> init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(
      Ash.Resource.put_metadata(actor, :token, token)
    )
  end
end
