defmodule MarshallWeb.AdminUsersLiveTest do
  use MarshallWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Marshall.Accounts.User
  alias Marshall.Compute.Ledger

  test "administration requires sign-in and permits ordinary accounts", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/admin/users")

    assert {:ok, _, _} = live(signed_in(conn, user(false)), ~p"/admin/users")
  end

  test "administrator manages another account but has no self-demotion control", %{conn: conn} do
    admin = user(true)
    other = user(false)
    {:ok, view, _} = live(signed_in(conn, admin), ~p"/admin/users")
    refute has_element?(view, "#role-#{admin.id}")
    assert has_element?(view, "#role-#{other.id}", "Make administrator")
    view |> element("#role-#{other.id}") |> render_click()
    assert has_element?(view, "#role-#{other.id}", "Remove administrator")
    render_click(view, "set-role", %{"id" => admin.id, "enabled" => "false"})
    assert render(view) =~ "Could not change administrator access"
  end

  test "demotion halts mutation callbacks while retaining read access", %{conn: conn} do
    admin = user(true)
    other = user(false)
    {:ok, view, _} = live(signed_in(conn, admin), ~p"/admin/users")
    Ledger.update!(admin, :assign_administrator, %{administrator: false})
    render_click(view, "set-role", %{"id" => other.id, "enabled" => "true"})
    assert render(view) =~ "Administrative changes require an administrator"

    refute Marshall.Authorization.Cedar.allowed?(
             other,
             "admin_accounts",
             Marshall.Authorization.Cedar.entity("ControlPlane", "marshall")
           )
  end

  test "administrator can revoke another account's browser sessions", %{conn: conn} do
    admin = user(true)
    other = user(false)
    {:ok, view, _} = live(signed_in(conn, admin), ~p"/admin/users")

    render_click(view, "revoke-sessions", %{"id" => other.id})

    assert has_element?(view, "#sessions-#{other.id}")

    assert [%{kind: :sessions_revoke, target_id: id}] =
             Marshall.Compute.Ledger.read!(Marshall.Accounts.AdminEvent, target_id: other.id)

    assert id == other.id
  end

  test "revocation halts a mounted view before its next refresh", %{conn: conn} do
    admin = user(true)
    conn = signed_in(conn, admin)
    {:ok, view, _} = live(conn, ~p"/admin/users")

    :ok =
      AshAuthentication.TokenResource.Actions.revoke(
        Marshall.Accounts.Token,
        get_session(conn, "user_token")
      )

    send(view.pid, :refresh)
    assert_redirect(view, ~p"/sign-in")
  end

  test "deletion progress uses the administrator's active language", %{conn: conn} do
    admin = user(true)
    target = user(false)

    deletion =
      Ash.Seed.seed!(Marshall.Accounts.UserDeletion, %{
        user_id: target.id,
        requested_by_id: admin.id,
        email: target.email
      })

    # Progress counters use :progress; completion goes through the state
    # machine's begin_finalization and complete transitions.
    for {locale, step, source} <- [
          {"ja", {:progress, %{blocked: false}}, "Deleting machines"},
          {"ar", {:progress, %{blocked: true}}, "Retrying machine cleanup"},
          {"ja", :complete, "Deleted"}
        ] do
      case step do
        {:progress, progress} ->
          Ledger.update!(deletion, :progress, progress)

        :complete ->
          [current] = Ledger.read!(Marshall.Accounts.UserDeletion, id: deletion.id)

          current
          |> Ledger.update!(:begin_finalization, %{})
          |> Ledger.update!(:complete, %{completed_at: DateTime.utc_now()})
      end

      {:ok, view, _} =
        conn
        |> signed_in(admin)
        |> put_req_header("accept-language", locale)
        |> live(~p"/admin/users")

      translated =
        Gettext.with_locale(MarshallWeb.Gettext, locale, fn ->
          Gettext.dgettext(MarshallWeb.Gettext, "admin_users", source)
        end)

      refute translated == source
      assert has_element?(view, "#users-#{target.id} p.muted", translated)
    end
  end

  defp user(admin),
    do:
      Ash.Seed.seed!(User, %{email: "#{Ash.UUID.generate()}@example.test", administrator: admin})

  defp signed_in(conn, user) do
    user = if user.administrator, do: Marshall.PasskeyFixture.verified_session(user), else: user

    {:ok, token, _} =
      if user.__metadata__[:token],
        do: {:ok, user.__metadata__.token, %{}},
        else: AshAuthentication.Jwt.token_for_user(user)

    user = Ash.Resource.put_metadata(user, :token, token)
    conn |> init_test_session(%{}) |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
