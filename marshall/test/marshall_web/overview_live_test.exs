defmodule MarshallWeb.OverviewLiveTest do
  # @cc [owner:ghuntley,label:product] overview-newsletter-and-localized-navigation
  # Overview renders and dismisses the newsletter panel
  use MarshallWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Marshall.ComputeFixtures
  alias Marshall.{Access, Compute}
  alias Marshall.Compute.Ledger
  alias Marshall.EditorFixture

  test "anonymous visitors must sign in", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, "/overview")
  end

  test "empty overview offers creation and all workspace destinations", %{conn: conn} do
    {:ok, view, _} = live(signed_in(conn, user()), "/overview")
    assert has_element?(view, "#overview-machines-empty")
    assert has_element?(view, "#overview-create[href='/machines/new']")
    assert has_element?(view, "nav[aria-label=Main] a[href='/git']")
    # AI usage is an account destination, listed after the workspace group.
    html = render(view)
    {account, _} = :binary.match(html, "Your account")
    {usage, _} = :binary.match(html, ~s(id="nav-usage"))
    assert usage > account
    assert has_element?(view, "#nav-usage[href='/usage']", "AI usage")
    assert has_element?(view, "nav[aria-label=Main] a[aria-current=page][href='/overview']")
    assert has_element?(view, "#nav-marvin-extension[href='/docs/browser-extension']")
    assert has_element?(view, "li[data-overalls-extension-setup] #nav-marvin-extension")
    assert has_element?(view, "#overview-marvin-extension[data-overalls-extension-setup]")
    assert has_element?(view, "#overview-marvin-extension-link[href='/docs/browser-extension']")
    assert has_element?(view, "a[href='/admin/nodes']", "Control room")
    assert has_element?(view, "#overview-capacity-unavailable")
    assert has_element?(view, "#overview-newsletter")

    assert has_element?(
             view,
             "#overview-newsletter-form[action='https://ghuntley.com/newsletter/']"
           )

    assert has_element?(view, "#overview-newsletter-dismiss")

    view |> element("#overview-newsletter-dismiss") |> render_click()
    refute has_element?(view, "#overview-newsletter")
  end

  test "preview status labels name the state and carry its severity tone", %{conn: conn} do
    host_fixture()
    host_fixture()
    owner = user()
    {:ok, failed} = Compute.provision(request(), actor: owner)

    Ledger.update!(failed, :observe, %{observed_state: :failed, failure_reason: :execution_failed})

    {:ok, running} = Compute.provision(request(), actor: owner)
    Ledger.update!(running, :observe, %{observed_state: :running})

    {:ok, view, _} = live(signed_in(conn, owner), "/overview")
    labels = fn vm -> "#overview-machine-#{vm.id} .preview-labels" end

    assert has_element?(
             view,
             labels.(failed) <> " .status-label[data-state=failed][data-tone=danger]",
             "Failed"
           )

    assert has_element?(
             view,
             labels.(running) <> " .status-label[data-state=running][data-tone=success]",
             "Running"
           )

    # [OS] leads [State] inside the label row.
    assert has_element?(
             view,
             labels.(failed) <> " #overview-machine-os-#{failed.id} + .status-label"
           )
  end

  test "preview includes shared machines, excludes unrelated machines, and drops revoked grants",
       %{conn: conn} do
    host_fixture()
    owner = user()
    member = user()
    {:ok, shared} = Compute.provision(request(), actor: owner)
    {:ok, private} = Compute.provision(request(), actor: owner)

    grant = %{
      vm_id: shared.id,
      email: to_string(member.email),
      role: :viewer,
      idempotency_key: Ash.UUID.generate()
    }

    {:ok, _} = Access.set_access(grant, actor: owner)
    {:ok, view, _} = live(signed_in(conn, member), "/overview")
    assert has_element?(view, "#overview-machine-#{shared.id}")

    assert has_element?(
             view,
             "#overview-machine-#{shared.id} p",
             ~r/vCPU · .* GiB RAM · .* GiB disk · Shared/
           )

    assert has_element?(view, "#overview-machine-os-#{shared.id}", "synthetic-test-image")
    # Operating system comes first, then status.
    assert has_element?(view, "#overview-machine-os-#{shared.id} + .status-label")
    refute has_element?(view, "#overview-machine-#{private.id}")

    {:ok, _} =
      Access.set_access(%{grant | role: :revoked, idempotency_key: Ash.UUID.generate()},
        actor: owner
      )

    view |> element("#overview-refresh") |> render_click()
    refute has_element?(view, "#overview-machine-#{shared.id}")
  end

  test "overview exposes terminal and VS Code actions for an eligible owner", %{conn: conn} do
    put_editor_release()
    fixture = EditorFixture.new()
    machine_id = fixture.vm.id

    {:ok, view, _} = live(signed_in(conn, fixture.owner), "/overview")

    assert has_element?(view, "#overview-machine-#{machine_id}")

    assert has_element?(
             view,
             "#overview-terminal-#{machine_id}[href='/machines/#{machine_id}/terminals']"
           )

    assert has_element?(
             view,
             "#overview-machine-#{machine_id}-vscode.machine-editor-link[href='/machines/#{machine_id}/code'][target='_blank'][rel='noopener noreferrer']",
             "Open VS Code ↗"
           )

    refute has_element?(view, "#overview-machine-#{machine_id}-vscode.console-button")

    refute has_element?(view, "#overview-machine-#{machine_id}-vscode-disabled")
    refute has_element?(view, "a[href='/machines/#{machine_id}/threads']")
  end

  test "overview hides VS Code from a viewer", %{conn: conn} do
    put_editor_release()
    fixture = EditorFixture.new()
    viewer = user()
    assert {:ok, _} = Marshall.TerminalFixtures.grant(fixture, viewer, :viewer)

    {:ok, view, _} = live(signed_in(conn, viewer), "/overview")

    assert has_element?(view, "#overview-machine-#{fixture.vm.id}")
    refute has_element?(view, "#overview-machine-#{fixture.vm.id}-vscode")
    refute has_element?(view, "#overview-machine-#{fixture.vm.id}-vscode-disabled")
  end

  test "overview disables VS Code when a machine is stopped or unavailable", %{conn: conn} do
    put_editor_release()
    fixture = EditorFixture.new()
    machine_id = fixture.vm.id
    {:ok, view, _} = live(signed_in(conn, fixture.owner), "/overview")

    Ledger.intent!(fixture.vm, %{desired_state: :stopped, generation: fixture.vm.generation + 1})
    send(view.pid, :refresh)
    assert has_element?(view, "#overview-machine-#{machine_id}-vscode-disabled[disabled]")

    assert has_element?(
             view,
             "#overview-machine-#{machine_id}-vscode-reason",
             "requires a running machine"
           )

    Application.delete_env(:marshall, :ingress_editor_releases)
    send(view.pid, :refresh)
    assert has_element?(view, "#overview-machine-#{machine_id}-vscode-disabled[disabled]")

    assert has_element?(
             view,
             "#overview-machine-#{machine_id}-vscode-reason",
             "temporarily unavailable"
           )
  end

  test "overview explains unsupported images without an editor link", %{conn: conn} do
    put_editor_release()
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    machine_id = fixture.vm.id
    {:ok, view, _} = live(signed_in(conn, fixture.owner), "/overview")

    refute has_element?(view, "#overview-machine-#{machine_id}-vscode")
    assert has_element?(view, "#overview-machine-#{machine_id}-vscode-disabled[disabled]")

    assert has_element?(
             view,
             "#overview-machine-#{machine_id}-vscode-reason",
             "does not support the current browser editor"
           )

    refute has_element?(view, "#overview-machine-#{machine_id}-vscode-reason", "new machine")
  end

  test "machine preview stays bounded", %{conn: conn} do
    for _ <- 1..4, do: host_fixture()
    owner = user()
    for _ <- 1..7, do: assert({:ok, _} = Compute.provision(request(), actor: owner))
    {:ok, view, _} = live(signed_in(conn, owner), "/overview")

    assert view
           |> element("#overview-machine-preview")
           |> render()
           |> LazyHTML.from_fragment()
           |> LazyHTML.query("article")
           |> Enum.count() == 6
  end

  test "overview omits usage summary while retaining the usage destination", %{conn: conn} do
    owner = user()
    today = DateTime.to_date(Ledger.now())
    daily(owner.id, today, 3, 1, 123, 45)
    {:ok, view, _} = live(signed_in(conn, owner), "/overview")

    refute has_element?(view, "#overview-usage")
    refute has_element?(view, "#overview-incomplete")
    refute has_element?(view, "#overview-usage-unavailable")
    refute render(view) =~ "Reported input tokens"
    assert has_element?(view, "a[href='/usage']", "Explore your usage")
  end

  test "a revoked login halts refresh", %{conn: conn} do
    owner = user()
    conn = signed_in(conn, owner)
    token = get_session(conn, "user_token")
    {:ok, view, _} = live(conn, "/overview")
    {:ok, %{"jti" => jti}} = AshAuthentication.Jwt.peek(token)
    Ecto.Adapters.SQL.query!(Marshall.Repo, "DELETE FROM tokens WHERE jti=$1", [jti], log: false)
    send(view.pid, :refresh)
    assert_redirect(view, "/sign-in")
  end

  test "unavailable panels do not render zero measurements" do
    html =
      render_component(&MarshallWeb.OverviewLive.render/1,
        flash: %{},
        current_user: user(),
        machines: :unavailable,
        catalog: :unavailable,
        updated_at: ~U[2026-10-18 12:00:00Z],
        time_zone: "Etc/UTC",
        now: ~U[2026-10-18 12:00:00Z]
      )

    document = LazyHTML.from_fragment(html)
    assert Enum.count(LazyHTML.query(document, "#overview-machines-unavailable")) == 1
    assert Enum.count(LazyHTML.query(document, "#overview-capacity-unavailable")) == 1
  end

  test "hidden pages pause automatic refresh and manual refresh remains available", %{conn: conn} do
    owner = user()
    {:ok, view, _} = live(signed_in(conn, owner), "/overview")
    render_hook(view, "visibility", %{"visible" => false})
    host_fixture()
    {:ok, machine} = Compute.provision(request(), actor: owner)
    send(view.pid, :refresh)
    refute has_element?(view, "#overview-machine-#{machine.id}")
    view |> element("#overview-refresh") |> render_click()
    assert has_element?(view, "#overview-machine-#{machine.id}")
  end

  @spec daily(
          String.t(),
          Date.t(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer(),
          non_neg_integer()
        ) :: Marshall.Inference.Daily.t()
  defp daily(owner, day, requests, unknown, input, output) do
    Ledger.create!(Marshall.Inference.Daily, :record, %{
      owner_id: owner,
      day: day,
      provider: :openai,
      model: "test",
      requests: requests,
      unknown_requests: unknown,
      input_tokens: input,
      output_tokens: output
    })
  end

  @spec signed_in(Plug.Conn.t(), Marshall.Accounts.User.t()) :: Plug.Conn.t()
  defp signed_in(conn, user) do
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(user)
    user = Ash.Resource.put_metadata(user, :token, token)
    conn |> init_test_session(%{}) |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  @spec put_editor_release() :: :ok
  defp put_editor_release do
    previous = Application.fetch_env(:marshall, :ingress_editor_releases)
    Application.put_env(:marshall, :ingress_editor_releases, Marshall.EditorFixture.releases())
    on_exit(fn -> restore_editor_release(previous) end)
    :ok
  end

  @spec restore_editor_release({:ok, map()} | :error) :: :ok
  defp restore_editor_release({:ok, value}) do
    Application.put_env(:marshall, :ingress_editor_releases, value)
    :ok
  end

  defp restore_editor_release(:error) do
    Application.delete_env(:marshall, :ingress_editor_releases)
    :ok
  end
end
