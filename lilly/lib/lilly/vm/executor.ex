defmodule Lilly.VM.Executor do
  @moduledoc "Translate a validated command into guarded physical work and a bounded observation."
  alias OverallsProtocol.Execution
  alias Lilly.Control.Config
  alias Lilly.Host.Pool
  alias Lilly.VM.{Disk, Driver, Jail, Observation, Spec, Unit, WorkspaceSource}
  require Lilly.Events

  @type observation :: %{
          optional(:guest_ready) => true,
          optional(:checkpoint) => OverallsProtocol.Checkpoint.t(),
          state: :running | :stopped | :paused | :deleted | :failed | :unknown,
          compute_empty: boolean(),
          disk_present: boolean(),
          cleanup_complete: boolean(),
          reason:
            :none | :execution_failed | :crashed | :cleanup_failed | :identity_mismatch | :unknown
        }
  @type result :: {:ok, observation()} | {:retry, atom()}
  @typedoc "Attempt history plus the actor's optional launch commit check (ADR-0176)."
  @type history :: %{
          required(:running_epoch) => non_neg_integer(),
          required(:running_generation) => non_neg_integer(),
          optional(:commit) => (-> :ok | {:error, :preempted})
        }
  @callback reconcile(term(), Execution.command(), history()) :: result()
  @callback terminal_options(term(), Execution.command()) :: {:ok, keyword()} | {:error, atom()}
  @optional_callbacks terminal_options: 2
  @callback boot_log(term(), Execution.command(), non_neg_integer()) ::
              {:ok, Lilly.VM.BootLog.page()} | {:error, atom()}
  @optional_callbacks boot_log: 3
  @callback open_ingress(term(), Execution.command(), map()) ::
              {:ok, :gen_tcp.socket()} | {:error, atom()}
  @optional_callbacks open_ingress: 3
  @callback bridge_ingress(
              term(),
              Execution.command(),
              map(),
              :gen_tcp.socket(),
              binary(),
              binary()
            ) ::
              :ok | {:error, atom()}
  @optional_callbacks bridge_ingress: 6

  @callback boot_proof(term(), Execution.command()) ::
              {:ok, %{pid: pos_integer(), cgroup: Path.t()}} | {:error, atom()}
  @optional_callbacks boot_proof: 2
  @callback watch_target(term(), Execution.command()) ::
              {:ok, %{pid: pos_integer(), cgroup: Path.t()}} | :error
  @optional_callbacks watch_target: 2

  # @cc [owner:ghuntley,label:concurrency;recovery] boot-proof-only-for-running-unit
  # boot_proof/2 MUST NOT take the placement lock unless the VM unit is running:
  # the actor probes every tick while a reconcile is in flight, and a lock taken
  # for a stopped unit races the launch's non-waiting acquisition and starves the
  # restart. A stopped unit is definite evidence (nothing booted); an unreadable
  # unit status is inconclusive (:execution_unavailable).
  @spec boot_proof(Config.t(), Execution.command()) ::
          {:ok, %{pid: pos_integer(), cgroup: Path.t()}} | {:error, atom()}
  def boot_proof(config, command) do
    with {:ok, spec} <- specification(command),
         pool when not is_nil(pool) <- Enum.find(config.pools, &(&1.id == command.pool_id)) do
      case Unit.status(spec) do
        {:ok, :running} ->
          Driver.boot_proof(config.execution, pool, spec,
            execution_epoch: command.execution_epoch,
            generation: command.generation
          )

        {:ok, _stopped} ->
          {:error, :not_launched}

        _ ->
          {:error, :execution_unavailable}
      end
    else
      _ -> {:error, :readiness_unconfirmed}
    end
  end

  # @cc [owner:ghuntley,label:security;isolation] watch-target-verified-vmm
  # watch_target/2 MUST return only the PID and unit cgroup of a VMM that
  # passes the full running confinement checks for this command's owned
  # specification; the native watcher then binds that PID with a pidfd and
  # re-checks cgroup membership before reporting armed.
  @spec watch_target(Config.t(), Execution.command()) ::
          {:ok, %{pid: pos_integer(), cgroup: Path.t()}} | :error
  def watch_target(config, command) do
    with {:ok, spec} <- specification(command),
         pool when not is_nil(pool) <- Enum.find(config.pools, &(&1.id == command.pool_id)) do
      Lilly.VM.Observation.vmm(config.execution, pool, spec)
    else
      _ -> :error
    end
  end

  # @cc [owner:ghuntley,label:security] executor-ingress-command-derived
  # Callers MUST retain a live ingress guardian for this exact command. The
  # socket target MUST come from the command's placement/profile/slot and trusted
  # local network configuration; a remote binding MUST NOT select physical paths.
  @spec open_ingress(Config.t(), Execution.command(), map()) ::
          {:ok, :gen_tcp.socket()} | {:error, :ingress_unavailable}
  def open_ingress(config, command, binding) do
    with true <- OverallsProtocol.IngressConnect.valid_for_profile?(binding, command.profile),
         true <-
           Enum.all?(
             [:host_id, :vm_id, :placement_id, :execution_epoch, :generation],
             &(Map.fetch!(command, &1) == Map.fetch!(binding, &1))
           ),
         true <- command.kind in [:provision, :start, :resume],
         {:ok, guest} <-
           Lilly.Network.Guest.new(command.placement_id, command.profile, command.slot) do
      Lilly.Network.Ingress.connect(config.execution.network, guest, binding)
    else
      _ -> {:error, :ingress_unavailable}
    end
  end

  # @cc [owner:ghuntley,label:security] executor-detached-ingress-command-derived
  # bridge_ingress/6 MUST apply exactly open_ingress/3's command checks and
  # derive the target only from the command, then bridge Audi's connection
  # through a detached hostd bridge (ADR-0187). Callers MUST hold a live
  # ingress guardian for this command until a bridge keeper takes over.
  @spec bridge_ingress(
          Config.t(),
          Execution.command(),
          map(),
          :gen_tcp.socket(),
          binary(),
          binary()
        ) ::
          :ok | {:error, :ingress_unavailable}
  def bridge_ingress(config, command, binding, client, key, greeting) do
    with true <- OverallsProtocol.IngressConnect.valid_for_profile?(binding, command.profile),
         true <-
           Enum.all?(
             [:host_id, :vm_id, :placement_id, :execution_epoch, :generation],
             &(Map.fetch!(command, &1) == Map.fetch!(binding, &1))
           ),
         true <- command.kind in [:provision, :start, :resume],
         {:ok, guest} <-
           Lilly.Network.Guest.new(command.placement_id, command.profile, command.slot) do
      Lilly.Network.Ingress.bridge(
        config.execution.network,
        guest,
        binding,
        client,
        key,
        greeting
      )
    else
      _ -> {:error, :ingress_unavailable}
    end
  end

  # @cc [owner:ghuntley,label:security] terminal-options-require-running-boot
  # terminal_options/2 MUST return the jailed vsock socket path bound to the
  # persisted current boot challenge only after a running VMM observation for
  # the exact current specification and only when the boot bundle declares an
  # agent set with terminal capability; callers use the result as terminal dial
  # authority and any mismatch or an agentless guest MUST deny dialing.
  @spec terminal_options(Config.t(), Execution.command()) :: {:ok, keyword()} | {:error, atom()}
  def terminal_options(config, command) do
    with {:ok, spec} <- specification(command),
         pool when not is_nil(pool) <- Enum.find(config.pools, &(&1.id == command.pool_id)),
         {:ok, capabilities} <- Driver.guest_capabilities(pool, spec),
         true <- capabilities.terminal,
         true <- Observation.running?(config.execution, pool, spec),
         expected = {command.execution_epoch, command.generation},
         {:ok, boot} <-
           Lilly.VM.Boot.current(
             Path.join(config.execution.state_dir, spec.id),
             spec.id,
             expected
           ) do
      {:ok,
       [
         vsock_path: Path.join(Jail.root(pool, spec), "v.sock"),
         boot_log_path: Unit.boot_log(config.execution, spec),
         boot_challenge: boot.boot_challenge,
         guest_identity: Lilly.VM.Boot.expectation(boot),
         placement_id: boot.placement_id,
         execution_epoch: boot.execution_epoch,
         generation: boot.generation
       ]}
    else
      _ -> {:error, :terminal_unavailable}
    end
  end

  # @cc [owner:ghuntley,label:security;recovery] boot-log-command-derived
  # Diagnostics MUST derive the private log directory only from the validated
  # command's placement and local configuration. BootLog's incarnation proof
  # MUST remain independent of image capabilities and guest readiness; its
  # adopted-generation fallback MUST use the existing full VMM observation.
  @spec boot_log(Config.t(), Execution.command(), non_neg_integer()) ::
          {:ok, Lilly.VM.BootLog.page()} | {:error, atom()}
  def boot_log(config, command, cursor) do
    with {:ok, spec} <- specification(command),
         pool when not is_nil(pool) <- Enum.find(config.pools, &(&1.id == command.pool_id)) do
      Lilly.VM.BootLog.read(
        Path.join(config.execution.state_dir, spec.id),
        spec.id,
        {command.execution_epoch, command.generation},
        cursor,
        fn -> Observation.running?(config.execution, pool, spec) end
      )
    else
      _ -> {:error, :boot_log_unavailable}
    end
  end

  # @cc [owner:ghuntley,label:recovery] unconfirmed-cleanup-retains-uncertainty
  # reconcile/3 MUST report unknown when physical stop/delete cleanup cannot be confirmed.
  # Temporary execution/storage/network lock unavailability must return retry without replacing the
  # previous durable observation.
  @spec reconcile(Config.t(), Execution.command(), history()) :: result()
  def reconcile(config, command, history) do
    with {:ok, spec} <- specification(command),
         pool when not is_nil(pool) <- Enum.find(config.pools, &(&1.id == command.pool_id)) do
      case command.kind do
        :provision ->
          start(config, pool, spec, command, history)

        :start ->
          restart(config, pool, spec, command, history)

        :pause ->
          case Driver.pause(config.execution, pool, spec,
                 execution_epoch: command.execution_epoch,
                 generation: command.generation,
                 vm_id: command.vm_id
               ) do
            {:ok, descriptor} ->
              {:ok,
               %{
                 state: :paused,
                 compute_empty: true,
                 disk_present: true,
                 cleanup_complete: false,
                 reason: :none,
                 checkpoint: descriptor
               }}

            {:error, reason}
            when reason in [:execution_unavailable, :storage_busy, :network_unavailable] ->
              {:retry, reason}

            _ ->
              unknown(:identity_mismatch)
          end

        :resume ->
          case Driver.resume(config.execution, pool, spec, command.checkpoint,
                 execution_epoch: command.execution_epoch,
                 generation: command.generation,
                 vm_id: command.vm_id,
                 commit: Map.get(history, :commit)
               ) do
            :ok ->
              case ready_or_fail(config, pool, spec, command, history) do
                {:ok, %{state: :running} = observation} ->
                  {:ok, Map.put(observation, :checkpoint, command.checkpoint)}

                other ->
                  other
              end

            {:error, reason}
            when reason in [
                   :execution_unavailable,
                   :storage_busy,
                   :network_unavailable,
                   :provisioning_busy,
                   :preempted
                 ] ->
              {:retry, reason}

            _ ->
              unknown(:identity_mismatch)
          end

        :resize ->
          source_command =
            Map.merge(
              command,
              Map.new(
                [:vcpu, :memory_bytes, :disk_bytes],
                &{&1, Map.fetch!(command.resize_from, Atom.to_string(&1))}
              )
            )

          with {:ok, source} <- specification(source_command),
               :ok <-
                 Driver.resize(config.execution, pool, source, spec,
                   execution_epoch: command.execution_epoch,
                   generation: command.generation,
                   request_id: command.resize_id,
                   vm_id: command.vm_id
                 ) do
            {:ok,
             Map.put(
               facts(:stopped, true),
               :applied_sizes,
               OverallsProtocol.Resize.sizes(command)
             )}
          else
            # A held placement or pool lock is contention, not an identity
            # conflict: retry instead of a definite unknown that fences the VM.
            {:error, reason}
            when reason in [:execution_unavailable, :storage_busy, :network_unavailable] ->
              {:retry, reason}

            _ ->
              unknown(:identity_mismatch)
          end

        :stop ->
          case Driver.stop(config.execution, pool, spec,
                 execution_epoch: command.execution_epoch,
                 generation: command.generation,
                 vm_id: command.vm_id
               ) do
            :ok ->
              stopped(pool, spec)

            {:error, reason}
            when reason in [:execution_unavailable, :storage_busy, :network_unavailable] ->
              {:retry, reason}

            _ ->
              unknown(:cleanup_failed)
          end

        :delete ->
          case Driver.delete(config.execution, pool, spec,
                 execution_epoch: command.execution_epoch,
                 generation: command.generation,
                 vm_id: command.vm_id
               ) do
            :ok ->
              {:ok, facts(:deleted, false)}

            # A held pool lock is contention after the durable deletion fence,
            # not a cleanup failure: retry without the cleanup-failed backoff.
            {:error, reason}
            when reason in [:execution_unavailable, :storage_busy, :network_unavailable] ->
              {:retry, reason}

            _ ->
              unknown(:cleanup_failed)
          end
      end
    else
      _ -> unknown(:identity_mismatch)
    end
  end

  # @cc [owner:ghuntley,label:recovery] physical-paths-use-placement
  # specification/1 MUST derive local disk, unit, network and ownership identities
  # from placement_id, while retaining the logical workload's image, shape and address slot.
  @spec specification(Execution.command()) :: {:ok, Spec.t()} | {:error, atom()}
  def specification(command) do
    command
    |> Map.take([
      :image_id,
      :pool_id,
      :profile,
      :slot,
      :vcpu,
      :memory_bytes,
      :disk_bytes,
      :workspace_source,
      :git_identity
    ])
    |> Map.put(:id, command.placement_id)
    |> Spec.new()
  end

  @doc false
  # @cc [owner:ghuntley,label:recovery] adoption-contention-does-not-replace-observation
  # A running VM's temporary VM/network lock contention MUST return retry, preserving its
  # previous durable outcome. Other adoption failures MUST withhold running and report
  # unknown identity_mismatch; neither classification may stop or restart the VMM.
  @spec adoption_failure(atom()) :: result()
  def adoption_failure(reason)
      when reason in [:execution_unavailable, :host_already_owned, :network_unavailable],
      do: {:retry, reason}

  def adoption_failure(_reason), do: unknown(:identity_mismatch)

  defp start(config, pool, spec, command, history) do
    case Unit.status(spec) do
      {:ok, :running} ->
        case Driver.adopt(config.execution, pool, spec,
               execution_epoch: command.execution_epoch,
               generation: command.generation,
               vm_id: command.vm_id
             ) do
          :ok -> ready_or_fail(config, pool, spec, command, history)
          {:error, reason} -> adoption_failure(reason)
        end

      {:ok, :stopped} ->
        image = Enum.find(config.images, &(&1.id == command.image_id))

        result =
          if not Lilly.Private.Readiness.ready?(config.execution.network) do
            {:error, :private_services_unavailable}
          else
            if image,
              do:
                Driver.start(config.execution, pool, image, spec,
                  execution_epoch: command.execution_epoch,
                  generation: command.generation,
                  vm_id: command.vm_id,
                  commit: Map.get(history, :commit)
                ),
              else: {:error, :image_unavailable}
          end

        case result do
          :ok ->
            if await_running(
                 config.execution,
                 pool,
                 spec,
                 System.monotonic_time(:millisecond) + 30_000
               ),
               do: ready_or_fail(config, pool, spec, command, history),
               else: launch_failed(config, pool, spec, command, history, :running_unconfirmed)

          {:error, :unit_state_unavailable} ->
            {:retry, :execution_unavailable}

          {:error, reason}
          when reason in [
                 :private_services_unavailable,
                 :storage_busy,
                 :provisioning_busy,
                 :execution_unavailable,
                 :host_already_owned,
                 :network_unavailable,
                 :preempted
               ] ->
            {:retry, reason}

          other ->
            launch_failed(config, pool, spec, command, history, launch_reason(other))
        end

      # Inconclusive (slow or transitional) unit observation: retry, never a
      # definite :unknown outcome that would fence the VM.
      {:error, :unit_state_unavailable} ->
        {:retry, :execution_unavailable}

      _ ->
        unknown(:unknown)
    end
  end

  defp restart(config, pool, spec, command, history) do
    case Unit.status(spec) do
      {:ok, :running} ->
        case Driver.adopt(config.execution, pool, spec,
               execution_epoch: command.execution_epoch,
               generation: command.generation,
               vm_id: command.vm_id
             ) do
          :ok -> ready_or_fail(config, pool, spec, command, history)
          {:error, reason} -> adoption_failure(reason)
        end

      {:ok, :stopped} ->
        result =
          if Lilly.Private.Readiness.ready?(config.execution.network) do
            Driver.restart(config.execution, pool, spec,
              execution_epoch: command.execution_epoch,
              generation: command.generation,
              vm_id: command.vm_id,
              commit: Map.get(history, :commit)
            )
          else
            {:error, :private_services_unavailable}
          end

        case result do
          :ok ->
            if await_running(
                 config.execution,
                 pool,
                 spec,
                 System.monotonic_time(:millisecond) + 30_000
               ),
               do: ready_or_fail(config, pool, spec, command, history),
               else: launch_failed(config, pool, spec, command, history, :running_unconfirmed)

          {:error, :unit_state_unavailable} ->
            {:retry, :execution_unavailable}

          {:error, reason}
          when reason in [
                 :private_services_unavailable,
                 :storage_busy,
                 :provisioning_busy,
                 :execution_unavailable,
                 :host_already_owned,
                 :network_unavailable,
                 :preempted
               ] ->
            {:retry, reason}

          other ->
            launch_failed(config, pool, spec, command, history, launch_reason(other))
        end

      # Inconclusive (slow or transitional) unit observation: retry, never a
      # definite :unknown outcome that would fence the VM.
      {:error, :unit_state_unavailable} ->
        {:retry, :execution_unavailable}

      _ ->
        unknown(:unknown)
    end
  end

  # @cc [owner:ghuntley,label:recovery] inception-core-readiness-budget
  # After boot-bound SMTP delivery, a new Inception execution MUST allow up to
  # forty minutes total for the offline instance-specific image rebuild and
  # core readiness: its persisted provisioning deadline carries that budget.
  # A failed or timed-out response MUST still fence and report the execution
  # as failed.
  defp ready_or_fail(config, pool, spec, command, history) do
    case Driver.trust(config.execution, pool, spec,
           execution_epoch: command.execution_epoch,
           generation: command.generation,
           vm_id: command.vm_id
         ) do
      :ok -> after_trust(config, pool, spec, command, history)
      {:error, :trust_failed} -> fail(config, pool, spec, command, history)
      {:error, :provisioning_busy} -> {:retry, :provisioning_busy}
      {:error, stage} -> {:retry, stage}
    end
  end

  defp after_trust(config, pool, spec, command, history) do
    case Driver.guest_capabilities(pool, spec) do
      {:ok, capabilities} ->
        if capabilities.readiness,
          do: provisioned_running(config, pool, spec, command, history),
          else: unattested_running(config, pool, spec, command, history)

      _ ->
        provisioned_running(config, pool, spec, command, history)
    end
  end

  # @cc [owner:ghuntley,label:recovery;security] agentless-running-without-guest-ready
  # A guest whose boot bundle declares no agents MUST be reported running from the
  # confined VMM observation alone, with no guest_ready fact and no readiness
  # deadline failure; unavailable locks retry exactly as for agent guests.
  defp unattested_running(config, pool, spec, command, history) do
    case Driver.unattested(config.execution, pool, spec,
           execution_epoch: command.execution_epoch,
           generation: command.generation,
           vm_id: command.vm_id
         ) do
      :ok -> {:ok, facts(:running, true)}
      error -> readiness_failure(config, pool, spec, command, history, error)
    end
  end

  defp provisioned_running(config, pool, spec, command, history) do
    case Driver.provisioned(config.execution, pool, spec,
           execution_epoch: command.execution_epoch,
           generation: command.generation,
           vm_id: command.vm_id
         ) do
      :ok ->
        running_with_source(
          config,
          pool,
          spec,
          command,
          Map.put(facts(:running, true), :guest_ready, true)
        )

      error ->
        readiness_failure(config, pool, spec, command, history, error)
    end
  end

  # @cc [owner:ghuntley,label:recovery] executor-source-handoff-after-running
  # A workspace source MUST be handed to a supervised delivery task only after guest
  # trust and durable provisioning readiness succeeded, and the running observation
  # MUST be returned unchanged whatever start/2 or the later delivery reports
  # (ADR-0157), preserving the guest_ready field from the completed readiness proof.
  @spec running_with_source(Config.t(), Pool.t(), Spec.t(), Execution.command(), observation()) ::
          {:ok, observation()}
  defp running_with_source(_config, _pool, %{workspace_source: nil}, _command, observation),
    do: {:ok, observation}

  defp running_with_source(config, pool, spec, command, observation) do
    options = [
      execution_epoch: command.execution_epoch,
      generation: command.generation,
      vm_id: command.vm_id
    ]

    if not WorkspaceSource.in_flight?(spec.id) and
         not Driver.workspace_source_settled?(config.execution, spec, options) do
      WorkspaceSource.start(spec.id, fn ->
        Driver.deliver_workspace_source(config.execution, pool, spec, options)
      end)
    end

    {:ok, observation}
  end

  # @cc [owner:ghuntley,label:recovery] readiness-contention-does-not-fence
  # Temporary placement/network lock contention during a readiness proof MUST
  # retry without fencing the boot or changing its previous observation.
  defp readiness_failure(_config, _pool, _spec, _command, _history, {:error, reason})
       when reason in [:execution_unavailable, :network_unavailable, :provisioning_busy],
       do: {:retry, reason}

  defp readiness_failure(config, pool, spec, command, history, {:error, reason}) do
    Lilly.Events.emit("vm.readiness_failed",
      vm_id: command.vm_id,
      placement_id: command.placement_id,
      operation_id: command.id,
      execution_epoch: command.execution_epoch,
      generation: command.generation,
      reason: reason
    )

    fail(config, pool, spec, command, history)
  end

  # @cc [owner:ghuntley,label:observability;recovery] launch-failure-names-cause
  # A provision or retained start whose launch fails without a retryable
  # reason MUST emit vm.launch_failed once, with the command's identifiers and
  # the closed reason atom (`:running_unconfirmed` when the submitted unit
  # never proved running), before fencing through fail/5. Paths, native output
  # and payloads MUST NOT be attached.
  defp launch_failed(config, pool, spec, command, history, reason) do
    Lilly.Events.emit("vm.launch_failed",
      vm_id: command.vm_id,
      placement_id: command.placement_id,
      operation: command.kind,
      execution_epoch: command.execution_epoch,
      generation: command.generation,
      reason: reason
    )

    fail(config, pool, spec, command, history)
  end

  defp launch_reason({:error, reason})
       when is_atom(reason) and not is_nil(reason) and not is_boolean(reason),
       do: reason

  defp launch_reason(_result), do: :execution_unconfirmed

  # @cc [owner:ghuntley,label:recovery] crash-requires-proven-running-history
  # Executor.fail/5 MUST label a fenced failure crashed only when durable history proves this same
  # epoch and generation previously ran; an initial launch failure must remain execution_failed and cannot
  # consume an automatic crash restart.
  defp fail(config, pool, spec, command, history) do
    reason =
      if history.running_epoch == command.execution_epoch and
           history.running_generation == command.generation,
         do: :crashed,
         else: :execution_failed

    with :ok <-
           Driver.fail(config.execution, pool, spec,
             execution_epoch: command.execution_epoch,
             generation: command.generation,
             vm_id: command.vm_id
           ),
         present when is_boolean(present) <- disk_present(pool, spec) do
      {:ok, %{facts(:failed, present) | reason: reason}}
    else
      {:error, reason} when reason in [:execution_unavailable, :network_unavailable] ->
        {:retry, reason}

      _ ->
        unknown(:cleanup_failed)
    end
  end

  defp stopped(pool, spec) do
    case disk_present(pool, spec) do
      present when is_boolean(present) -> {:ok, facts(:stopped, present)}
      _ -> unknown(:identity_mismatch)
    end
  end

  # @cc [owner:ghuntley,label:observability;recovery] disk-presence-unconfirmed-names-drive-shape
  # disk_present/2 MUST report a drive it cannot classify as present or absent
  # by emitting vm.disk_presence_unconfirmed with exactly one closed reason from
  # drive_shape/3 (never a path, size or uid value) before returning :unknown.
  defp disk_present(pool, spec) do
    directory = Path.dirname(Disk.path(pool, spec))

    Spec.drives(spec)
    |> Enum.reduce_while(true, fn drive, true ->
      case drive_shape(
             File.lstat(Path.join(directory, drive.name)),
             drive.bytes,
             spec.network.uid
           ) do
        :present ->
          {:cont, true}

        :absent ->
          {:halt, false}

        reason ->
          Lilly.Events.emit("vm.disk_presence_unconfirmed",
            placement_id: spec.id,
            reason: reason
          )

          {:halt, :unknown}
      end
    end)
  end

  @typedoc "How one placement drive's lstat result classifies."
  @type drive_shape ::
          :present
          | :absent
          | :drive_unreadable
          | :drive_not_regular
          | :drive_links
          | :drive_owner
          | :drive_smaller
          | :drive_larger

  @doc false
  @spec drive_shape({:ok, File.Stat.t()} | {:error, File.posix()}, non_neg_integer(), integer()) ::
          drive_shape()
  def drive_shape({:error, :enoent}, _bytes, _uid), do: :absent
  def drive_shape({:error, _}, _bytes, _uid), do: :drive_unreadable

  def drive_shape({:ok, %File.Stat{type: type}}, _bytes, _uid) when type != :regular,
    do: :drive_not_regular

  def drive_shape({:ok, %File.Stat{links: links}}, _bytes, _uid) when links != 1, do: :drive_links

  def drive_shape({:ok, %File.Stat{uid: owner}}, _bytes, uid) when owner not in [0, uid],
    do: :drive_owner

  def drive_shape({:ok, %File.Stat{size: size}}, bytes, _uid) when size < bytes,
    do: :drive_smaller

  def drive_shape({:ok, %File.Stat{size: size}}, bytes, _uid) when size > bytes, do: :drive_larger
  def drive_shape({:ok, %File.Stat{}}, _bytes, _uid), do: :present

  defp await_running(config, pool, spec, deadline) do
    cond do
      Observation.running?(config, pool, spec) ->
        true

      System.monotonic_time(:millisecond) >= deadline ->
        false

      Unit.status(spec) == {:ok, :stopped} ->
        false

      true ->
        receive do
        after
          100 -> await_running(config, pool, spec, deadline)
        end
    end
  end

  defp unknown(reason), do: {:ok, %{facts(:unknown, false) | reason: reason}}

  defp facts(state, disk),
    do: %{
      state: state,
      disk_present: disk,
      compute_empty: state in [:stopped, :deleted, :failed],
      cleanup_complete: state == :deleted,
      reason: :none
    }
end
