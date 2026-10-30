defmodule MarshallWeb.DefaultProfileHistoryTest do
  use MarshallWeb.ConnCase, async: false
  import Hegel
  import Hegel.Gen
  import Phoenix.LiveViewTest
  import Marshall.ComputeFixtures
  alias Marshall.Compute.{Ledger, Operation, Reservation, VirtualMachine}
  alias Marshall.Threads.{ProvisionWorker, Thread}

  @typep selection :: nil | :oss | :standard

  # @cc [owner:ghuntley,label:verification;product] browser-profile-draft-oracle
  # Omitted profiles MUST start as Standard (Work). Generated explicit choices, refreshes and
  # reloads MUST preserve the last choice and request identity through admission;
  # replaying the same URL MUST create no additional VM, reservation or operation.
  @tag :hegel
  @tag :hegel_case_sandbox
  # Each case now also admits through ProvisionWorker; 100 cases measured 59.9 s
  # on a host at load ~40 (2026-10-30). Sized at about 3x that measurement.
  @tag timeout: 180_000
  test "profile drafts survive refresh and reload before duplicate submission", %{conn: conn} do
    Hegel.check(
      fn ->
        Marshall.DataCase.isolate_property_case()
        initial = draw("initial", member_of([nil, :oss, :standard]))

        changes =
          draw(
            "changes",
            list_of(member_of([:refresh, :reload, :oss, :standard]), max_length: 8)
          )

        fixture = host_fixture()
        owner = user()
        conn = signed_in(conn, owner)
        key = Ash.UUID.generate()

        values = %{
          "request_key" => key,
          "vcpu" => "1",
          "memory_mib" => "512",
          "disk_gib" => "2",
          "image_id" => image_id()
        }

        values = if initial, do: Map.put(values, "profile", Atom.to_string(initial)), else: values
        url = "/machines/new?" <> Plug.Conn.Query.encode(%{"machine" => values})
        view = draft_view(conn, url)
        expected = expected_profile(initial)
        assert has_element?(view, "#machine_profile option[selected][value='#{expected}']")
        # Form creation opens an agent thread; Customer VMs have no agent root.
        refute has_element?(view, "#machine_profile option[value='customer']")

        {view, url, expected} =
          Enum.reduce(changes ++ [:refresh, :reload], {view, url, expected}, fn
            :refresh, {view, url, expected} ->
              send(view.pid, :refresh)
              assert has_element?(view, "#machine_profile option[selected][value='#{expected}']")
              {view, url, expected}

            :reload, {view, url, expected} ->
              stop_draft_view(view.pid)
              reloaded = draft_view(conn, url)

              assert has_element?(
                       reloaded,
                       "#machine_profile option[selected][value='#{expected}']"
                     )

              {reloaded, url, expected}

            profile, {view, _url, _expected} ->
              view
              |> form("#provision-form", machine: %{profile: Atom.to_string(profile)})
              |> render_change()

              {view, assert_patch(view), Atom.to_string(profile)}
          end)

        assert has_element?(view, "#machine_request_key[value='#{key}']")
        Ledger.update!(fixture.host, :report, %{reported_at: Ledger.now()})
        # The form hands admission to a durable setup thread; ProvisionWorker
        # admits the VM with the drafted profile.
        thread = submit_provisioning(view)
        assert {:snooze, _} = admit(thread)
        assert [%{id: id, profile: profile}] = Ledger.read!(VirtualMachine, owner_id: owner.id)
        assert Atom.to_string(profile) == expected

        # Replaying the URL resolves to the same setup thread, not a new one.
        replay = draft_view(conn, url)
        assert submit_provisioning(replay).id == thread.id
        assert [%{id: ^id}] = Ledger.read!(VirtualMachine, owner_id: owner.id)
        assert [_thread] = Ledger.read!(Thread, creator_id: owner.id)
        assert length(Ledger.read!(Reservation, vm_id: id)) == 1
        assert length(Ledger.read!(Operation, vm_id: id)) == 1
      end,
      test_cases: 100
    )
  end

  # @cc [owner:ghuntley,label:verification] browser-profile-case-view-custody
  # Every mounted draft LiveView MUST stop before its generated case's SQL owner.
  # Cleanup MUST target only the captured PID, tolerate only an already stopped
  # view and retain a finite operation deadline.
  @spec draft_view(Plug.Conn.t(), String.t()) :: %Phoenix.LiveViewTest.View{}
  defp draft_view(conn, url) do
    {:ok, view, _} = live(conn, url)
    Hegel.on_cleanup(fn -> stop_draft_view(view.pid) end)
    view
  end

  @spec stop_draft_view(pid()) :: :ok
  defp stop_draft_view(pid) do
    GenServer.stop(pid, :normal, 5_000)
  catch
    :exit, {:noproc, _} -> :ok
  end

  @spec expected_profile(selection()) :: String.t()
  defp expected_profile(nil), do: "standard"
  defp expected_profile(profile), do: Atom.to_string(profile)

  @spec submit_provisioning(Phoenix.LiveViewTest.View.t()) :: Thread.t()
  defp submit_provisioning(view) do
    view |> form("#provision-form", machine: %{}) |> render_submit()
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

  @spec signed_in(Plug.Conn.t(), Marshall.Accounts.User.t()) :: Plug.Conn.t()
  defp signed_in(conn, user) do
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(user)
    user = Ash.Resource.put_metadata(user, :token, token)
    conn |> init_test_session(%{}) |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
