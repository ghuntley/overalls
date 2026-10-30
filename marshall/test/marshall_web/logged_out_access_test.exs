defmodule MarshallWeb.LoggedOutAccessTest do
  use MarshallWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Marshall.Accounts.User

  @app_nav_hrefs ~w(/overview /git /machines /integrations /teams /usage /settings /admin/users /admin/usage)

  test "the root path sends anonymous visitors through public capture to sign-in", %{conn: conn} do
    assert redirected_to(get(conn, "/")) == "/launch/entry"
    html = html_response(get(conn, "/launch/entry"), 200)
    assert html =~ ~s(data-idle-to="/sign-in")
    refute app_nav_links(html)
  end

  test "the root path sends authenticated users through repository launch", %{conn: conn} do
    assert redirected_to(get(signed_in(conn, user()), "/")) == "/launch/entry"
  end

  test "the sign-in page shows no site or console navigation", %{conn: conn} do
    assert {:ok, _view, html} = live(conn, "/sign-in")

    refute html =~ ~s(class="public-header")
    refute html =~ ~s(id="public-marvin-extension")
    refute html =~ ~s(href="https://github.com/ghuntley/overalls")
    refute html =~ ~s(class="auth-banner")
    assert html =~ "Email me a sign-in link"
    refute html =~ "Request magic link"
    refute app_nav_links(html)
  end

  test "public documentation hides console navigation from anonymous visitors", %{conn: conn} do
    html = html_response(get(conn, "/docs"), 200)

    assert html =~ ~s(href="/docs")
    assert html =~ ~s(href="/docs/browser-extension")
    # The docs sidebar lists only field notes since 42df2df27; sign-in lives
    # in the public console header, not in documentation pages.
    refute html =~ ~s(href="/sign-in")
    assert html =~ "Getting started"
    refute app_nav_links(html)
  end

  defp app_nav_links(html) do
    Enum.any?(@app_nav_hrefs, fn href -> html =~ ~s(href="#{href}") end)
  end

  defp user, do: Ash.Seed.seed!(User, %{email: "#{Ash.UUID.generate()}@example.test"})

  defp signed_in(conn, user) do
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(user)
    user = Ash.Resource.put_metadata(user, :token, token)
    conn |> init_test_session(%{}) |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
