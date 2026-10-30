defmodule MarshallWeb.IntegrationsLiveTest do
  use MarshallWeb.ConnCase, async: false
  import Hegel
  import Hegel.Gen
  import Phoenix.LiveViewTest
  alias Marshall.Compute.Ledger

  test "built-in GitHub endpoint stays per owner and detachment is reversible", %{conn: conn} do
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    {:ok, view, _} = live(signed_in(conn, fixture.owner), ~p"/integrations")

    assert has_element?(
             view,
             "#github-com-integration",
             "https://com-github.integration.internal"
           )

    assert has_element?(view, "#github-com-state", "Disconnected")
    assert has_element?(view, "#github-com-integration", "owner's GitHub permissions")

    # Re-renders after Detach/Attach must not close the panel the owner opened.
    assert view |> element("#github-com-machines") |> render() =~ "ignore_attrs"

    view |> form("#github-com-detach", github_machine: %{vm_id: fixture.vm.id}) |> render_submit()
    assert has_element?(view, "#github-com-excluded-#{fixture.vm.id}")
    view |> element("#github-com-excluded-#{fixture.vm.id} button") |> render_click()
    refute has_element?(view, "#github-com-excluded-#{fixture.vm.id}")

    other = Marshall.ComputeFixtures.user()
    {:ok, other_view, _} = live(signed_in(build_conn(), other), ~p"/integrations")

    html =
      other_view
      |> form("#github-com-detach", github_machine: %{vm_id: fixture.vm.id})
      |> render_submit()

    assert html =~ "Could not update the GitHub connection."
    refute has_element?(other_view, "#github-com-excluded-#{fixture.vm.id}")
  end

  @tag :hegel
  test "invalid submissions preserve the connected view and show redacted refusal", %{
    conn: conn
  } do
    owner = Marshall.ComputeFixtures.user()
    {:ok, view, _} = live(signed_in(conn, owner), ~p"/integrations")

    Hegel.check(
      fn ->
        suffix = draw("suffix", string(:alphanumeric, min_length: 1, max_length: 12))
        previous_password_ids = password_ids(view)

        html =
          view
          |> form("#integration-form",
            integration: %{
              name: "browser-invalid",
              target: "http://#{suffix}.example.test",
              bearer: "private-browser-secret"
            }
          )
          |> render_submit()

        assert html =~ "Could not save this integration."
        refute html =~ "private-browser-secret"
        assert has_element?(view, "#integration-form input[name='integration[bearer]'][value='']")
        assert MapSet.disjoint?(MapSet.new(previous_password_ids), MapSet.new(password_ids(view)))
        assert Ledger.read!(Marshall.Galileo.Integration, name: "browser-invalid") == []
      end,
      test_cases: 100
    )
  end

  test "integration UI configures peer/team fields and manages redacted attachments", %{
    conn: conn
  } do
    owner = Marshall.ComputeFixtures.user()
    vm = Marshall.TerminalFixtures.terminal_fixture().vm
    {:ok, view, _} = live(signed_in(conn, owner), ~p"/integrations")

    assert has_element?(view, "#integration-form")

    assert has_element?(
             view,
             "#integration-form input[name='integration[name]'][placeholder='example-integration']"
           )

    assert has_element?(view, "#integration_peer_vm_id")
    assert has_element?(view, "#integration_team_id")

    secret = "browser-only-secret"
    previous_password_ids = password_ids(view)

    view
    |> form("#integration-form",
      integration: %{
        name: "browser-api",
        target: "https://api.example.test",
        strip_prefix: "",
        bearer: secret,
        basic: "",
        header_name: "x-platform",
        header_value: "header-secret",
        peer: "false",
        peer_vm_id: "",
        team_id: ""
      }
    )
    |> render_submit()

    [integration] = Ledger.read!(Marshall.Galileo.Integration, name: "browser-api")
    assert MapSet.disjoint?(MapSet.new(previous_password_ids), MapSet.new(password_ids(view)))
    assert has_element?(view, "#integration-#{integration.id}")
    assert has_element?(view, "#integration-headers-#{integration.id}", "****")
    refute has_element?(view, "#integrations", secret)
    refute has_element?(view, "#integrations", "header-secret")

    view
    |> form("#attach-form-#{integration.id}", attachment: %{vm_id: vm.id})
    |> render_submit()

    [attachment] =
      Ledger.read!(Marshall.Galileo.Attachment, integration_id: integration.id, vm_id: vm.id)

    assert has_element?(view, "#integration-attachment-#{attachment.id}")

    view
    |> element("#integration-attachment-#{attachment.id} button")
    |> render_click()

    assert Ledger.read!(Marshall.Galileo.Attachment,
             integration_id: integration.id,
             vm_id: vm.id
           ) == []
  end

  @spec password_ids(Phoenix.LiveViewTest.View.t()) :: [String.t()]
  defp password_ids(view) do
    view
    |> element("#integration-form")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("input[type='password']")
    |> LazyHTML.attribute("id")
  end

  defp signed_in(conn, user) do
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(user)
    user = Ash.Resource.put_metadata(user, :token, token)
    conn |> init_test_session(%{}) |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
