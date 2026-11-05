defmodule MarshallWeb.EditorWorkspaceTest do
  use MarshallWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Marshall.Accounts.{GuestAccount, Login, Security, User}
  alias Marshall.Compute
  alias Marshall.Compute.{Image, Ledger, VirtualMachine}
  alias Marshall.EditorFixture, as: F

  setup context do
    previous = Application.fetch_env(:marshall, :ingress_editor_releases)
    Application.put_env(:marshall, :ingress_editor_releases, F.releases())

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:marshall, :ingress_editor_releases, value)
        :error -> Application.delete_env(:marshall, :ingress_editor_releases)
      end
    end)

    fixture =
      if context[:legacy],
        do: Marshall.TerminalFixtures.terminal_fixture(),
        else: F.new()

    {:ok, jti, _} = Login.verify(fixture.token, fixture.owner)
    Map.put(fixture, :owner, Security.bind(fixture.owner, jti))
  end

  # @cc [owner:ghuntley,label:verification;security] editor-view-is-read-only
  # Authorized get/resolve/list projections MUST expose only finite eligibility
  # without allocating GuestAccounts or changing immutable images. Disabling a
  # catalog image MUST retain the running VM's real editor launch behavior.
  test "a disabled matching image remains usable and its authorized views are read only", c do
    [image] = Ledger.read!(Image, id: c.vm.image_id)
    image = Ledger.update!(image, :configure, %{enabled: false})
    accounts = Ledger.read!(GuestAccount)
    fields = Ash.Resource.Info.attributes(Image) |> Enum.map(& &1.name)
    before = Map.take(image, fields)

    assert {:ok, vm} = Compute.get_vm(%{vm_id: c.vm.id}, actor: c.owner)
    assert vm.editor_image_status == :available
    refute Map.has_key?(vm, :editor) or Map.has_key?(vm, :manifest)
    assert {:ok, resolved} = Compute.resolve_vm(%{reference: c.vm.id}, actor: c.owner)
    assert resolved.editor_image_status == :available
    assert {:ok, %{items: items}} = Compute.list_vms(%{limit: 10}, actor: c.owner)
    assert Enum.find(items, &(&1.id == c.vm.id)).editor_image_status == :available
    assert Ledger.read!(GuestAccount) == accounts
    assert [after_view] = Ledger.read!(Image, id: c.vm.image_id)
    assert Map.take(after_view, fields) == before

    assert {:ok, view, _} = live(signed_in(c.owner, c.token), "/machines/#{c.vm.id}")
    assert has_element?(view, "#open-vscode[href='/machines/#{c.vm.id}/code']")
    refute has_element?(view, "#open-vscode-disabled")
    response = get(signed_in(c.owner, c.token), "/machines/#{c.vm.id}/code")
    assert response.status == 302
    [location] = get_resp_header(response, "location")

    assert {:ok, %{vm_id: vm_id}} =
             location
             |> URI.parse()
             |> Map.fetch!(:host)
             |> String.replace_suffix(".apps.example.test", "")
             |> OverallsProtocol.EditorName.parse()

    assert vm_id == c.vm.id
  end

  @tag legacy: true
  test "a real retained legacy image explains new image requirements without a launch link", c do
    assert {:ok, vm} = Compute.get_vm(%{vm_id: c.vm.id}, actor: c.owner)
    assert vm.editor_image_status == :unsupported_image
    assert {:ok, view, _} = live(signed_in(c.owner, c.token), "/machines/#{c.vm.id}")
    refute has_element?(view, "#open-vscode")
    assert has_element?(view, "#open-vscode-disabled[disabled]")

    assert has_element?(
             view,
             "#vscode-unavailable",
             "does not support the current browser editor"
           )

    refute has_element?(view, "#vscode-unavailable", "Create a new machine")
    assert get(signed_in(c.owner, c.token), "/machines/#{c.vm.id}/code").status == 403
  end

  test "a changed release removes a mounted link and its stale URL cannot launch", c do
    assert {:ok, view, _} = live(signed_in(c.owner, c.token), "/machines/#{c.vm.id}")
    assert has_element?(view, "#open-vscode")
    descriptor = Map.put(c.descriptor, "release", String.duplicate("c", 64))
    Application.put_env(:marshall, :ingress_editor_releases, F.releases(descriptor))
    send(view.pid, :refresh_terminals)
    refute has_element?(view, "#open-vscode")

    assert has_element?(
             view,
             "#vscode-unavailable",
             "does not support the current browser editor"
           )

    refute has_element?(view, "#vscode-unavailable", "Create a new machine")
    assert get(signed_in(c.owner, c.token), "/machines/#{c.vm.id}/code").status == 403
  end

  test "missing release configuration fails closed across refresh and direct launch", c do
    assert {:ok, view, _} = live(signed_in(c.owner, c.token), "/machines/#{c.vm.id}")
    Application.delete_env(:marshall, :ingress_editor_releases)
    send(view.pid, :refresh_terminals)
    refute has_element?(view, "#open-vscode")
    assert has_element?(view, "#vscode-unavailable", "temporarily unavailable")
    assert get(signed_in(c.owner, c.token), "/machines/#{c.vm.id}/code").status == 403
  end

  test "stopping a still physically running machine removes the editor link", c do
    assert {:ok, view, _} = live(signed_in(c.owner, c.token), "/machines/#{c.vm.id}")
    Ledger.intent!(c.vm, %{desired_state: :stopped, generation: c.vm.generation + 1})
    assert [%{observed_state: :running}] = Ledger.read!(VirtualMachine, id: c.vm.id)
    send(view.pid, :refresh_terminals)
    refute has_element?(view, "#open-vscode")
    assert has_element?(view, "#vscode-unavailable", "requires a running machine")
    assert get(signed_in(c.owner, c.token), "/machines/#{c.vm.id}/code").status == 403
  end

  test "a mounted writer downgrade removes the link and fresh launch authority refuses", c do
    writer = Marshall.ComputeFixtures.user()
    token = Marshall.TerminalFixtures.user_token(writer)
    assert {:ok, _} = Marshall.TerminalFixtures.grant(c, writer, :operator)
    assert {:ok, view, _} = live(signed_in(writer, token), "/machines/#{c.vm.id}")
    assert has_element?(view, "#open-vscode")
    assert {:ok, _} = Marshall.TerminalFixtures.grant(c, writer, :viewer)
    send(view.pid, :refresh_terminals)
    refute has_element?(view, "#open-vscode")
    refute has_element?(view, "#open-vscode-disabled")
    assert get(signed_in(writer, token), "/machines/#{c.vm.id}/code").status == 403
  end

  test "a revoked stored login cannot retain mounted editor access", c do
    assert {:ok, view, _} = live(signed_in(c.owner, c.token), "/machines/#{c.vm.id}")
    assert has_element?(view, "#open-vscode")
    :ok = AshAuthentication.TokenResource.Actions.revoke(Marshall.Accounts.Token, c.token)
    send(view.pid, :refresh_terminals)
    assert_redirect(view, "/sign-in")
    response = get(signed_in(c.owner, c.token), "/machines/#{c.vm.id}/code")
    assert redirected_to(response) == "/sign-in"
  end

  test "a projection without image status renders safely with no active editor link", c do
    assert {:ok, vm} = Compute.get_vm(%{vm_id: c.vm.id}, actor: c.owner)

    document =
      render_component(&MarshallWeb.WorkspaceComponents.machine_header/1,
        vm: Map.delete(vm, :editor_image_status),
        active: "terminal",
        power_key: Ash.UUID.generate()
      )
      |> LazyHTML.from_fragment()

    assert Enum.empty?(LazyHTML.query(document, "#open-vscode"))
    assert Enum.count(LazyHTML.query(document, "#open-vscode-disabled[disabled]")) == 1
  end

  # @cc [owner:ghuntley,label:verification;security] agentless-image-hides-guest-controls
  # A projection whose image carries no guest agents MUST render without the
  # Terminal navigation, the editor link, or the SSH connection commands, and
  # MUST explain why; a Linux projection keeps them. Machine navigation MUST
  # omit Agents for every image because Threads is the global entry.
  test "guest capabilities gate machine controls while Agents stays out of machine navigation",
       c do
    assert {:ok, vm} = Compute.get_vm(%{vm_id: c.vm.id}, actor: c.owner)
    assert vm.guest_capabilities.available and vm.guest_capabilities.terminal

    connection = %{
      install: "curl install",
      install_windows: "windows install",
      ssh: "ssh host"
    }

    render = fn projection ->
      render_component(&MarshallWeb.WorkspaceComponents.machine_header/1,
        vm: projection,
        connection: connection,
        active: "terminal",
        power_key: Ash.UUID.generate()
      )
      |> LazyHTML.from_fragment()
    end

    linux = render.(vm)
    assert Enum.count(LazyHTML.query(linux, "#ssh-connection-commands")) == 1
    assert Enum.empty?(LazyHTML.query(linux, "a[href='/machines/#{c.vm.id}/threads']"))
    assert Enum.count(LazyHTML.query(linux, "a[href='/machines/#{c.vm.id}']")) == 1
    assert Enum.count(LazyHTML.query(linux, "#open-vscode")) == 1

    assert Enum.empty?(LazyHTML.query(linux, "#machine-boot-log"))

    windows =
      render.(
        Map.put(vm, :guest_capabilities, %{
          available: true,
          ssh: false,
          terminal: false,
          agents: false,
          editor: false,
          readiness: false,
          inception: false
        })
      )

    assert Enum.empty?(LazyHTML.query(windows, "#ssh-connection-commands"))
    assert Enum.empty?(LazyHTML.query(windows, "a[href='/machines/#{c.vm.id}/threads']"))
    assert Enum.empty?(LazyHTML.query(windows, "a[href='/machines/#{c.vm.id}']"))
    assert Enum.empty?(LazyHTML.query(windows, "#open-vscode"))
    assert Enum.empty?(LazyHTML.query(windows, "#open-vscode-disabled"))

    assert Enum.empty?(LazyHTML.query(windows, ".machine-tabs #machine-boot-log"))

    assert Enum.count(
             LazyHTML.query(
               windows,
               "#machine-connect-unavailable #machine-boot-log[href='/machines/#{c.vm.id}/terminals?view=boot-log']"
             )
           ) == 1

    # Without commands the box starts open so the explanation stays visible.
    assert Enum.count(LazyHTML.query(windows, "details#machine-connect-details[open]")) == 1

    notice = LazyHTML.query(windows, "#machine-connect-unavailable")
    assert Enum.count(notice) == 1
    assert LazyHTML.text(notice) =~ "no guest agents"
    assert Enum.count(LazyHTML.query(windows, "a[href='/machines/#{c.vm.id}/settings']")) == 1

    with_agents =
      render.(
        Map.put(vm, :guest_capabilities, %{
          available: true,
          ssh: true,
          terminal: true,
          agents: true,
          editor: false,
          readiness: true,
          inception: false
        })
      )

    assert Enum.count(LazyHTML.query(with_agents, "#ssh-connection-commands")) == 1
    assert Enum.count(LazyHTML.query(with_agents, "a[href='/machines/#{c.vm.id}']")) == 1
    assert Enum.empty?(LazyHTML.query(with_agents, "a[href='/machines/#{c.vm.id}/threads']"))
    assert Enum.empty?(LazyHTML.query(with_agents, "#open-vscode"))
    assert Enum.empty?(LazyHTML.query(with_agents, "#open-vscode-disabled"))

    # A missing projection fails closed like the editor status does.
    unknown = render.(Map.delete(vm, :guest_capabilities))
    assert Enum.empty?(LazyHTML.query(unknown, "#ssh-connection-commands"))
    assert Enum.empty?(LazyHTML.query(unknown, "a[href='/machines/#{c.vm.id}']"))
  end

  @spec signed_in(User.t(), String.t()) :: Plug.Conn.t()
  defp signed_in(user, token) do
    user = Ash.Resource.put_metadata(user, :token, token)

    build_conn()
    |> init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
