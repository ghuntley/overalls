# @cc [owner:ghuntley,label:verification;security] mila-journey-fixture-authority
# The hermetic Mila journey fixture MAY seed only disposable ordinary users, a
# synthetic image catalog entry and a synthetic host (control session,
# headroom reports, and explicit per-machine operation completion and state
# observation standing in for the absent provisioner), and MAY
# stand in for the model's question and plan tool calls through the same
# Planning domain functions. Every tested Mila operation MUST still enter
# through Porsche SSH and Marshall's production authority. Login tokens and
# gateway credentials MUST stay in owner-private files under /run/mila-fixture.
defmodule MilaJourneyFixture do
  alias Marshall.Compute.{Host, HostReports, Images, Ledger, StoragePool}
  require Ash.Query

  @root "/run/mila-fixture"
  @owner "mila-owner@example.test"
  @member "mila-member@example.test"

  @type result :: %{optional(String.t()) => term()}

  @spec main() :: :ok
  def main do
    {:ok, _} = Application.ensure_all_started(:marshall)
    action = System.fetch_env!("MILA_FIXTURE_ACTION")
    result = run(action)
    private_write(Path.join(@root, action <> ".json"), JSON.encode!(result))
    :ok
  end

  @spec run(String.t()) :: result()
  def run("seed") do
    [bootstrap] = Ledger.read!(Marshall.Accounts.AdminBootstrap, id: "installation")
    unless bootstrap.completed, do: Ledger.update!(bootstrap, :complete, %{})
    owner = user(@owner)
    member = user(@member)
    image = image()
    {host, pool} = host()
    report!(host, pool, image.id, 1)

    {:ok, vm} =
      Marshall.Compute.provision(
        %{
          idempotency_key: "mila-journey-seed-machine",
          architecture: :x86_64,
          image_id: image.id,
          profile: :standard,
          vcpu: 1,
          memory_bytes: 536_870_912,
          disk_bytes: 2_147_483_648
        },
        actor: owner
      )

    {:ok, _} = Marshall.Operations.SSHGateway.prepare("/run/overalls-test/gateway.token")

    {:ok, _} =
      Marshall.Operations.SSHGateway.configure("mila-journey", "/run/overalls-test/gateway.token")

    %{
      "owner_id" => owner.id,
      "owner_email" => @owner,
      "member_id" => member.id,
      "member_email" => @member,
      "image_id" => image.id,
      "host_id" => host.id,
      "pool_id" => pool.id,
      "machine_id" => vm.id,
      "machine_name" => vm.name
    }
  end

  # @cc [owner:ghuntley,label:verification;capacity] mila-fixture-synthetic-host-scope
  # The synthetic host opens a control session and reports fresh headroom
  # through the same Ash resources the provisioner control channel uses, so
  # admission and placement decisions are real. It MUST NOT acknowledge
  # operations or report guest state: no guest executes in this fixture.
  def run("host") do
    seed = seed()
    [host] = Ledger.read!(Host, id: seed["host_id"])
    [pool] = Ledger.read!(StoragePool, id: seed["pool_id"])
    session = Ash.UUID.generate()

    {:ok, host} =
      Ledger.transaction(fn ->
        host = Ledger.lock!(Host, host.id)
        epoch = host.connection_epoch + 1

        Ledger.create!(Marshall.Compute.HostSession, :open, %{
          id: session,
          host_id: host.id,
          epoch: epoch
        })

        Ledger.update!(host, :connect, %{
          connection_session_id: session,
          connection_epoch: epoch,
          report_sequence: 0,
          reported_at: nil
        })
      end)

    report_loop(host, pool, seed["image_id"], 1)
  end

  # A fresh owner magic-link token for the browser approver (private file only).
  def run("login") do
    owner = Ash.get!(Marshall.Accounts.User, seed()["owner_id"], authorize?: false)
    strategy = AshAuthentication.Info.strategy!(Marshall.Accounts.User, :magic_link)
    {:ok, token} = AshAuthentication.Strategy.MagicLink.request_token_for(strategy, owner)
    %{"token" => token}
  end

  # Stand in for the absent provisioner for one machine: complete its open
  # operations and observe its desired state, so the next lifecycle intent is
  # admissible. This establishes no guest execution; it is invoked explicitly
  # by the journey after each accepted physical mutation.
  def run("observe") do
    id = System.fetch_env!("MILA_FIXTURE_MACHINE")

    {:ok, vm} =
      retrying(fn ->
        vm = Ledger.lock!(Marshall.Compute.VirtualMachine, id)

        Ledger.read!(Marshall.Compute.Operation, vm_id: id)
        |> Enum.filter(&(&1.status in [:pending, :acknowledged]))
        |> Enum.each(&Ledger.update!(&1, :complete, %{}))

        Ledger.update!(vm, :observe, %{
          observed_state: vm.desired_state,
          observed_at: Ledger.now()
        })
      end)

    %{"observed_state" => Atom.to_string(vm.observed_state)}
  end

  def run("thread-create") do
    seed = seed()
    actor = Ash.get!(Marshall.Accounts.User, seed["owner_id"], authorize?: false)
    [image] = Ledger.read!(Marshall.Compute.Image, id: seed["image_id"])

    {:ok, thread} =
      Marshall.Threads.create_thread(
        %{
          objective: "Report this machine's hostname",
          mode: :medium,
          idempotency_key: "mila-journey-thread",
          machine_spec: %{
            idempotency_key: "mila-journey-thread",
            architecture: :x86_64,
            image_id: image.id,
            profile: :standard,
            vcpu: 1,
            memory_bytes: max(536_870_912, image.minimum_memory_bytes),
            disk_bytes: max(2_147_483_648, image.minimum_disk_bytes)
          }
        },
        actor: actor
      )

    %{"thread_id" => thread.id, "status" => Atom.to_string(thread.status)}
  end

  # Observe the thread machine as running, as the synthetic host would, and
  # wait for Marshall's own provision worker to bind the agent and mark the
  # thread ready. The initial turn is queued; no executor runs it.
  def run("thread-ready") do
    id = System.fetch_env!("MILA_FIXTURE_THREAD")
    wait_ready(id, 120)
  end

  def run("thread-question") do
    seed = seed()
    actor = Ash.get!(Marshall.Accounts.User, seed["owner_id"], authorize?: false)
    [thread] = Ledger.read!(Marshall.Threads.Thread, id: System.fetch_env!("MILA_FIXTURE_THREAD"))

    {:ok, question} =
      retrying(fn ->
        agent = Ledger.lock!(Marshall.Agents.Thread, thread.agent_thread_id)
        turns = Ledger.read!(Marshall.Agents.Turn, thread_id: agent.id)
        Enum.each(turns, &settle_turn/1)

        turn =
          Ledger.create!(Marshall.Agents.Turn, :enqueue, %{
            thread_id: agent.id,
            actor_id: actor.id,
            request_key: Ash.UUID.generate(),
            ordinal: length(turns) + 1,
            prompt: "Choose the implementation approach.",
            collaboration_mode: :plan
          })

        turn = Ledger.update!(turn, :transition, %{status: :running, started_at: Ledger.now()})
        agent = Ledger.update!(agent, :set_context, %{collaboration_mode: :plan})
        agent = Ledger.update!(agent, :advance, %{active_turn_id: turn.id})

        Marshall.Agents.Planning.request_questions_locked!(agent, turn, %{
          id: "mila-question",
          arguments: %{
            "questions" => [
              %{
                "id" => "approach",
                "header" => "Approach",
                "question" => "Which approach should the plan use?",
                "options" => [
                  %{"label" => "First", "description" => "Keep the current interface."},
                  %{"label" => "Second", "description" => "Add a new interface."}
                ]
              }
            ]
          }
        })
      end)

    %{"question_id" => question.id}
  end

  def run("thread-proposal") do
    [thread] = Ledger.read!(Marshall.Threads.Thread, id: System.fetch_env!("MILA_FIXTURE_THREAD"))

    {:ok, proposal} =
      retrying(fn ->
        agent = Ledger.lock!(Marshall.Agents.Thread, thread.agent_thread_id)
        turns = Ledger.read!(Marshall.Agents.Turn, thread_id: agent.id)
        Enum.each(turns, &settle_turn/1)
        Ledger.update!(agent, :advance, %{active_turn_id: nil})
        turn = Enum.max_by(turns, & &1.ordinal)
        text = "Inspect the route, implement the change, and verify the response."

        Ledger.create!(Marshall.Agents.PlanProposal, :record, %{
          thread_id: agent.id,
          turn_id: turn.id,
          event_sequence: agent.next_event_sequence,
          text: text,
          digest: :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)
        })
      end)

    %{"plan_id" => proposal.id}
  end

  defp wait_ready(_id, 0), do: raise("thread did not become ready")

  defp wait_ready(id, attempts) do
    [thread] = Ledger.read!(Marshall.Threads.Thread, id: id)

    cond do
      thread.status == :ready ->
        %{"status" => "ready", "machine_id" => thread.machine_id}

      thread.status == :failed ->
        raise "thread provisioning failed: #{thread.failure_reason}"

      is_binary(thread.machine_id) ->
        [vm] = Ledger.read!(Marshall.Compute.VirtualMachine, id: thread.machine_id)

        if vm.desired_state == :running and vm.observed_state != :running,
          do: Ledger.update!(vm, :observe, %{observed_state: :running, observed_at: Ledger.now()})

        Process.sleep(1_000)
        wait_ready(id, attempts - 1)

      true ->
        Process.sleep(1_000)
        wait_ready(id, attempts - 1)
    end
  end

  defp settle_turn(%{status: status} = turn) when status in [:queued, :running],
    do: Ledger.update!(turn, :transition, %{status: :completed, finished_at: Ledger.now()})

  defp settle_turn(turn), do: turn

  # A stand-in transaction can deadlock with Marshall's own workers on the
  # same rows; PostgreSQL rolled it back, so retrying it is safe.
  defp retrying(fun, attempts \\ 5) do
    case Ledger.transaction(fun) do
      {:error, %Ash.Error.Unknown{} = error} when attempts > 1 ->
        if Exception.message(error) =~ "deadlock_detected" do
          Process.sleep(200)
          retrying(fun, attempts - 1)
        else
          {:error, error}
        end

      result ->
        result
    end
  end

  defp seed, do: Path.join(@root, "seed.json") |> File.read!() |> JSON.decode!()

  defp user(email) do
    query = Ash.Query.filter(Marshall.Accounts.User, email == ^email)

    case Ash.read!(query, authorize?: false) do
      [user] -> user
      [] -> Ash.Seed.seed!(Marshall.Accounts.User, %{email: email})
    end
  end

  defp image do
    artifact = %{"bytes" => 16, "sha256" => String.duplicate("a", 64)}

    {:ok, image} =
      Images.register(
        %{
          "version" => 4,
          "architecture" => "x86_64",
          "workspace_source_version" => 2,
          "git_identity_version" => 1,
          "boot_args" => "console=ttyS0",
          "kernel" => artifact,
          "initrd" => artifact,
          "rootfs" => artifact,
          "minimum_memory_bytes" => 536_870_912,
          "minimum_disk_bytes" => 2_147_483_648
        },
        "synthetic-mila-journey"
      )

    image
  end

  defp host do
    host =
      case Ledger.read!(Host, name: "mila-journey-synthetic") do
        [host] ->
          host

        [] ->
          Ledger.create!(Host, :enroll, %{
            name: "mila-journey-synthetic",
            architecture: :x86_64,
            machine_id: "sha256:" <> String.duplicate("c", 64),
            overhead_cores: 1,
            overhead_memory_bytes: 1_073_741_824,
            transfer_endpoint: %{
              "address" => "synthetic.example.test",
              "port" => 2222,
              "host_key" =>
                "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, 1::256>>)
            }
          })
      end

    pool =
      case Ledger.read!(StoragePool, host_id: host.id) do
        [pool] ->
          pool

        [] ->
          Ledger.create!(StoragePool, :enroll, %{
            host_id: host.id,
            name: "guests",
            backend: :zfs,
            zpool_guid: "1",
            dataset_guid: "2",
            dataset: "fixture/mila",
            filesystem_id: "zfs:1:2",
            overhead_bytes: 1_073_741_824
          })
      end

    Ledger.update!(host, :configure, %{enabled: true})
    {host, pool}
  end

  defp report_loop(host, pool, image_id, sequence) do
    {:ok, :ok} =
      HostReports.ingest(host.id, host.connection_epoch, report(pool, image_id, sequence))

    Process.sleep(1_000)
    report_loop(host, pool, image_id, sequence + 1)
  end

  defp report!(host, pool, image_id, sequence) do
    {:ok, epoch} = HostReports.connect(host.id)
    {:ok, :ok} = HostReports.ingest(host.id, epoch, report(pool, image_id, sequence))
  end

  defp report(pool, image_id, sequence) do
    %{
      sequence: sequence,
      sampled_at: Ledger.now(),
      effective_cores: 16,
      effective_memory_bytes: 34_359_738_368,
      inventory: %{
        "checkpoint_compatibility" => "sha256:" <> String.duplicate("a", 64),
        "architecture" => "x86_64",
        "images" => [image_id],
        "checkpoint_image_ids" => [image_id],
        "execution_ready" => true,
        "terminal_protocol" => 2,
        "inception_image_id" => nil
      },
      capacity: %{
        "version" => 1,
        "cpu_headroom_millicores" => 16_000,
        "memory_headroom_bytes" => 34_359_738_368,
        "interval_us" => 1_000_000,
        "covered" => %{}
      },
      pools: [
        %{
          id: pool.id,
          total_bytes: 1_099_511_627_776,
          free_bytes: 1_099_511_627_776,
          allocations: %{},
          checkpoint_allocations: %{},
          storage: %{
            backend: :zfs,
            zpool_guid: "1",
            dataset_guid: "2",
            dataset: "fixture/mila",
            used_bytes: 0,
            quota_bytes: 1_099_511_627_776
          }
        }
      ]
    }
  end

  defp private_write(path, data) do
    File.rm(path)
    File.write!(path, data)
    File.chmod!(path, 0o600)
  end
end

MilaJourneyFixture.main()

