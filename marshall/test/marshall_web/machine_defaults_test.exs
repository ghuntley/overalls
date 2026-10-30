defmodule MarshallWeb.MachineDefaultsTest do
  use MarshallWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Marshall.ComputeFixtures
  alias Marshall.Accounts.{Security, User}
  alias Marshall.Compute.{Images, Ledger, VirtualMachine}
  alias MarshallWeb.{MachineDefaults, PendingLaunch, RepositoryLaunchController}

  setup do
    fixture = host_fixture()
    owner = user()
    %{fixture: fixture, owner: owner}
  end

  # @cc [owner:ghuntley,label:verification;product] independent-preset-journey
  # Saving any preset MUST preserve the other two presets and other accounts.
  # Fresh creation surfaces MUST seed the matching persisted values, while
  # explicit draft edits and request identities survive refresh and reload.
  test "three presets persist independently and seed their creation surfaces", c do
    other = user()

    {:ok, alternate} =
      Images.register(Map.put(image_manifest(), "boot_args", "console=ttyS0 preset"), "Preset OS")

    inventory = Map.put(c.fixture.report.inventory, "images", [image_id(), alternate.id])
    report = %{c.fixture.report | inventory: inventory, sequence: 2, sampled_at: Ledger.now()}

    assert {:ok, :ok} =
             Marshall.Compute.HostReports.ingest(c.fixture.host.id, c.fixture.epoch, report)

    conn = signed_in(c.conn, c.owner)
    {:ok, settings, _} = live(conn, ~p"/settings")
    assert has_element?(settings, "#launch_defaults_profile option[value=oss][selected]")
    assert has_element?(settings, "#machine_defaults_profile option[value=standard][selected]")
    assert has_element?(settings, "#thread_defaults_profile option[value=standard][selected]")

    for {preset, profile, cpu, memory, disk} <- [
          {"launch", "standard", "1", "1024", "4"},
          {"machine", "oss", "2", "2048", "6"},
          {"thread", "oss", "3", "3072", "8"}
        ] do
      render_submit(settings, "save_machine_defaults", %{
        "#{preset}_defaults" => %{
          "profile" => profile,
          "image_id" => if(preset == "machine", do: alternate.id, else: image_id()),
          "vcpu" => cpu,
          "memory_mib" => memory,
          "disk_gib" => disk
        }
      })

      assert has_element?(settings, "#flash-info", "Machine defaults saved.")
    end

    saved = Security.current(c.owner.id)
    assert {saved.launch_default_profile, saved.launch_default_vcpu} == {:standard, 1}
    assert {saved.machine_default_profile, saved.machine_default_vcpu} == {:oss, 2}
    assert {saved.thread_default_profile, saved.thread_default_vcpu} == {:oss, 3}
    assert Security.current(other.id).machine_default_image_id == nil
    {:ok, reloaded, _} = live(conn, ~p"/settings")
    assert has_element?(reloaded, "#thread_defaults_disk_gib[value='8']")

    {:ok, machine, _} = live(conn, ~p"/machines/new")
    assert has_element?(machine, "#machine_profile option[value=oss][selected]")
    assert has_element?(machine, "#machine_image_id option[value='#{alternate.id}'][selected]")
    assert has_element?(machine, "#machine_vcpu[value='2']")
    assert has_element?(machine, "#machine_memory_mib[value='2048']")
    assert has_element?(machine, "#machine_disk_gib[value='6']")

    machine
    |> form("#provision-form", machine: %{vcpu: "4", profile: "standard"})
    |> render_change()

    path = assert_patch(machine)
    send(machine.pid, :refresh)
    assert has_element?(machine, "#machine_vcpu[value='4']")
    {:ok, draft, _} = live(conn, path)
    assert has_element?(draft, "#machine_vcpu[value='4']")
    assert has_element?(draft, "#machine_profile option[value=standard][selected]")
    assert Security.current(c.owner.id).machine_default_profile == :oss

    {:ok, thread, _} = live(conn, ~p"/threads/new")
    assert has_element?(thread, "#thread_profile option[value=oss][selected]")
    assert has_element?(thread, "#thread_vcpu[value='3']")
    assert has_element?(thread, "#thread_memory_mib[value='3072']")
    assert has_element?(thread, "#thread_disk_gib[value='8']")
    assert has_element?(thread, "#thread_collaboration_mode option[value=work][selected]")

    thread
    |> form("#new-thread-form", thread: %{vcpu: "4", objective: "Keep this draft"})
    |> render_change()

    send(thread.pid, :refresh_threads)
    assert has_element?(thread, "#thread_vcpu[value='4']")
    assert has_element?(thread, "#thread_objective", "Keep this draft")
  end

  test "settings reject invalid defaults and revoked logins without changing any preset", c do
    conn = signed_in(c.conn, c.owner)
    {:ok, view, _} = live(conn, ~p"/settings")
    before = Security.current(c.owner.id)

    for values <- [
          %{profile: :customer},
          %{image_id: "missing"},
          %{vcpu: 33},
          %{memory_bytes: 1},
          %{disk_bytes: 1},
          %{memory_bytes: 536_870_913},
          %{user_id: user().id}
        ] do
      assert {:error, _} = save(bound_actor(conn, c.owner), Map.merge(valid_defaults(), values))

      assert Security.current(c.owner.id).machine_default_image_id ==
               before.machine_default_image_id
    end

    actor = bound_actor(conn, c.owner)

    assert {:error, _} =
             c.owner
             |> Ash.Changeset.for_update(:store_machine_defaults, %{machine_default_vcpu: 2},
               actor: actor
             )
             |> Ash.update()

    :ok =
      AshAuthentication.TokenResource.Actions.revoke(
        Marshall.Accounts.Token,
        get_session(conn, "user_token")
      )

    assert {:error, _} = save(actor, valid_defaults())

    render_submit(view, "save_machine_defaults", %{
      "machine_defaults" => %{
        "profile" => "oss",
        "image_id" => image_id(),
        "vcpu" => "1",
        "memory_mib" => "512",
        "disk_gib" => "2"
      }
    })

    assert_redirect(view, ~p"/sign-in")
    assert Security.current(c.owner.id).machine_default_image_id == nil
  end

  test "disabled and source-incapable saved images fall back without accepting invalid saves",
       c do
    {:ok, unsupported} = Images.register(windows_image_manifest(), "No workspace")

    {:ok, disabled} =
      Images.register(
        Map.put(image_manifest(), "boot_args", "console=ttyS0 disabled"),
        "Disabled"
      )

    Ledger.update!(disabled, :configure, %{enabled: false})
    actor = bound_actor(signed_in(c.conn, c.owner), c.owner)
    assert {:error, _} = save(actor, Map.put(valid_defaults(), :image_id, disabled.id))

    assert {:error, _} =
             save(
               actor,
               Map.merge(valid_defaults(), %{
                 preset: :launch,
                 image_id: unsupported.id,
                 memory_bytes: 2_147_483_648,
                 disk_bytes: 34_359_738_368
               })
             )

    user =
      Ash.Seed.update!(c.owner, %{
        launch_default_image_id: unsupported.id,
        machine_default_image_id: disabled.id,
        machine_default_memory_bytes: 1
      })

    {:ok, catalog} = Marshall.Compute.catalog(%{}, actor: c.owner)
    assert MachineDefaults.for_user(user, :machine, catalog.images)["image_id"] == image_id()
    assert MachineDefaults.for_user(user, :machine, catalog.images)["memory_mib"] == "512"

    assert MachineDefaults.for_user(user, :launch, catalog.images, source_required?: true)[
             "image_id"
           ] == image_id()
  end

  test "launch uses its saved profile and sizes and replay keeps the original request", c do
    owner =
      Ash.Seed.update!(c.owner, %{
        launch_default_profile: :standard,
        launch_default_image_id: image_id(),
        launch_default_vcpu: 1,
        launch_default_memory_bytes: 1_073_741_824,
        launch_default_disk_bytes: 4_294_967_296
      })

    conn = signed_in(c.conn, owner)
    visit = String.duplicate("ab", 16)

    staged =
      conn
      |> fetch_session()
      |> RepositoryLaunchController.stage(%{
        "source" => "https://github.com/tastejs/todomvc",
        "visit" => visit
      })

    pending = get_session(staged, PendingLaunch.key())
    launch_conn = put_session(conn, PendingLaunch.key(), pending)
    {:ok, first, _} = live(launch_conn, ~p"/launch")
    assert_push_event(first, "repository-launch-complete", %{receipt: receipt}, 1_000)
    {:ok, %{vm_id: id}} = PendingLaunch.verify_receipt(receipt)
    [vm] = Ledger.read!(VirtualMachine, id: id)

    assert {vm.profile, vm.vcpu, vm.memory_bytes, vm.disk_bytes} ==
             {:standard, 1, 1_073_741_824, 4_294_967_296}

    Ash.Seed.update!(owner, %{launch_default_profile: :oss, launch_default_vcpu: 2})
    {:ok, replay, _} = live(launch_conn, ~p"/launch")
    assert_push_event(replay, "repository-launch-complete", %{receipt: replay_receipt}, 1_000)
    assert {:ok, %{vm_id: ^id}} = PendingLaunch.verify_receipt(replay_receipt)
    assert [_] = Ledger.read!(VirtualMachine, owner_id: owner.id)
    other = user()

    assert {:ok, %{request: nil}} =
             Marshall.Compute.repository_launch_request(%{idempotency_key: vm.idempotency_key},
               actor: other
             )
  end

  @spec valid_defaults() :: map()
  defp valid_defaults,
    do: %{
      preset: :machine,
      profile: :standard,
      image_id: image_id(),
      vcpu: 1,
      memory_bytes: 536_870_912,
      disk_bytes: 2_147_483_648
    }

  @spec save(User.t(), map()) :: {:ok, map()} | {:error, term()}
  defp save(actor, values),
    do:
      User
      |> Ash.ActionInput.for_action(:save_machine_defaults, values, actor: actor)
      |> Ash.run_action()

  @spec bound_actor(Plug.Conn.t(), User.t()) :: User.t()
  defp bound_actor(conn, owner) do
    {:ok, jti, _} = Marshall.Accounts.Login.verify(get_session(conn, "user_token"), owner)
    Security.bind(owner, jti)
  end

  @spec signed_in(Plug.Conn.t(), User.t()) :: Plug.Conn.t()
  defp signed_in(conn, user) do
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(user)
    user = Ash.Resource.put_metadata(user, :token, token)
    conn |> init_test_session(%{}) |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
