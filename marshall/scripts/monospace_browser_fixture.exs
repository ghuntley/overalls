defmodule Marshall.MonospaceBrowserFixture do
  @moduledoc "Isolated, disposable data for the Monospace Web presentation browser checks."
  alias Marshall.Compute.Ledger

  # @cc [owner:ghuntley,label:security;verification] redesign-fixture-isolation
  # This fixture MUST run in its dedicated test partition and shared sandbox.
  # Login links MUST only be written to an exclusive owner-readable context file.
  # Synthetic machine state MUST NOT be presented as guest execution evidence.
  @spec run() :: :ok
  def run do
    unless Mix.env() == :test and System.get_env("MIX_TEST_PARTITION") == "monospace_browser",
      do: raise("redesign fixture requires its dedicated test partition")

    port = String.to_integer(System.fetch_env!("MONOSPACE_BROWSER_PORT"))
    output = System.fetch_env!("MONOSPACE_BROWSER_CONTEXT")
    config = Application.fetch_env!(:marshall, MarshallWeb.Endpoint)

    Application.put_env(
      :marshall,
      MarshallWeb.Endpoint,
      config
      |> Keyword.put(:server, true)
      |> Keyword.put(:http, ip: {127, 0, 0, 1}, port: port)
      |> Keyword.put(:url, host: "localhost", scheme: "http", port: port)
    )

    {:ok, _} = Application.ensure_all_started(:marshall)
    Logger.configure(level: :warning)
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Marshall.Repo, ownership_timeout: :infinity)
    Ecto.Adapters.SQL.Sandbox.mode(Marshall.Repo, {:shared, self()})

    bootstrap = Ledger.lock!(Marshall.Accounts.AdminBootstrap, "installation")
    Ledger.update!(bootstrap, :complete, %{})
    Application.put_env(:marshall, :ingress_editor_releases, Marshall.EditorFixture.releases())
    fixture = Marshall.EditorFixture.new()
    owner = Ash.Seed.update!(fixture.owner, %{email: "hana@example.test"})
    vm = Ash.Seed.update!(fixture.vm, %{name: "sakura-workshop"})

    admin =
      Ash.Seed.seed!(Marshall.Accounts.User, %{email: "yuki@example.test", administrator: true})

    empty = Ash.Seed.seed!(Marshall.Accounts.User, %{email: "momo@example.test"})
    viewer = Ash.Seed.seed!(Marshall.Accounts.User, %{email: "aoi@example.test"})
    operator = Ash.Seed.seed!(Marshall.Accounts.User, %{email: "ren@example.test"})
    manager = Ash.Seed.seed!(Marshall.Accounts.User, %{email: "sora@example.test"})
    {:ok, second} = Marshall.Compute.provision(Marshall.ComputeFixtures.request(), actor: owner)
    Ash.Seed.update!(second, %{name: "tiny-moon"})
    # A second listed machine (tiny-moon is archived below) for the pin-order probe.
    Marshall.ComputeFixtures.host_fixture()
    {:ok, third} = Marshall.Compute.provision(Marshall.ComputeFixtures.request(), actor: owner)
    Ash.Seed.update!(third, %{name: "paper-lantern"})

    # Settled failed and stopped machines so the lists render every status
    # label severity. These observations are seeded, not provisioner outcomes.
    Marshall.ComputeFixtures.host_fixture()
    {:ok, failed} = Marshall.Compute.provision(Marshall.ComputeFixtures.request(), actor: owner)
    Ash.Seed.update!(failed, %{name: "ember-kiln"})

    Ledger.update!(failed, :observe, %{
      observed_state: :failed,
      failure_reason: :execution_failed,
      observed_at: Ledger.now()
    })

    Marshall.ComputeFixtures.host_fixture()
    {:ok, stopped} = Marshall.Compute.provision(Marshall.ComputeFixtures.request(), actor: owner)
    Ash.Seed.update!(stopped, %{name: "quiet-harbour"})

    stopped =
      Ledger.intent!(stopped, %{desired_state: :stopped, generation: stopped.generation + 1})

    Ledger.update!(stopped, :observe, %{observed_state: :stopped, observed_at: Ledger.now()})

    {:ok, _} =
      Marshall.Teams.create_team(%{name: "little-workshop", idempotency_key: Ash.UUID.generate()},
        actor: owner
      )

    # One registered key so the account page's SSH section renders a key article.
    {:ok, _} =
      Marshall.SSH.add_key(
        %{public_key: Marshall.SharingSurfacesFixture.key_text(), label: "hana-laptop"},
        actor: owner
      )

    Ledger.create!(Marshall.Inference.Daily, :record, %{
      owner_id: owner.id,
      day: DateTime.to_date(Ledger.now()),
      provider: :openai,
      model: "gpt-5.4",
      requests: 128,
      unknown_requests: 2,
      input_tokens: 48120,
      output_tokens: 12340
    })

    ready_thread =
      thread_fixture(owner, vm, :ready, "Make deployment failures easier to diagnose")

    archived_thread =
      thread_fixture(owner, second, :archived, "Update dependencies and check the release")

    pending_thread = state_fixture(owner, :pending, "Add repository search to the workspace")
    provisioning_thread = state_fixture(owner, :provisioning, "Improve the mobile navigation")
    failed_thread = state_fixture(owner, :failed, "Investigate the failed deployment")

    for thread <- [ready_thread, archived_thread, failed_thread],
        {recipient, role} <- [{viewer, :viewer}, {operator, :operator}, {manager, :manager}] do
      grant_access(owner, thread, recipient, role)
    end

    context = %{
      ready_thread_id: ready_thread.id,
      archived_thread_id: archived_thread.id,
      pending_thread_id: pending_thread.id,
      provisioning_thread_id: provisioning_thread.id,
      failed_thread_id: failed_thread.id,
      origin: "http://localhost:#{port}",
      vm_id: vm.id,
      owner: login(owner),
      admin: login(admin),
      empty: login(empty),
      viewer: login(viewer),
      operator: login(operator),
      manager: login(manager),
      owner_email: to_string(owner.email),
      viewer_email: to_string(viewer.email),
      operator_email: to_string(operator.email),
      manager_email: to_string(manager.email)
    }

    File.open!(output, [:write, :exclusive], fn file ->
      File.chmod!(output, 0o600)
      IO.binwrite(file, Jason.encode!(context))
    end)

    System.at_exit(fn _ -> File.rm(output) end)

    heartbeat(fixture.host.id, fixture.report)
  end

  # Keep the disposable inventory fresh while the browser checks editor eligibility.
  # This synthetic heartbeat is not evidence of a running guest or provisioner.
  @spec heartbeat(String.t(), Marshall.Compute.HostReports.report()) :: :ok
  defp heartbeat(host_id, report) do
    receive do
      :stop -> :ok
    after
      2_000 ->
        [host] = Ledger.read!(Marshall.Compute.Host, id: host_id)
        report = %{report | sequence: host.report_sequence + 1, sampled_at: Ledger.now()}
        {:ok, :ok} = Marshall.Compute.HostReports.ingest(host.id, host.connection_epoch, report)
        heartbeat(host_id, report)
    end
  end

  # @cc [owner:ghuntley,label:verification] thread-browser-fixture-transcript
  # Ready and archived browser fixtures MUST retain a bound, synthetic transcript
  # containing prompt, tool request, tool result and assistant events in sequence.
  # The binding MUST retain the actual machine admission key and pass public reads.
  # No browser assertion may treat these rows as observed agent or guest execution.
  @spec thread_fixture(
          Marshall.Accounts.User.t(),
          Marshall.Compute.VirtualMachine.t(),
          :ready | :archived,
          String.t()
        ) :: Marshall.Threads.Thread.t()
  defp thread_fixture(owner, vm, status, title) do
    [root] = Ledger.read!(Marshall.Agents.Root, vm_id: vm.id)
    [agent_thread] = Ledger.read!(Marshall.Agents.Thread, root_id: root.id)
    key = Ash.UUID.generate()

    thread =
      Ledger.create!(Marshall.Threads.Thread, :open, %{
        creator_id: owner.id,
        objective: title,
        mode: :medium,
        machine_spec: Marshall.ComputeFixtures.request(),
        idempotency_key: key,
        machine_key: vm.idempotency_key
      })

    thread = Ledger.update!(thread, :set_title, %{title: title})

    thread =
      Ledger.update!(thread, :bind_machine, %{
        machine_id: vm.id,
        agent_root_id: root.id,
        agent_thread_id: agent_thread.id,
        status: :ready
      })

    events = [
      {:prompt,
       %{
         "prompt" =>
           "Review the deployment workflow and make failures easier to diagnose. Keep the changes focused and run the relevant checks."
       }},
      {:turn_started, %{}},
      {:assistant,
       %{
         "text" =>
           "I will trace the deployment status updates, check how failures reach the interface, and add a clearer recovery path."
       }},
      {:tool_queued,
       %{
         "calls" => [
           %{
             "call_id" => "fixture-read",
             "tool" => "read_file",
             "arguments" => %{"path" => "/workspace/lib/deployment.ex"}
           }
         ]
       }},
      {:tool_result,
       %{
         "command_id" => Ash.UUID.generate(),
         "call_id" => "fixture-read",
         "result" => %{
           "status" => "completed",
           "contents" => "# Synthetic deployment workflow used only by the browser fixture."
         }
       }},
      {:tool_queued,
       %{
         "calls" => [
           %{
             "call_id" => "fixture-check",
             "tool" => "exec_command",
             "arguments" => %{
               "cmd" => "mix test test/deployment_test.exs",
               "workdir" => "/workspace"
             }
           }
         ]
       }},
      {:tool_result,
       %{
         "command_id" => Ash.UUID.generate(),
         "call_id" => "fixture-check",
         "result" => %{
           "status" => "completed",
           "exit_code" => 0,
           "stdout" => "Synthetic check completed. No guest command was executed.",
           "stderr" => ""
         }
       }},
      {:assistant,
       %{
         "text" =>
           "The requested changes are ready for review.\n\nDeployment failures now include the step that failed and a direct retry action. The status stays visible while the retry runs.\n\nAll checks passed in this synthetic fixture."
       }},
      {:turn_finished, %{}}
    ]

    events
    |> Enum.with_index(agent_thread.next_event_sequence)
    |> Enum.each(fn {{kind, body}, sequence} ->
      Ledger.create!(Marshall.Agents.Event, :append, %{
        thread_id: agent_thread.id,
        sequence: sequence,
        kind: kind,
        body: body
      })
    end)

    {:ok, retained_events} = Marshall.Threads.events(thread.id, owner)
    true = Enum.map(retained_events, & &1.kind) == Enum.map(events, &elem(&1, 0))

    if status == :archived do
      :ok = Ledger.archive!(vm, :archive)

      Ledger.update!(thread, :mark_archived, %{status: :archived, archived_at: DateTime.utc_now()})
    else
      thread
    end
  end

  @spec state_fixture(Marshall.Accounts.User.t(), :pending | :provisioning | :failed, String.t()) ::
          Marshall.Threads.Thread.t()
  defp state_fixture(owner, status, title) do
    key = Ash.UUID.generate()

    thread =
      Ledger.create!(Marshall.Threads.Thread, :open, %{
        creator_id: owner.id,
        objective: title,
        mode: :high,
        machine_spec: Marshall.ComputeFixtures.request(),
        idempotency_key: key,
        machine_key: key
      })

    thread = Ledger.update!(thread, :set_title, %{title: title})

    case status do
      :pending ->
        thread

      :provisioning ->
        Ledger.update!(thread, :bind_machine, %{status: :provisioning})

      :failed ->
        Ledger.update!(thread, :mark_failed, %{status: :failed, failure_reason: :provision_failed})
    end
  end

  # @cc [owner:ghuntley,label:security;verification] thread-browser-public-sharing
  # Synthetic viewer/operator/manager grants MUST use the public set_access action
  # with the actual creator actor; seed data MUST NOT bypass thread authorization.
  @spec grant_access(
          Marshall.Accounts.User.t(),
          Marshall.Threads.Thread.t(),
          Marshall.Accounts.User.t(),
          :viewer | :operator | :manager
        ) :: :ok
  defp grant_access(owner, thread, recipient, role) do
    {:ok, _change} =
      Marshall.Threads.set_access(
        %{
          thread_id: thread.id,
          email: to_string(recipient.email),
          role: role,
          idempotency_key: Ash.UUID.generate()
        },
        actor: owner
      )

    :ok
  end

  @spec login(Marshall.Accounts.User.t()) :: String.t()
  defp login(user) do
    strategy = AshAuthentication.Info.strategy!(Marshall.Accounts.User, :magic_link)
    {:ok, token} = AshAuthentication.Strategy.MagicLink.request_token_for(strategy, user)
    "/magic_link/" <> token
  end
end

Marshall.MonospaceBrowserFixture.run()
