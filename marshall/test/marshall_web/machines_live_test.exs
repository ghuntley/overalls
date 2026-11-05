defmodule MarshallWeb.MachinesLiveTest do
  use MarshallWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Marshall.ComputeFixtures
  alias Marshall.{Access, Compute, Teams}
  alias Marshall.Compute.{Ledger, Operation, VirtualMachine}
  alias Marshall.Threads.{ProvisionWorker, Thread}
  alias Marshall.EditorFixture

  setup do
    fixture = host_fixture()
    owner = user()
    %{owner: owner, fixture: fixture}
  end

  # @cc [owner:ghuntley,label:verification;product] settings-reflection-metadata-projection
  # Settings MUST render the persisted labels and comment from the authorized
  # machine projection, including empty defaults on a newly created machine.
  test "settings renders empty and persisted Reflection metadata", %{conn: conn, owner: owner} do
    {:ok, vm} = Compute.provision(request(), actor: owner)
    conn = signed_in(conn, owner)
    {:ok, view, _} = live(conn, ~p"/machines/#{vm.id}/settings")
    assert has_element?(view, "#reflection-metadata input[name='metadata[labels]'][value='']")
    assert has_element?(view, "#reflection-metadata textarea[name='metadata[comment]']")

    Ash.Seed.update!(vm, %{labels: ["production", "project-name"], comment: "Agent workspace"})
    send(view.pid, :refresh)

    assert has_element?(
             view,
             "#reflection-metadata input[name='metadata[labels]'][value='production, project-name']"
           )

    assert has_element?(
             view,
             "#reflection-metadata textarea[name='metadata[comment]']",
             "Agent workspace"
           )
  end

  # @cc [owner:ghuntley,label:verification;recovery] suspended-machine-controls
  # Paused machines MUST expose Resume and terminal connection, never Start;
  # transitional labels MUST retain their text and pending severity.
  test "paused machines retain resume controls and terminal connection", %{
    conn: conn,
    owner: owner
  } do
    {:ok, vm} = Compute.provision(request(), actor: owner)
    Ash.Seed.update!(vm, %{desired_state: :paused, observed_state: :paused})
    {:ok, detail, _} = live(signed_in(conn, owner), ~p"/machines/#{vm.id}")
    assert has_element?(detail, "#resume-machine[phx-value-kind=resume]", "Resume machine")
    assert has_element?(detail, "#stop-machine")
    refute has_element?(detail, "#start-machine")
    refute has_element?(detail, "#pause-machine")
    assert has_element?(detail, "#machine-state[data-state=paused]", "Paused")

    {:ok, listing, _} = live(signed_in(conn, owner), ~p"/machines")
    assert has_element?(listing, "#machine-terminal-#{vm.id}")

    for {desired, observed, label} <- [
          {:paused, :running, "Suspending"},
          {:running, :paused, "Resuming"}
        ] do
      state = %{desired_state: desired, observed_state: observed}
      assert MarshallWeb.WorkspaceComponents.machine_state(state) == label
      assert MarshallWeb.WorkspaceComponents.machine_tone(state) == "pending"
    end
  end

  # @cc [owner:ghuntley,label:verification;security] windows-machine-lifecycle-surface
  # A Windows guest admitted through the native windows-v1 image must project the
  # same authenticated list/detail lifecycle controls as other guests. Request
  # keys are UUIDs, rotate after an accepted mutation and remain bound to the
  # operation kind so forged reuse cannot enqueue a second intent.
  test "windows machines expose list detail and lifecycle controls", %{
    conn: conn,
    owner: owner,
    fixture: fixture
  } do
    image = windows_v1_image_fixture()
    report_windows_capacity(fixture, image.id)

    # Admission refuses requests below the image minima (2 GiB, 32 GiB).
    {:ok, vm} =
      Compute.provision(
        request(%{
          image_id: image.id,
          memory_bytes: image.minimum_memory_bytes,
          disk_bytes: image.minimum_disk_bytes
        }),
        actor: owner
      )

    # The terminal link and stop control are offered only for a running machine.
    vm = Ash.Seed.update!(vm, %{desired_state: :running, observed_state: :running})
    signed = signed_in(conn, owner)

    {:ok, listing, _} = live(signed, ~p"/machines")
    assert has_element?(listing, "#machines-#{vm.id}")
    assert has_element?(listing, "#machine-terminal-#{vm.id}")

    assert has_element?(listing, "#machine-os-#{vm.id}", "Windows Server 2025 (agents)")

    {:ok, detail, _} = live(signed, ~p"/machines/#{vm.id}/settings")
    assert has_element?(detail, "#machine-detail")
    assert has_element?(detail, "#machine-operating-system", "Windows Server 2025 (agents)")
    assert has_element?(detail, "#stop-machine")
    stop_key = power_key(detail, "#stop-machine")

    assert Regex.match?(
             ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
             stop_key
           )

    render_click(detail, "machine-power", %{"kind" => "stop", "key" => stop_key})

    assert [%{kind: :stop, request_key: ^stop_key}] =
             Ledger.read!(Operation, vm_id: vm.id, kind: :stop)

    assert has_element?(detail, "#start-machine")
    start_key = power_key(detail, "#start-machine")
    refute start_key == stop_key

    render_click(detail, "machine-power", %{"kind" => "start", "key" => stop_key})
    assert has_element?(detail, "#flash-group", "could not be updated")
    assert [] = Ledger.read!(Operation, vm_id: vm.id, kind: :start)
  end

  test "machine connection keeps installer and SSH commands without a profile download", %{
    conn: conn,
    owner: owner
  } do
    {:ok, vm} = Compute.provision(request(), actor: owner)
    {:ok, view, _} = live(signed_in(conn, owner), ~p"/machines/#{vm.id}")

    assert has_element?(view, "#machine-install-command", "/bin/install.sh")
    assert has_element?(view, "#machine-ssh-command", "ssh ")
    refute has_element?(view, "#machine-ssh-command", "overalls ssh")
    assert has_element?(view, "#machine-connect-windows #machine-install-command-windows")
    # One disclosure for the whole box (collapsed while it holds commands);
    # nothing inside it is collapsible.
    assert has_element?(view, "#machine-connect > details#machine-connect-details:not([open])")
    assert has_element?(view, "#machine-connect-details > summary #machine-connect-title")
    refute has_element?(view, "#machine-connect-details details")
    assert has_element?(view, "#machine-connect > #machine-copy-status")
    assert has_element?(view, "#machine-install-command-windows", "/bin/install.ps1")
    assert has_element?(view, "#machine-install-command-windows", "-ExecutionPolicy Bypass")
    refute has_element?(view, "#machine-ssh-command-windows")

    # Every Copy control shares one presentation; none is a primary button.
    copy_buttons =
      view |> render() |> LazyHTML.from_fragment() |> LazyHTML.query("[data-copy-command]")

    assert Enum.count(copy_buttons) == 4
    assert Enum.count(LazyHTML.query(copy_buttons, ".console-button.compact.copy-button")) == 4
    refute has_element?(view, "[data-copy-command].primary")
    refute has_element?(view, "#download-ssh-config")
    refute has_element?(view, "a[href$='/ssh-config']")

    # The header shows the operating system (the registered image name) beside
    # the state and the machine ID inline with its own Copy button.
    assert has_element?(view, "#machine-workspace-header h1", vm.name)
    assert has_element?(view, "#machine-state[data-state]")
    assert has_element?(view, "#machine-os.status-label", "synthetic-test-image")
    # Operating system comes first, then status.
    assert has_element?(view, ".machine-title h1 + #machine-os + #machine-state")
    assert has_element?(view, "#machine-id", vm.id)

    assert has_element?(
             view,
             "#machine-workspace-header button[data-copy-command='machine-id'][data-copy-label='Machine ID']"
           )

    refute has_element?(view, "#machine-workspace-header summary", "Machine ID")
    assert has_element?(view, "#machine-connect h3", "Install and connect")
    assert has_element?(view, "#machine-connect h3", "Already installed")
    assert has_element?(view, "#machine-connect .connection-platform", "Windows")
    refute has_element?(view, "#machine-connect h3", "Already installed?")
  end

  test "Customer hides sharing but retains owner lifecycle controls", %{conn: conn, owner: owner} do
    {:ok, vm} = Compute.provision(request(%{profile: :customer}), actor: owner)
    {:ok, view, _} = live(signed_in(conn, owner), ~p"/machines/#{vm.id}/settings")
    assert has_element?(view, "#customer-isolation")
    refute has_element?(view, "#sharing-form")
    assert has_element?(view, "#lifecycle-actions")
    assert has_element?(view, "#clone-form")
    assert has_element?(view, "#resize-machine")

    assert {:error, {:live_redirect, %{to: to}}} =
             live(signed_in(build_conn(), owner), ~p"/machines/#{vm.id}/resources")

    assert to == ~p"/machines/#{vm.id}/settings"
  end

  # @cc [owner:ghuntley,label:verification;recovery] power-key-refusal-reuse
  # A refused power event records no operation, so its request key MUST remain
  # usable: the same key with a different kind submits the fresh intent exactly
  # once. Accepted intent MUST rotate the rendered key for the next click.
  test "a refused power event keeps its key usable for a fresh different kind", %{
    conn: conn,
    owner: owner,
    fixture: fixture
  } do
    {:ok, vm} = Compute.provision(request(%{profile: :customer}), actor: owner)
    {:ok, view, _} = live(signed_in(conn, owner), ~p"/machines/#{vm.id}/settings")
    stop_key = power_key(view, "#stop-machine")
    dispatches = dispatch_count()

    view |> element("#stop-machine") |> render_click()
    assert [%{kind: :stop}] = Ledger.read!(Operation, vm_id: vm.id, kind: :stop)
    assert [%{desired_state: :stopped}] = Ledger.read!(VirtualMachine, id: vm.id)
    assert has_element?(view, "#start-machine")
    start_key = power_key(view, "#start-machine")
    refute start_key == stop_key

    Ledger.update!(fixture.host, :report, %{capacity: capacity(0, 0)})
    render_click(view, "machine-power", %{"kind" => "start", "key" => start_key})
    assert has_element?(view, "#flash-group", "could not be updated")
    assert [] = Ledger.read!(Operation, vm_id: vm.id, kind: :start)
    assert 1 == length(Ledger.read!(Operation, vm_id: vm.id, kind: :stop))
    assert [%{desired_state: :stopped}] = Ledger.read!(VirtualMachine, id: vm.id)
    assert dispatch_count() == dispatches + 1
    assert power_key(view, "#start-machine") == start_key

    render_click(view, "machine-power", %{"kind" => "stop", "key" => start_key})

    assert [%{request_key: ^start_key}] =
             Ledger.read!(Operation, vm_id: vm.id, kind: :stop, request_key: start_key)

    assert 2 == length(Ledger.read!(Operation, vm_id: vm.id, kind: :stop))
    assert [%{desired_state: :stopped}] = Ledger.read!(VirtualMachine, id: vm.id)
    assert dispatch_count() == dispatches + 2
    refute power_key(view, "#start-machine") == start_key
  end

  # @cc [owner:ghuntley,label:verification;recovery] power-key-kind-conflict
  # A request key bound to an accepted kind MUST refuse a changed kind through
  # either power entry without enqueueing another operation or changing durable
  # intent; the flash uses only a fixed public message.
  test "an accepted key refuses a changed kind without enqueueing new intent", %{
    conn: conn,
    owner: owner
  } do
    {:ok, vm} = Compute.provision(request(%{profile: :customer}), actor: owner)
    {:ok, view, _} = live(signed_in(conn, owner), ~p"/machines/#{vm.id}/settings")
    stop_key = power_key(view, "#stop-machine")
    dispatches = dispatch_count()
    view |> element("#stop-machine") |> render_click()
    assert [%{kind: :stop}] = Ledger.read!(Operation, vm_id: vm.id, kind: :stop)

    render_click(view, "machine-power", %{"kind" => "start", "key" => stop_key})
    assert has_element?(view, "#flash-group", "could not be updated")
    assert [] = Ledger.read!(Operation, vm_id: vm.id, kind: :start)
    assert [%{desired_state: :stopped}] = Ledger.read!(VirtualMachine, id: vm.id)
    assert dispatch_count() == dispatches + 1

    render_click(view, "lifecycle", %{"kind" => "delete", "key" => stop_key})
    assert has_element?(view, "#flash-group", "already been used")
    assert [] = Ledger.read!(Operation, vm_id: vm.id, kind: :delete)

    assert [%{desired_state: :stopped, archived_at: nil}] =
             Ledger.read!(VirtualMachine, id: vm.id)

    assert dispatch_count() == dispatches + 1
  end

  # @cc [owner:ghuntley,label:verification;security] customer-browser-entry-refusal
  # Non-owner browser reads of a Customer machine MUST redirect to /machines
  # without lifecycle work, including one seeded stale manager grant and an
  # elevated administrator; the machine remains untouched through every denied
  # direct URL.
  test "customer detail refuses member, stranger and elevated administrator reads", %{
    owner: owner
  } do
    {:ok, vm} = Compute.provision(request(%{profile: :customer}), actor: owner)
    grant_member = user()

    Ledger.create!(Marshall.Access.Grant, :grant, %{
      vm_id: vm.id,
      user_id: grant_member.id,
      granted_by_id: owner.id,
      role: :manager
    })

    admin = Marshall.PasskeyFixture.user(true) |> Marshall.PasskeyFixture.verified_session()
    operations = Ledger.read!(Operation, vm_id: vm.id)

    for actor <- [grant_member, user(), admin] do
      for {path, notice} <- [
            {"/machines/#{vm.id}", "Machine not found."},
            {"/machines/#{vm.id}/settings", "unavailable"}
          ] do
        assert {:error, redirect} = live(signed_in_current(build_conn(), actor), path)
        assert redirect_location(redirect) == "/machines"
        assert %{"error" => flash} = redirect_flash(redirect)
        assert flash =~ notice
      end
    end

    assert Ledger.read!(Operation, vm_id: vm.id) == operations

    assert [%{desired_state: :running, archived_at: nil}] =
             Ledger.read!(VirtualMachine, id: vm.id)
  end

  test "creation form compares available profile capabilities", %{conn: conn, owner: owner} do
    {:ok, view, _} = live(signed_in(conn, owner), ~p"/machines/new")

    assert has_element?(view, "#machine_profile option[selected][value='standard']")
    assert has_element?(view, "#machine_profile[aria-describedby='profile-guide']")
    # Creation opens an agent thread; Customer VMs have no agent root (ADR-0099).
    refute has_element?(view, "#machine_profile option[value='customer']")
    refute has_element?(view, "#profile-help-customer")
    assert has_element?(view, "#profile-help-standard", "cannot start child agents")
    assert has_element?(view, "#profile-help-oss", "can start child agents")
    refute has_element?(view, "#profile-help-inception")
  end

  # @cc [owner:ghuntley,label:verification;observability] creation-form-edits-skip-refresh
  # Editing the creation form MUST NOT reload page data; a refresh tick MUST
  # reload it exactly once.
  test "creation form edits do not reload page data but a tick does", %{
    conn: conn,
    owner: owner
  } do
    test = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:marshall, :live, :refresh],
        fn _event, _measurements, metadata, _ -> send(test, {:page_refresh, metadata.view}) end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    {:ok, view, _} = live(signed_in(conn, owner), ~p"/machines/new")
    _ = render(view)
    drain_page_refreshes()

    for name <- ["draft-a", "draft-ab", "draft-abc"] do
      view |> element("#provision-form") |> render_change(%{"machine" => %{"name" => name}})
    end

    _ = render(view)
    refute_received {:page_refresh, _}

    send(view.pid, :refresh)
    _ = render(view)
    assert_received {:page_refresh, :machine_new}
    refute_received {:page_refresh, _}
  end

  test "clone form queues additional copies and retains duplicate submission identity", %{
    conn: conn,
    owner: owner
  } do
    {:ok, vm} = Compute.provision(request(), actor: owner)
    {:ok, view, _} = live(signed_in(conn, owner), ~p"/machines/#{vm.id}/settings")
    assert has_element?(view, "#clone-form")
    assert has_element?(view, "#clone-empty")
    params = %{"clone" => %{"name" => "", "request_key" => "browser-copy-one"}}
    render_submit(view, "clone", params)
    render_submit(view, "clone", params)
    assert length(Ledger.read!(Marshall.Compute.CloneRequest)) == 1

    render_submit(view, "clone", %{
      "clone" => %{"name" => "", "request_key" => "browser-copy-two"}
    })

    assert length(Ledger.read!(Marshall.Compute.CloneRequest)) == 2
    assert has_element?(view, "#clone-requests article", "Queue position 2")
    refute has_element?(view, "#clone-empty")
  end

  test "clone cards refresh through snapshot, recovery, publication and completion", %{
    conn: conn,
    owner: owner
  } do
    {:ok, vm} = Compute.provision(request(), actor: owner)
    {:ok, clone} = Compute.clone(%{vm_id: vm.id, idempotency_key: "progress-card"}, actor: owner)
    {:ok, view, _} = live(signed_in(conn, owner), ~p"/machines/#{vm.id}/settings")
    card = "#clones-#{clone.id}"
    assert has_element?(view, card <> "-status", "Queued")
    [record] = Ledger.read!(Marshall.Compute.CloneRequest, id: clone.id)

    record =
      Enum.reduce(
        [
          {:prepare, %{active: true, original_power_state: :running}, "Preparing clone"},
          {:stop_source, %{}, "Stopping source for snapshot"},
          {:capture, %{}, "Taking snapshot"},
          {:confirm_capture, %{}, "Copying files"}
        ],
        record,
        fn {action, attrs, label}, record ->
          next = Ledger.update!(record, action, attrs)
          send(view.pid, :refresh)
          assert has_element?(view, card <> "-status", label)
          assert has_element?(view, "#clone-announcement", label)
          next
        end
      )

    record = Ledger.update!(record, :record_progress, %{failure: "source_restart_failed"})
    send(view.pid, :refresh)
    assert has_element?(view, card <> "-status", "Needs attention")
    view |> element(card <> "-retry") |> render_click()
    assert has_element?(view, card <> " .clone-source", "Source recovery retry requested")

    record =
      Ledger.update!(record, :record_progress, %{
        source_restored_at: DateTime.utc_now(),
        failure: nil
      })

    send(view.pid, :refresh)

    assert has_element?(
             view,
             card <> " .clone-source",
             "Source returned to its original power state"
           )

    assert has_element?(view, card <> "-status", "Copying files")
    refute has_element?(view, card <> "-open")

    record = Ledger.update!(record, :confirm_copy, %{})
    send(view.pid, :refresh)
    assert has_element?(view, card <> "-status", "Creating cloned machine")
    record = Ledger.update!(record, :publish, %{published_at: DateTime.utc_now()})
    send(view.pid, :refresh)
    assert has_element?(view, card <> "-status", "Finishing up")
    assert has_element?(view, card <> "-open[href='/machines/#{clone.destination_vm_id}']")
    refute has_element?(view, card <> "-cancel")

    Ledger.update!(record, :complete, %{active: false, finished_at: DateTime.utc_now()})
    send(view.pid, :refresh)
    assert has_element?(view, card <> "-status", "Clone complete")

    assert Enum.count(
             view
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.query(card <> " [data-state='done']")
           ) == 5

    announcement = view |> element("#clone-announcement") |> render()
    send(view.pid, :refresh)
    assert view |> element("#clone-announcement") |> render() == announcement
  end

  test "clone cancellation and failed admission retain truthful recovery controls", %{
    conn: conn,
    owner: owner
  } do
    {:ok, vm} = Compute.provision(request(), actor: owner)
    {:ok, clone} = Compute.clone(%{vm_id: vm.id, idempotency_key: "cancel-card"}, actor: owner)
    {:ok, view, _} = live(signed_in(conn, owner), ~p"/machines/#{vm.id}/settings")
    card = "#clones-#{clone.id}"
    [record] = Ledger.read!(Marshall.Compute.CloneRequest, id: clone.id)

    record =
      Ledger.update!(record, :fail, %{
        failure: "insufficient_capacity",
        finished_at: DateTime.utc_now()
      })

    send(view.pid, :refresh)
    assert has_element?(view, card <> "-status", "Clone needs attention")
    assert has_element?(view, card <> " .clone-failure", "not enough capacity")
    view |> element(card <> "-retry") |> render_click()
    assert has_element?(view, card <> "-status", "Queued")
    [record] = Ledger.read!(Marshall.Compute.CloneRequest, id: record.id)
    record = Ledger.update!(record, :prepare, %{active: true, original_power_state: :running})
    send(view.pid, :refresh)
    view |> element(card <> "-cancel") |> render_click()
    assert has_element?(view, card <> "-status", "Cancelling clone")
    [record] = Ledger.read!(Marshall.Compute.CloneRequest, id: record.id)
    Ledger.update!(record, :cancel, %{active: false, finished_at: DateTime.utc_now()})
    send(view.pid, :refresh)
    assert has_element?(view, card <> "-status", "Clone cancelled")
    refute has_element?(view, card <> "-open")
    refute has_element?(view, card <> "-cancel")
  end

  test "Ubuntu is selectable beside the configured NixOS default and provisions its image", %{
    conn: conn,
    owner: owner,
    fixture: fixture
  } do
    ubuntu = ubuntu_image_fixture(fixture)
    previous = Application.get_env(:marshall, :default_image_id)
    Application.put_env(:marshall, :default_image_id, image_id())
    on_exit(fn -> Application.put_env(:marshall, :default_image_id, previous) end)
    {:ok, view, _} = live(signed_in(conn, owner), ~p"/machines/new")
    assert has_element?(view, "#machine_image_id option[selected][value='#{image_id()}']")

    assert has_element?(
             view,
             "#machine_image_id option[value='#{ubuntu.id}']",
             "Ubuntu 26.04 LTS"
           )

    view |> form("#provision-form", machine: %{image_id: ubuntu.id}) |> render_change()
    assert_patch(view)
    thread = submit_provisioning(view, %{})
    assert {:snooze, _} = admit(thread)
    assert [%{id: vm_id, image_id: selected}] = Ledger.read!(VirtualMachine, owner_id: owner.id)
    assert selected == ubuntu.id

    # The image's registered name is the operating-system label everywhere the
    # machine appears: detail header, Settings resources, Machines list, Overview.
    {:ok, detail, _} = live(signed_in(conn, owner), ~p"/machines/#{vm_id}")
    assert has_element?(detail, "#machine-os", "Ubuntu 26.04 LTS")
    {:ok, settings, _} = live(signed_in(conn, owner), ~p"/machines/#{vm_id}/settings")
    assert has_element?(settings, "#machine-os", "Ubuntu 26.04 LTS")
    assert has_element?(settings, "#machine-operating-system", "Ubuntu 26.04 LTS")
    {:ok, list, _} = live(signed_in(conn, owner), ~p"/machines")

    assert has_element?(
             list,
             "#machines td .machine-name + #machine-os-#{vm_id}",
             "Ubuntu 26.04 LTS"
           )

    {:ok, overview, _} = live(signed_in(conn, owner), ~p"/overview")
    assert has_element?(overview, "#overview-machine-os-#{vm_id}", "Ubuntu 26.04 LTS")
  end

  defp larger_image(fixture) do
    manifest =
      image_manifest()
      |> Map.put("minimum_memory_bytes", 805_306_369)
      |> Map.put("minimum_disk_bytes", 2_147_487_744)

    {:ok, image} = Marshall.Compute.Images.register(manifest, "zz-larger-image")

    report = %{
      fixture.report
      | sequence: 2,
        inventory: Map.put(fixture.report.inventory, "images", [image_id(), image.id])
    }

    {:ok, :ok} = Marshall.Compute.HostReports.ingest(fixture.host.id, fixture.epoch, report)
    image
  end

  test "Inception selection binds its image and defaults while retaining the request identity", %{
    conn: conn,
    owner: owner,
    fixture: fixture
  } do
    image = larger_image(fixture)
    previous = Application.get_env(:marshall, :inception_image_id)
    Application.put_env(:marshall, :inception_image_id, image.id)
    on_exit(fn -> Application.put_env(:marshall, :inception_image_id, previous) end)
    {:ok, view, _} = live(signed_in(conn, owner), ~p"/machines/new")
    assert has_element?(view, "#machine_profile option[value='inception']")
    assert has_element?(view, "#profile-help-inception", "256 GiB data disk")

    key =
      view
      |> element("#machine_request_key")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("input")
      |> LazyHTML.attribute("value")
      |> hd()

    view |> form("#provision-form", machine: %{profile: "inception"}) |> render_change()
    assert_patch(view)
    assert has_element?(view, "#inception-image-id[value='#{image.id}']")
    assert has_element?(view, "#machine_vcpu[value='16']")
    assert has_element?(view, "#machine_memory_mib[value='32768']")
    assert has_element?(view, "#machine_disk_gib[value='64']")
    assert has_element?(view, "#machine_request_key[value='#{key}']")
    assert has_element?(view, "#profile-help-inception", "higher resource minimums")
    refute has_element?(view, "select#machine_image_id")
    view |> form("#provision-form", machine: %{disk_gib: "65"}) |> render_change()
    assert_patch(view)
    send(view.pid, :refresh)
    assert has_element?(view, "#machine_disk_gib[value='65']")
    view |> form("#provision-form", machine: %{}) |> render_submit()
    assert Ledger.read!(VirtualMachine, owner_id: owner.id) == []
    assert has_element?(view, "#provision-form")
  end

  test "an unconfigured Inception image is not offered as a working profile", %{
    conn: conn,
    owner: owner
  } do
    {:ok, view, _} = live(signed_in(conn, owner), ~p"/machines/new")
    refute has_element?(view, "#machine_profile option[value='inception']")
    refute has_element?(view, "#profile-help-inception")
  end

  test "configured image supplies rounded defaults and still provisions through Ash", %{
    conn: conn,
    owner: owner,
    fixture: fixture
  } do
    image = larger_image(fixture)
    previous = Application.get_env(:marshall, :default_image_id)
    Application.put_env(:marshall, :default_image_id, image.id)
    on_exit(fn -> Application.put_env(:marshall, :default_image_id, previous) end)
    {:ok, view, _} = live(signed_in(conn, owner), ~p"/machines/new")
    assert has_element?(view, "#machine_image_id option[selected][value='#{image.id}']")
    assert has_element?(view, "#machine_memory_mib[value='769']")
    assert has_element?(view, "#machine_disk_gib[value='3']")
    thread = submit_provisioning(view, %{})
    assert {:snooze, _} = admit(thread)

    assert [
             %{
               image_id: id,
               profile: :standard,
               memory_bytes: 806_354_944,
               disk_bytes: 3_221_225_472
             }
           ] =
             Ledger.read!(VirtualMachine, owner_id: owner.id)

    assert id == image.id
  end

  # @cc [owner:ghuntley,label:verification;product] creation-draft-image-change-resets-sizes
  # Changing the image in the creation form MUST reset the size fields to the
  # selected image's rounded minima, including a size the user edited for the
  # previous image, while the profile and request identity stay untouched.
  test "an image change resets the size defaults to the selected image's minima", %{
    conn: conn,
    owner: owner,
    fixture: fixture
  } do
    larger = larger_image(fixture)
    previous = Application.get_env(:marshall, :default_image_id)
    Application.put_env(:marshall, :default_image_id, image_id())
    on_exit(fn -> Application.put_env(:marshall, :default_image_id, previous) end)
    {:ok, view, _} = live(signed_in(conn, owner), ~p"/machines/new")
    assert has_element?(view, "#machine_image_id option[selected][value='#{image_id()}']")
    refute has_element?(view, "#machine_memory_mib[value='769']")

    view |> form("#provision-form", machine: %{image_id: larger.id}) |> render_change()
    assert_patch(view)
    assert has_element?(view, "#machine_memory_mib[value='769']")
    assert has_element?(view, "#machine_disk_gib[value='3']")

    # A size edit survives further validation of the same image...
    view |> form("#provision-form", machine: %{disk_gib: "7"}) |> render_change()
    assert_patch(view)
    assert has_element?(view, "#machine_disk_gib[value='7']")
    assert has_element?(view, "#machine_memory_mib[value='769']")

    # ...and is reset with the memory default when the image changes again.
    view |> form("#provision-form", machine: %{image_id: image_id()}) |> render_change()
    assert_patch(view)
    refute has_element?(view, "#machine_disk_gib[value='7']")
    refute has_element?(view, "#machine_memory_mib[value='769']")
    assert has_element?(view, "#machine_profile option[selected][value='standard']")
  end

  # @cc [owner:ghuntley,label:verification;product] provision-form-image-minimum-refusal-evidence
  # A submitted size below the selected image's minima MUST render the localized
  # refusal on the retained form and create no thread and no machine; the same
  # form with sizes at the minima MUST still provision through the setup thread,
  # and the worker MUST still refuse an undersized thread created directly.
  test "explicit undersized drafts remain unchanged and Ash rejects admission", %{
    conn: conn,
    owner: owner,
    fixture: fixture
  } do
    image = larger_image(fixture)
    draft = %{image_id: image.id, memory_mib: "512", disk_gib: "2"}
    {:ok, view, _} = live(signed_in(conn, owner), ~p"/machines/new?#{%{machine: draft}}")
    assert has_element?(view, "#machine_memory_mib[value='512']")
    assert has_element?(view, "#machine_disk_gib[value='2']")
    view |> form("#provision-form", machine: %{}) |> render_submit()

    assert has_element?(
             view,
             "#provision-form #provision-error[role=alert]",
             "The selected image needs more memory or disk space."
           )

    assert has_element?(view, "#machine_memory_mib[value='512']")
    assert has_element?(view, "#machine_disk_gib[value='2']")
    assert Ledger.read!(Thread, creator_id: owner.id) == []
    assert Ledger.read!(VirtualMachine, owner_id: owner.id) == []

    # Editing the draft clears the refusal; sizes at the image minima provision.
    view
    |> form("#provision-form", machine: %{memory_mib: "769", disk_gib: "3"})
    |> render_change()

    assert_patch(view)
    refute has_element?(view, "#provision-error")
    thread = submit_provisioning(view, %{})
    assert {:snooze, _} = admit(thread)

    assert [%{image_id: id, memory_bytes: 806_354_944, disk_bytes: 3_221_225_472}] =
             Ledger.read!(VirtualMachine, owner_id: owner.id)

    assert id == image.id

    # The worker keeps its transactional refusal for a thread that bypasses the form.
    {:ok, bypass} =
      Marshall.Threads.create_thread(
        %{
          objective: "Check the undersized refusal",
          mode: :medium,
          collaboration_mode: :work,
          idempotency_key: Ash.UUID.generate(),
          machine_spec: %{
            architecture: :x86_64,
            image_id: image.id,
            profile: "standard",
            team_id: nil,
            vcpu: 1,
            memory_bytes: 536_870_912,
            disk_bytes: 2_147_483_648
          }
        },
        actor: owner
      )

    assert {:error, _} = admit(bypass)
    assert [%{status: :failed, machine_id: nil}] = Ledger.read!(Thread, id: bypass.id)
    assert [%{image_id: ^id}] = Ledger.read!(VirtualMachine, owner_id: owner.id)
  end

  test "machine routes require sign in", %{conn: conn} do
    for route <- [~p"/machines", ~p"/machines/new"] do
      assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, route)
    end
  end

  test "machine list exposes terminal and VS Code actions for an eligible owner", %{conn: conn} do
    put_editor_release()
    fixture = EditorFixture.new()
    machine_id = fixture.vm.id

    {:ok, view, _} = live(signed_in(conn, fixture.owner), ~p"/machines")

    assert has_element?(view, "th", "Connect")

    assert has_element?(
             view,
             "#machine-terminal-#{machine_id}[href='/machines/#{machine_id}/terminals']"
           )

    assert has_element?(
             view,
             "#machine-#{machine_id}-vscode.console-button[href='/machines/#{machine_id}/code'][target='_blank'][rel='noopener noreferrer']",
             "Open VS Code"
           )

    refute has_element?(view, "#machine-#{machine_id}-vscode-disabled")
  end

  test "machine list hides VS Code from a viewer", %{conn: conn} do
    put_editor_release()
    fixture = EditorFixture.new()
    viewer = user()
    assert {:ok, _} = Marshall.TerminalFixtures.grant(fixture, viewer, :viewer)

    {:ok, view, _} = live(signed_in(conn, viewer), ~p"/machines")

    assert has_element?(view, "#machines-#{fixture.vm.id}")
    refute has_element?(view, "#machine-#{fixture.vm.id}-vscode")
    refute has_element?(view, "#machine-#{fixture.vm.id}-vscode-disabled")
  end

  test "machine list disables VS Code with stopped and unavailable reasons", %{conn: conn} do
    put_editor_release()
    fixture = EditorFixture.new()
    machine_id = fixture.vm.id
    {:ok, view, _} = live(signed_in(conn, fixture.owner), ~p"/machines")

    Ledger.intent!(fixture.vm, %{desired_state: :stopped, generation: fixture.vm.generation + 1})
    send(view.pid, :refresh)
    assert has_element?(view, "#machine-#{machine_id}-vscode-disabled[disabled]")

    assert has_element?(
             view,
             "#machine-#{machine_id}-vscode-reason",
             "requires a running machine"
           )

    Application.delete_env(:marshall, :ingress_editor_releases)
    send(view.pid, :refresh)
    assert has_element?(view, "#machine-#{machine_id}-vscode-disabled[disabled]")
    assert has_element?(view, "#machine-#{machine_id}-vscode-reason", "temporarily unavailable")
  end

  test "machine list explains unsupported images without an editor link", %{conn: conn} do
    put_editor_release()
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    machine_id = fixture.vm.id
    {:ok, view, _} = live(signed_in(conn, fixture.owner), ~p"/machines")

    refute has_element?(view, "#machine-#{machine_id}-vscode")
    assert has_element?(view, "#machine-#{machine_id}-vscode-disabled[disabled]")

    assert has_element?(
             view,
             "#machine-#{machine_id}-vscode-reason",
             "does not support the current browser editor"
           )

    refute has_element?(view, "#machine-#{machine_id}-vscode-reason", "new machine")
  end

  test "current headroom distinguishes unknown telemetry from measured zero", %{
    conn: conn,
    owner: owner,
    fixture: c
  } do
    conn = signed_in(conn, owner)
    {:ok, view, _} = live(conn, ~p"/machines")
    assert has_element?(view, "#available-capacity", "Current headroom")
    Ledger.update!(c.host, :report, %{capacity: nil})
    send(view.pid, :refresh)
    assert has_element?(view, "#available-capacity", "temporarily unavailable")
    Ledger.update!(c.host, :report, %{capacity: capacity(0, 0)})
    send(view.pid, :refresh)
    assert has_element?(view, "#available-capacity", "0 vCPU")
    refute has_element?(view, "#available-capacity", "temporarily unavailable")
  end

  test "signed-in user can provision and request lifecycle changes", %{
    conn: conn,
    owner: owner,
    fixture: fixture
  } do
    conn = signed_in(conn, owner)
    {:ok, view, _} = live(conn, ~p"/machines")
    assert has_element?(view, "#available-capacity")
    assert has_element?(view, "#machines-empty")
    refute has_element?(view, "#provision-form")
    assert has_element?(view, "#create-machine[href='/machines/new']")
    {:ok, view, _} = live(conn, ~p"/machines/new")
    assert has_element?(view, "#provision-submit:not([disabled])")

    thread =
      submit_provisioning(view, %{
        image_id: image_id(),
        profile: "standard",
        vcpu: "1",
        memory_mib: "512",
        disk_gib: "2"
      })

    {:ok, receipt, _} = live(conn, ~p"/machines/provisioning/#{thread.id}")
    assert has_element?(receipt, "#machine-provisioning")
    assert {:snooze, _} = admit(thread)
    [vm] = Ledger.read!(VirtualMachine, owner_id: owner.id)
    assert vm.profile == :standard
    vm_path = ~p"/machines/#{vm.id}"

    assert {:error, {:live_redirect, %{to: ^vm_path}}} =
             live(conn, ~p"/machines/provisioning/#{thread.id}")

    {:ok, detail, _} = live(conn, ~p"/machines/#{vm.id}/settings")
    assert has_element?(detail, "#machine-detail")
    assert has_element?(detail, "#machine-detail h1", vm.name)
    assert has_element?(detail, "#machine-host", fixture.host.name)
    refute has_element?(detail, "#sharing-form")
    detail |> element("#stop-machine") |> render_click()
    assert [%{desired_state: :stopped}] = Ledger.read!(VirtualMachine, id: vm.id)
    assert has_element?(detail, "#start-machine")
  end

  test "team selection provisions a machine visible in bounded lists to current members", %{
    conn: conn,
    owner: owner
  } do
    member = user()

    {:ok, team} =
      Teams.create_team(
        %{
          name: "web-team-" <> binary_part(Ash.UUID.generate(), 0, 8),
          idempotency_key: Ash.UUID.generate()
        },
        actor: owner
      )

    assert {:ok, _} =
             Teams.set_team_member(
               %{
                 team_id: team.id,
                 email: to_string(member.email),
                 role: :member,
                 idempotency_key: Ash.UUID.generate()
               },
               actor: owner
             )

    {:ok, view, _} = live(signed_in(conn, owner), ~p"/machines/new")
    assert has_element?(view, "#machine_team_id option[value='#{team.id}']", team.name)

    thread =
      submit_provisioning(view, %{
        image_id: image_id(),
        profile: "standard",
        team_id: team.id,
        vcpu: "1",
        memory_mib: "512",
        disk_gib: "2"
      })

    assert thread.team_id == team.id
    assert {:snooze, _} = admit(thread)
    [vm] = Ledger.read!(VirtualMachine, owner_id: owner.id)
    assert vm.team_id == team.id

    {:ok, list, _} = live(signed_in(build_conn(), member), ~p"/machines")
    assert has_element?(list, "#machines-#{vm.id}")

    {:ok, member_form, _} = live(signed_in(build_conn(), member), ~p"/machines/new")
    refute has_element?(member_form, "#machine_team_id option[value='#{team.id}']")
  end

  test "sharing is usable from the detail page and a viewer cannot forge lifecycle events", %{
    conn: conn,
    owner: owner
  } do
    member = user()
    {:ok, vm} = Compute.provision(request(), actor: owner)
    {:ok, view, _} = live(signed_in(conn, owner), ~p"/machines/#{vm.id}/access")

    assert has_element?(view, "#access-people h2", "Direct machine grants")
    assert has_element?(view, "#grants-empty", "No direct machine grants")

    assert has_element?(
             view,
             "#access-people p",
             "Team membership and thread sharing can also grant machine access."
           )

    view
    |> form("#sharing-form", access: %{email: to_string(member.email), role: "viewer"})
    |> render_submit()

    {:ok, viewer, _} = live(signed_in(build_conn(), member), ~p"/machines/#{vm.id}/settings")
    assert has_element?(viewer, "#machine-host")
    refute has_element?(viewer, "#sharing-form")
    refute has_element?(viewer, "#lifecycle-actions")
    render_click(viewer, "lifecycle", %{"kind" => "delete", "key" => Ash.UUID.generate()})
    assert [%{desired_state: :running}] = Ledger.read!(VirtualMachine, id: vm.id)
    {:ok, list, _} = live(signed_in(build_conn(), member), ~p"/machines")
    assert has_element?(list, "#machines-#{vm.id}")
  end

  test "revocation affects an already connected manager before its next event", %{
    conn: conn,
    owner: owner
  } do
    manager = user()
    {:ok, vm} = Compute.provision(request(), actor: owner)

    request = %{
      vm_id: vm.id,
      email: to_string(manager.email),
      role: :manager,
      idempotency_key: Ash.UUID.generate()
    }

    assert {:ok, _} = Access.set_access(request, actor: owner)
    {:ok, view, _} = live(signed_in(conn, manager), ~p"/machines/#{vm.id}/settings")
    assert has_element?(view, "#delete-machine")

    assert {:ok, _} =
             Access.set_access(%{request | role: :revoked, idempotency_key: Ash.UUID.generate()},
               actor: owner
             )

    render_click(view, "lifecycle", %{"kind" => "delete", "key" => Ash.UUID.generate()})
    assert [%{desired_state: :running}] = Ledger.read!(VirtualMachine, id: vm.id)
    send(view.pid, :refresh)
    assert_redirect(view, ~p"/machines")
  end

  test "exhaustion refuses admission without accepting another machine", %{
    conn: conn,
    owner: owner
  } do
    for _ <- 1..2, do: assert({:ok, _} = Compute.provision(request(), actor: owner))
    conn = signed_in(conn, owner)
    {:ok, view, _} = live(conn, ~p"/machines/new")

    # Creation hands admission to the setup thread, so exhaustion is refused by
    # ProvisionWorker's admission rather than by the form. No third machine is
    # accepted and the receipt keeps offering a retry.
    thread =
      submit_provisioning(view, %{
        image_id: image_id(),
        profile: "standard",
        vcpu: "1",
        memory_mib: "512",
        disk_gib: "2"
      })

    assert {:error, :insufficient_capacity} = admit(thread)
    assert length(Ledger.read!(VirtualMachine, owner_id: owner.id)) == 2
    {:ok, receipt, _html} = live(conn, ~p"/machines/provisioning/#{thread.id}")
    assert has_element?(receipt, "#machine-provisioning")
  end

  test "login-token revocation blocks an already connected owner's lifecycle event", %{
    conn: conn,
    owner: owner
  } do
    {:ok, vm} = Compute.provision(request(), actor: owner)
    conn = signed_in(conn, owner)
    token = get_session(conn, "user_token")
    {:ok, view, _} = live(conn, ~p"/machines/#{vm.id}/settings")
    :ok = AshAuthentication.TokenResource.Actions.revoke(Marshall.Accounts.Token, token)
    render_click(view, "lifecycle", %{"kind" => "delete", "key" => Ash.UUID.generate()})
    assert_redirect(view, "/sign-in")
    assert [%{desired_state: :running}] = Ledger.read!(VirtualMachine, id: vm.id)
  end

  test "creation draft survives invalid input, polling and reload with the same request identity",
       %{conn: conn, owner: owner} do
    conn = signed_in(conn, owner)
    {:ok, view, _} = live(conn, ~p"/machines/new")

    key =
      view
      |> element("#machine_request_key")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("input")
      |> LazyHTML.attribute("value")
      |> hd()

    values = %{image_id: image_id(), profile: "oss", vcpu: "3", memory_mib: "768", disk_gib: "4"}
    view |> form("#provision-form", machine: values) |> render_change()
    url = assert_patch(view)
    assert Plug.Conn.Query.decode(URI.parse(url).query)["machine"]["request_key"] == key
    send(view.pid, :refresh)
    assert has_element?(view, "#machine_memory_mib[value='768']")

    render_submit(view, "provision", %{
      "machine" =>
        Map.new(values, fn {k, v} -> {Atom.to_string(k), v} end)
        |> Map.merge(%{"vcpu" => "invalid", "request_key" => key})
    })

    assert has_element?(view, "#machine_vcpu[value='invalid']")
    assert has_element?(view, "#machine_request_key[value='#{key}']")
    {:ok, reloaded, _} = live(conn, url)
    assert has_element?(reloaded, "#machine_memory_mib[value='768']")
    assert has_element?(reloaded, "#machine_request_key[value='#{key}']")
    assert Ledger.read!(VirtualMachine, owner_id: owner.id) == []
  end

  test "creation shows unavailable images and recovers on refresh", %{
    conn: conn,
    owner: owner,
    fixture: fixture
  } do
    host = Ledger.update!(fixture.host, :configure, %{enabled: false})
    {:ok, view, _} = live(signed_in(conn, owner), ~p"/machines/new")
    assert has_element?(view, "#no-ready-images")
    assert has_element?(view, "#provision-submit[disabled]")
    Ledger.update!(host, :configure, %{enabled: true})
    send(view.pid, :refresh)
    assert has_element?(view, "#provision-submit:not([disabled])")
  end

  test "creation events honor login revocation", %{conn: conn, owner: owner} do
    conn = signed_in(conn, owner)
    {:ok, view, _} = live(conn, ~p"/machines/new")

    :ok =
      AshAuthentication.TokenResource.Actions.revoke(
        Marshall.Accounts.Token,
        get_session(conn, "user_token")
      )

    render_change(view, "validate", %{"machine" => %{"vcpu" => "2"}})
    assert_redirect(view, "/sign-in")
    assert Ledger.read!(VirtualMachine, owner_id: owner.id) == []
  end

  test "manager can request and cancel relocation while status exposes durable phases", %{
    conn: conn,
    owner: owner
  } do
    {:ok, vm} = Compute.provision(request(), actor: owner)
    [operation] = Ledger.read!(Marshall.Compute.Operation, vm_id: vm.id)
    Ledger.update!(operation, :complete, %{})
    Ledger.update!(vm, :observe, %{observed_state: :running})
    host_fixture()
    {:ok, view, _} = live(signed_in(conn, owner), ~p"/machines/#{vm.id}/settings")
    assert has_element?(view, "#relocate-machine")
    assert has_element?(view, "#relocation-network-note", "1 Gbit/s")
    view |> element("#relocate-machine") |> render_click()
    [relocation] = Ledger.read!(Marshall.Compute.Relocation, vm_id: vm.id)
    assert has_element?(view, "#relocation-status")
    assert has_element?(view, "#relocation-phase", "Preparing transfer")
    refute has_element?(view, "#relocate-machine")
    assert has_element?(view, "#cancel-relocation")
    refute has_element?(view, "#relocation-downtime")

    send(view.pid, :refresh)
    refute has_element?(view, "#relocation-progress")
    assert {:ok, detail} = Compute.get_vm(%{vm_id: vm.id}, actor: owner)

    assert Enum.sort(Map.keys(detail.relocation)) ==
             Enum.sort([
               :id,
               :phase,
               :active,
               :cancellable,
               :retryable,
               :downtime
             ])

    view |> element("#cancel-relocation") |> render_click()
    assert has_element?(view, "#relocation-phase", "Cancelling and restoring the source")
    refute has_element?(view, "#cancel-relocation")
    [cancelled] = Ledger.read!(Marshall.Compute.Relocation, id: relocation.id)
    assert cancelled.cancellation_requested_at != nil
    assert cancelled.finished_at == nil
  end

  test "revoked manager cannot request relocation from a stale page", %{conn: conn, owner: owner} do
    {:ok, vm} = Compute.provision(request(), actor: owner)
    manager = user()

    grant = %{
      vm_id: vm.id,
      email: to_string(manager.email),
      role: :manager,
      idempotency_key: Ash.UUID.generate()
    }

    assert {:ok, _} = Access.set_access(grant, actor: owner)
    {:ok, view, _} = live(signed_in(conn, manager), ~p"/machines/#{vm.id}/settings")
    assert has_element?(view, "#relocate-machine")
    assert has_element?(view, "#relocation-network-note", "1 Gbit/s")

    assert {:ok, _} =
             Access.set_access(%{grant | role: :viewer, idempotency_key: Ash.UUID.generate()},
               actor: owner
             )

    render_click(view, "relocate", %{})
    assert Ledger.read!(Marshall.Compute.Relocation, vm_id: vm.id) == []
    send(view.pid, :refresh)
    refute has_element?(view, "#relocation-controls")
    assert {:ok, %{relocation: nil}} = Compute.get_vm(%{vm_id: vm.id}, actor: manager)
  end

  @spec drain_page_refreshes() :: :ok
  # Machine creation hands admission to a durable setup thread: the form
  # navigates to the provisioning receipt and ProvisionWorker admits the VM.
  @spec submit_provisioning(Phoenix.LiveViewTest.View.t(), map()) :: Thread.t()
  defp submit_provisioning(view, params) do
    view |> form("#provision-form", machine: params) |> render_submit()
    {"/machines/provisioning/" <> thread_id, _flash} = assert_redirect(view)
    [thread] = Ledger.read!(Thread, id: thread_id)
    thread
  end

  @spec admit(Thread.t()) :: :ok | {:snooze, pos_integer()} | {:error, term()}
  defp admit(thread) do
    Oban.Testing.perform_job(
      ProvisionWorker,
      %{"thread_id" => thread.id, "machine_key" => thread.machine_key},
      repo: Marshall.Repo
    )
  end

  defp drain_page_refreshes do
    receive do
      {:page_refresh, _} -> drain_page_refreshes()
    after
      0 -> :ok
    end
  end

  defp signed_in(conn, user) do
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(user)
    user = Ash.Resource.put_metadata(user, :token, token)
    conn |> init_test_session(%{}) |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  # Sign in with the actor's existing login token so a verified session keeps
  # its recorded elevation instead of minting a fresh unverified login.
  defp signed_in_current(conn, user) do
    {:ok, token, _} =
      if user.__metadata__[:token],
        do: {:ok, user.__metadata__.token, %{}},
        else: AshAuthentication.Jwt.token_for_user(user)

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

  defp power_key(view, id) do
    view
    |> element(id)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[phx-value-key]")
    |> LazyHTML.attribute("phx-value-key")
    |> hd()
  end

  defp dispatch_count do
    length(
      Oban.Testing.all_enqueued(repo: Marshall.Repo, worker: Marshall.Compute.Workers.Dispatch)
    )
  end

  defp redirect_location({:live_redirect, %{to: to}}), do: to
  defp redirect_location({:redirect, %{to: to}}), do: to

  defp redirect_flash({_kind, options}) when is_map(options),
    do: Map.get(options, :flash) || %{}

  # @cc [owner:ghuntley,label:product;verification] machines-status-label-severity
  # The list and header status labels MUST name each state in text and carry
  # the observed `data-state` plus a `data-tone` severity: Failed/danger,
  # Running/success, Starting and Stopping/pending, and Stopped with no tone.
  test "status labels name the state in text and carry its severity tone", %{
    conn: conn,
    owner: owner
  } do
    for _ <- 1..2, do: host_fixture()
    {:ok, failed} = Compute.provision(request(), actor: owner)

    Ledger.update!(failed, :observe, %{observed_state: :failed, failure_reason: :execution_failed})

    {:ok, running} = Compute.provision(request(), actor: owner)
    Ledger.update!(running, :observe, %{observed_state: :running})
    {:ok, stopping} = Compute.provision(request(), actor: owner)
    stopping = Ledger.update!(stopping, :observe, %{observed_state: :running})
    Ledger.intent!(stopping, %{desired_state: :stopped, generation: stopping.generation + 1})
    {:ok, stopped} = Compute.provision(request(), actor: owner)

    stopped =
      Ledger.intent!(stopped, %{desired_state: :stopped, generation: stopped.generation + 1})

    Ledger.update!(stopped, :observe, %{observed_state: :stopped})
    # A fresh provision is observed pending while its desired state is running.
    {:ok, starting} = Compute.provision(request(), actor: owner)

    {:ok, view, _} = live(signed_in(conn, owner), ~p"/machines")
    label = fn vm -> "#machines tr#machines-#{vm.id} td[data-label=Status] .status-label" end

    assert has_element?(view, label.(failed) <> "[data-state=failed][data-tone=danger]", "Failed")

    assert has_element?(
             view,
             label.(running) <> "[data-state=running][data-tone=success]",
             "Running"
           )

    assert has_element?(
             view,
             label.(stopping) <> "[data-state=running][data-tone=pending]",
             "Stopping"
           )

    assert has_element?(
             view,
             label.(starting) <> "[data-state=pending][data-tone=pending]",
             "Starting"
           )

    assert has_element?(
             view,
             label.(stopped) <> "[data-state=stopped]:not([data-tone])",
             "Stopped"
           )

    {:ok, view, _} = live(signed_in(conn, owner), ~p"/machines/#{failed.id}")
    assert has_element?(view, "#machine-state[data-state=failed][data-tone=danger]", "Failed")
    assert has_element?(view, ".machine-title h1 + #machine-os[data-tone=muted] + #machine-state")
  end

  # The default fixture host reports only the Linux image on a 10 GiB pool; a
  # Windows image needs its own inventory entry and a pool above its 32 GiB
  # minimum disk before admission can place it.
  @windows_pool_bytes 68_719_476_736
  @spec report_windows_capacity(map(), String.t()) :: :ok
  defp report_windows_capacity(fixture, image_id) do
    [pool_report] = fixture.report.pools
    [pool] = Ledger.read!(Marshall.Compute.StoragePool, id: fixture.pool.id)

    report = %{
      fixture.report
      | sequence: fixture.report.sequence + 1,
        sampled_at: Ledger.now(),
        inventory: Map.update!(fixture.report.inventory, "images", &Enum.uniq([image_id | &1])),
        pools: [
          %{
            pool_report
            | total_bytes: @windows_pool_bytes,
              free_bytes: @windows_pool_bytes,
              storage: storage_observation(pool, @windows_pool_bytes, @windows_pool_bytes)
          }
        ]
    }

    {:ok, :ok} = Marshall.Compute.HostReports.ingest(fixture.host.id, fixture.epoch, report)
    :ok
  end
end
