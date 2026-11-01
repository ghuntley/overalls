defmodule Lilly.VM.Driver do
  @moduledoc "Local privileged execution primitives for validated v4 commands."
  require Lilly.Events
  alias Lilly.Host.{Image, Lock, Pool, PrivateFiles}

  alias Lilly.VM.{
    API,
    Boot,
    Checkpoint,
    CheckpointStorage,
    Config,
    Credentials,
    Disk,
    GuestTrust,
    Intent,
    Jail,
    KernelAttestation,
    Observation,
    Provisioning,
    Readiness,
    Spec,
    Unit,
    WorkspaceSource
  }

  @type result :: :ok | {:error, atom()}

  # @cc [owner:ghuntley,label:security;recovery] transfer-source-current-local-authority
  # with_transfer_source/6 MUST hold the ordinary placement mutation lock and
  # verify its existing host/disk claim and exact launch epoch/generation before
  # invoking transfer work. The caller names the required source state: :running
  # (connectivity probes, post-clone snapshot pruning) requires running intent;
  # :stopped (snapshot creation and stream grants) requires stopped intent plus
  # confirmed unit, jail and network cleanup; :paused additionally requires its
  # durable ready checkpoint before memory relocation or snapshot cleanup.
  # This entry point MUST NOT create
  # launch authority or stop a running guest.
  @spec with_transfer_source(
          Config.t(),
          Pool.t(),
          Spec.t(),
          {pos_integer(), pos_integer()},
          :running | :stopped | :paused,
          (-> {:ok, term()} | :ok | {:error, atom()})
        ) ::
          {:ok, term()} | :ok | {:error, atom()}
  def with_transfer_source(config, pool, spec, {epoch, generation}, required, fun),
    do: with_transfer_source(config, pool, spec, {epoch, generation}, required, 0, fun)

  # @cc [owner:ghuntley,label:recovery;concurrency] transfer-source-cleanup-acquisition-window
  # Cleanup effects (post-clone pruning) may wait up to two seconds for the
  # placement lock instead of failing on the first contended tick, so a busy
  # VM actor does not starve snapshot cleanup; the callback still runs at most
  # once per acquisition and capture keeps the zero-wait default.
  @spec with_transfer_source(
          Config.t(),
          Pool.t(),
          Spec.t(),
          {pos_integer(), pos_integer()},
          :running | :stopped | :paused,
          0..2000,
          (-> {:ok, term()} | :ok | {:error, atom()})
        ) :: {:ok, term()} | :ok | {:error, atom()}
  def with_transfer_source(config, pool, spec, {epoch, generation}, required, retry_ms, fun)
      when required in [:running, :stopped, :paused] and retry_ms in 0..2000 do
    locked_value(config, spec, retry_ms, fn ->
      with :ok <- existing_claim(config, pool, spec),
           {:ok,
            %{
              placement_id: placement,
              execution_epoch: ^epoch,
              generation: ^generation,
              state: state
            }} <-
             Intent.read(directory(config, spec)),
           true <- placement == spec.id,
           :ok <- transfer_state(config, pool, spec, required, state) do
        fun.()
      else
        _ -> {:error, :source_authority_unconfirmed}
      end
    end)
  end

  defp transfer_state(_, _, _, :running, :running), do: :ok

  defp transfer_state(config, pool, spec, :stopped, :stopped) do
    with {:ok, :stopped} <- Unit.status(spec),
         :ok <- Jail.cleanup(pool, spec),
         :ok <- Lilly.Network.detach(config.network, spec.network),
         do: :ok,
         else: (_ -> {:error, :source_authority_unconfirmed})
  end

  defp transfer_state(config, pool, spec, :paused, :paused) do
    with {:ok, :stopped} <- Unit.status(spec),
         :ok <- Jail.cleanup(pool, spec),
         :ok <- Lilly.Network.detach(config.network, spec.network),
         {:ok, _, _} <- Checkpoint.ready(pool, spec),
         do: :ok,
         else: (_ -> {:error, :source_authority_unconfirmed})
  end

  defp transfer_state(_, _, _, _, _), do: {:error, :source_authority_unconfirmed}

  # @cc [owner:ghuntley,label:security;recovery] deleted-source-snapshot-reclamation
  # with_deleted_transfer_source/5 requires the exact retained delete command and
  # revoked exports. Under the placement lock it MUST verify existing ownership,
  # terminal delete intent and physical execution cleanup before snapshot work.
  # It MUST NOT create authority, change intent or delete the disk. An ordinary
  # delete retry remains responsible for disk absence and its physical outcome.
  @spec with_deleted_transfer_source(
          Config.t(),
          Pool.t(),
          Spec.t(),
          {pos_integer(), pos_integer()},
          (-> {:ok, term()} | {:error, atom()})
        ) :: {:ok, term()} | {:error, atom()}
  def with_deleted_transfer_source(config, pool, spec, {epoch, generation}, fun) do
    locked_value(config, spec, fn ->
      with :ok <- existing_claim(config, pool, spec),
           {:ok,
            %{
              placement_id: placement,
              execution_epoch: ^epoch,
              generation: ^generation,
              state: :deleted
            }} <-
             Intent.read(directory(config, spec)),
           true <- placement == spec.id,
           {:ok, :stopped} <- Unit.status(spec),
           :ok <- Jail.cleanup(pool, spec),
           :ok <- Lilly.Network.detach(config.network, spec.network),
           do: fun.(),
           else: (_ -> {:error, :source_authority_unconfirmed})
    end)
  end

  # @cc [owner:ghuntley,label:security;recovery] transfer-retirement-fences-before-delete
  # retire_transfer_source/5 requires authenticated cleanup authority and revoked,
  # reaped export streams. It MUST match the existing stopped source revision or
  # its exact successor deletion retry, prove execution quiescent, and persist
  # deletion intent/tombstone before removing snapshots or disk. Its callback MUST
  # verify and retire only the descriptor-bound source snapshot journal. Ordinary
  # disk deletion then proves physical absence; no return releases remote holds.
  # Failures MUST identify only a closed local stage or pool-lock
  # contention, never callback payloads. Classification MUST preserve guard order.
  # Retirement may retry per-VM acquisition for two seconds before any guard or
  # effect; the callback MUST run at most once. Final deletion may independently
  # retry pool acquisition for two seconds, never the effect.
  @spec retire_transfer_source(
          Config.t(),
          Pool.t(),
          Spec.t(),
          {pos_integer(), pos_integer()},
          (-> result())
        ) :: result()
  def retire_transfer_source(config, pool, spec, {epoch, generation}, fun) do
    locked(config, spec, 2000, fn ->
      with true <- generation in 1..9_223_372_036_854_775_806,
           {:claim, :ok} <- {:claim, existing_claim(config, pool, spec)},
           {:intent, {:ok, intent}} when is_map(intent) <-
             {:intent, Intent.read(directory(config, spec))},
           {:intent, true} <-
             {:intent, intent.placement_id == spec.id and intent.execution_epoch == epoch},
           {:intent, true} <-
             {:intent,
              {intent.generation, intent.state} in [
                {generation, :stopped},
                {generation, :paused},
                {generation + 1, :deleted}
              ]},
           {:unit, {:ok, :stopped}} <- {:unit, Unit.status(spec)},
           {:jail, :ok} <- {:jail, Jail.cleanup(pool, spec)},
           {:network, :ok} <- {:network, Lilly.Network.detach(config.network, spec.network)},
           {:fence, {:ok, _}} <-
             {:fence,
              Intent.set(directory(config, spec), spec.id, {epoch, generation + 1}, :deleted)},
           {:tombstone, :ok} <-
             {:tombstone,
              PrivateFiles.write(
                directory(config, spec),
                "deleted.json",
                JSON.encode!(identity(config, pool, spec))
              )},
           {:boot_log, :ok} <- {:boot_log, remove_log(Unit.boot_log(config, spec))},
           {:snapshots, :ok} <- {:snapshots, fun.()},
           {:snapshots, :ok} <- {:snapshots, CheckpointStorage.retire(pool, spec)},
           {:disk, :ok} <- {:disk, Disk.delete(pool, spec)},
           do: :ok,
           else: (
             {:claim, _} ->
               {:error, :source_claim_unconfirmed}

             {:intent, _} ->
               {:error, :source_intent_unconfirmed}

             {:unit, _} ->
               {:error, :source_unit_unconfirmed}

             {:jail, _} ->
               {:error, :source_jail_unconfirmed}

             {:network, _} ->
               {:error, :source_network_unconfirmed}

             {:fence, _} ->
               {:error, :source_fence_unconfirmed}

             {:tombstone, _} ->
               {:error, :source_tombstone_unconfirmed}

             {stage, {:error, :storage_busy}} when stage in [:snapshots, :disk] ->
               {:error, :storage_busy}

             {:boot_log, _} ->
               {:error, :source_boot_log_unconfirmed}

             {:snapshots, _} ->
               {:error, :source_snapshots_unconfirmed}

             {:disk, _} ->
               {:error, :source_disk_delete_unconfirmed}

             _ ->
               {:error, :source_cleanup_unconfirmed}
           )
    end)
  end

  # @cc [owner:ghuntley,label:security;recovery] transfer-import-before-execution
  # with_transfer_import/4 MUST serialize with ordinary placement mutations and
  # refuse unrelated VM claims, any launch intent or deletion tombstone. It MUST
  # prove the unit stopped and jail/network access absent before local adoption.
  # The callback MUST verify final disk adoption before returning success; only
  # then may this guard publish destination-local VM ownership for later ordinary
  # activation. A matching claim without launch intent permits interrupted retries.
  # This creates no launch authority and cannot adopt an executing placement.
  # Failed jail cleanup, network detach, disk adoption and ownership publication
  # MUST return distinct closed stage reasons without exposing underlying payloads.
  # Failures MUST identify only a closed local stage, never the rejected data;
  # stage classification MUST preserve guard order and reject before later effects.
  @spec with_transfer_import(Config.t(), Pool.t(), Spec.t(), (-> {:ok, term()} | {:error, atom()})) ::
          {:ok, term()} | {:error, atom()}
  def with_transfer_import(config, pool, spec, fun) do
    locked_value(config, spec, fn ->
      with {:claim, :ok} <- {:claim, import_claim_available(config, pool, spec)},
           {:tombstone, {:error, :enoent}} <-
             {:tombstone,
              Lilly.Host.Privilege.lstat(Path.join(directory(config, spec), "deleted.json"))},
           {:intent, {:ok, nil}} <- {:intent, Intent.read(directory(config, spec))},
           {:unit, {:ok, :stopped}} <- {:unit, Unit.status(spec)},
           {:jail, :ok} <- {:jail, Jail.cleanup(pool, spec)},
           {:network, :ok} <- {:network, Lilly.Network.detach(config.network, spec.network)},
           {:adoption, {:ok, value}} <- {:adoption, fun.()},
           {:ownership, :ok} <-
             {:ownership,
              PrivateFiles.write(
                directory(config, spec),
                "vm.json",
                JSON.encode!(identity(config, pool, spec))
              )} do
        {:ok, value}
      else
        {:claim, _} ->
          {:error, :import_claim_unconfirmed}

        {:tombstone, _} ->
          {:error, :import_tombstone_unconfirmed}

        {:intent, _} ->
          {:error, :import_intent_unconfirmed}

        {:unit, _} ->
          {:error, :import_unit_unconfirmed}

        {:jail, _} ->
          {:error, :import_jail_unconfirmed}

        {:network, _} ->
          {:error, :import_network_unconfirmed}

        {:adoption, {:error, reason}} when reason in [:storage_busy, :import_busy] ->
          {:error, reason}

        {:adoption, _} ->
          {:error, :import_disk_adoption_unconfirmed}

        {:ownership, _} ->
          {:error, :import_ownership_unconfirmed}
      end
    end)
  end

  defp import_claim_available(config, pool, spec) do
    case Lilly.Host.Privilege.lstat(Path.join(directory(config, spec), "vm.json")) do
      {:error, :enoent} -> :ok
      {:ok, _} -> existing_claim(config, pool, spec)
      _ -> :error
    end
  end

  # @cc [owner:ghuntley,label:security;recovery] cancelled-import-launch-fence-before-reclamation
  # retire_transfer_destination/5 requires authenticated pre-handoff cancellation
  # and a permanently retired transfer key. It MUST serialize ordinary placement
  # mutations, reject foreign ownership and any prior execution intent except its
  # exact deletion retry, and prove the unit stopped. It MUST persist terminal
  # launch intent and matching deletion ownership before jail/network or storage
  # cleanup. The callback MUST hold transfer exclusion and verify exact local
  # import reclamation. Failed callbacks retain all fences; successful retries
  # MUST NOT create a blank disk or authorize execution.
  @spec retire_transfer_destination(Config.t(), Pool.t(), Spec.t(), pos_integer(), (-> result())) ::
          result()
  def retire_transfer_destination(config, pool, spec, epoch, fun) do
    locked(config, spec, fn ->
      with true <- is_integer(epoch) and epoch in 1..9_223_372_036_854_775_807,
           true <- config.network.host_id == pool.host_id and spec.pool_id == pool.id,
           :ok <- import_claim_available(config, pool, spec),
           :ok <- import_deletion_available(config, pool, spec),
           {:ok, previous} <- Intent.read(directory(config, spec)),
           true <-
             previous == nil or
               previous == %{
                 placement_id: spec.id,
                 execution_epoch: epoch,
                 generation: 1,
                 state: :deleted
               },
           {:ok, :stopped} <- Unit.status(spec),
           {:ok, _} <- Intent.set(directory(config, spec), spec.id, {epoch, 1}, :deleted),
           :ok <-
             PrivateFiles.write(
               directory(config, spec),
               "vm.json",
               JSON.encode!(identity(config, pool, spec))
             ),
           :ok <-
             PrivateFiles.write(
               directory(config, spec),
               "deleted.json",
               JSON.encode!(identity(config, pool, spec))
             ),
           :ok <- Jail.cleanup(pool, spec),
           :ok <- Lilly.Network.detach(config.network, spec.network),
           :ok <- remove_socket(Unit.boot_log(config, spec)),
           :ok <- fun.(),
           do: :ok,
           else: (_ -> {:error, :destination_cleanup_unconfirmed})
    end)
  end

  defp import_deletion_available(config, pool, spec) do
    path = Path.join(directory(config, spec), "deleted.json")

    case Lilly.Host.Privilege.lstat(path) do
      {:error, :enoent} ->
        :ok

      {:ok, _} ->
        with {:ok, bytes} <- PrivateFiles.read_secret(path),
             {:ok, value} <- JSON.decode(bytes),
             true <- value == identity(config, pool, spec),
             do: :ok

      _ ->
        :error
    end
  end

  # @cc [owner:ghuntley,label:recovery] launch-at-most-once-per-generation
  # start/5 MUST persist the launch-attempt placement/epoch/generation before submitting a systemd start and
  # refuse to resubmit that authority after interruption. A deleted tombstone must prevent any
  # subsequent start.
  @spec start(Config.t(), Pool.t(), Image.t(), Spec.t(), keyword()) :: result()
  def start(config, pool, image, spec, options \\ []) do
    with :ok <- native_admission(image.manifest),
         :ok <- agents_profile(image, spec),
         :ok <- source_capability(image, spec),
         :ok <- git_identity_capability(image.manifest, spec) do
      launch(config, pool, spec, options, fn -> Disk.prepare(pool, image, spec) end)
    end
  end

  # @cc [owner:ghuntley,label:security] agentless-image-refuses-inception
  # An image whose agent set lacks the Inception capability MUST refuse the
  # Inception profile before disk preparation or any other host effect: Inception
  # depends on vsock credential delivery, terminals and workspace exchanges.
  @spec agents_profile(Image.t(), Spec.t()) :: :ok | {:error, :guest_agents_unavailable}
  defp agents_profile(%Image{manifest: %{guest_agents: agents} = manifest}, %{
         network: %{profile: :inception}
       }) do
    if OverallsProtocol.GuestAgents.capabilities(agents, manifest).inception,
      do: :ok,
      else: {:error, :guest_agents_unavailable}
  end

  defp agents_profile(_image, _spec), do: :ok

  # @cc [owner:ghuntley,label:security] native-launch-reviewed-image-only
  # Fresh and retained native launches MUST refuse an unreviewed immutable
  # image identity before disk preparation, boot identity or launch intent.
  # Existing stock manifests remain readable for diagnostics and cleanup.
  @spec native_admission(OverallsProtocol.ImageManifest.t() | OverallsProtocol.WorkloadBundle.t()) ::
          :ok | {:error, :guest_agents_unavailable}
  defp native_admission(identity) do
    if OverallsProtocol.NativeAdmission.admitted?(identity),
      do: :ok,
      else: {:error, :guest_agents_unavailable}
  end

  # @cc [owner:ghuntley,label:security;protocol] source-capability-before-start
  # A fresh source-bearing execution MUST use a validated current image that
  # explicitly declares workspace source protocol 2 (v4 Linux or v6 native).
  # Package presence, stale
  # manifests and malformed capability fields MUST refuse before disk preparation,
  # launch intent or any other host effect. Retained restart/adoption paths use
  # the immutable portable bundle and do not recreate an image.
  @spec source_capability(Image.t(), Spec.t()) :: :ok | {:error, :workspace_source_unavailable}
  defp source_capability(_image, %{workspace_source: nil}), do: :ok

  defp source_capability(%Image{id: image_id, manifest: manifest}, spec) do
    case OverallsProtocol.ImageManifest.validate(manifest.manifest) do
      {:ok, %{id: id, workspace_source_version: 2}}
      when id == image_id and id == spec.image_id ->
        :ok

      _ ->
        {:error, :workspace_source_unavailable}
    end
  end

  # @cc [owner:ghuntley,label:security;protocol] git-identity-capability-before-launch
  # Identity-bearing fresh and retained launches MUST require Git identity version
  # 1 from the matching validated image or retained portable bundle before launch
  # intent, disk preparation or boot metadata. Absence MUST refuse; VMs without an
  # identity MUST preserve the existing launch path without consulting the catalog.
  @spec git_identity_capability(
          OverallsProtocol.ImageManifest.t() | OverallsProtocol.WorkloadBundle.t(),
          Spec.t()
        ) :: :ok | {:error, :git_identity_unavailable}
  defp git_identity_capability(_identity, %{git_identity: nil}), do: :ok

  defp git_identity_capability(%{manifest: raw}, spec) do
    case OverallsProtocol.ImageManifest.validate(raw) do
      {:ok, %{id: id, git_identity_version: 1}} when id == spec.image_id -> :ok
      _ -> {:error, :git_identity_unavailable}
    end
  end

  defp git_identity_capability(%{git_identity_version: 1, image_id: id}, %{image_id: id}),
    do: :ok

  defp git_identity_capability(_identity, _spec), do: {:error, :git_identity_unavailable}

  # @cc [owner:ghuntley,label:recovery;security] retained-start-uses-portable-bundle
  # restart/4 MUST verify the existing placement-local disk and boot bundle and
  # MUST NOT consult, load or recreate an image artifact. It retains the same
  # launch authority and at-most-once guarantees as initial provisioning.
  # storage_busy MUST return before Boot.prepare or launch-attempt persistence;
  # only the existing executor/actor reconciliation may retry that authority.
  @spec restart(Config.t(), Pool.t(), Spec.t(), keyword()) :: result()
  def restart(config, pool, spec, options \\ []) do
    with {_, {:ok, bundle}} <- {:bundle, guest_bundle(pool, spec)},
         {_, :ok} <- {:admission, native_admission(bundle)},
         {_, :ok} <- {:git_identity, git_identity_capability(bundle, spec)} do
      launch(config, pool, spec, options, fn -> Disk.ready(pool, spec) end)
    else
      {stage, result} -> launch_refused(spec, stage, result)
    end
  end

  # @cc [owner:ghuntley,label:recovery;security] durable-pause-preserves-guest-memory
  # pause/4 MUST persist non-running authority before capture, freeze without a
  # guest shutdown, durably record successful snapshot creation, then prove the
  # cgroup empty and remove jail/network access before publishing immutable RAM.
  # An already-paused continuation may advance authority without executing RAM.
  @spec pause(Config.t(), Pool.t(), Spec.t(), keyword()) ::
          {:ok, OverallsProtocol.Checkpoint.t()} | {:error, atom()}
  def pause(config, pool, spec, options) do
    locked_value(config, spec, fn ->
      with :ok <- existing_claim(config, pool, spec),
           {:ok, bundle} <- guest_bundle(pool, spec),
           true <-
             OverallsProtocol.NativeAdmission.checkpoint_admitted?(
               bundle,
               config.checkpoint_image_ids
             ),
           {:ok, compatibility} <- Checkpoint.compatibility(config.firecracker),
           {:ok, intent} <-
             Intent.set(directory(config, spec), spec.id, revision(options), :paused) do
        authority =
          Map.take(intent, [:placement_id, :execution_epoch, :generation])
          |> stringify_authority()

        case Checkpoint.read(pool, spec.id) do
          {:ok, %{"phase" => "ready"}} ->
            with {:ok, :stopped} <- Unit.status(spec),
                 :ok <- Jail.cleanup(pool, spec),
                 :ok <- Lilly.Network.detach(config.network, spec.network),
                 {:ok, descriptor, _} <- Checkpoint.ready(pool, spec),
                 :ok <- CheckpointStorage.recycle_other(pool, spec),
                 do: {:ok, descriptor}

          {:ok, %{"phase" => "copied", "capture_authority" => ^authority}} ->
            finish_pause(config, pool, spec, authority)

          {:ok, %{"phase" => phase}} when phase in ["empty", "consumed"] ->
            with {:ok, _} <- Observation.check_state(config, pool, spec, [:running]),
                 {:ok, boot} <- Boot.read(directory(config, spec)),
                 true <- boot.placement_id == spec.id,
                 {:ok, record} <-
                   Checkpoint.begin_capture(pool, spec, boot, authority, compatibility),
                 :ok <- API.pause(api_path(pool, spec)),
                 {:ok, _} <- Observation.check_state(config, pool, spec, [:paused]),
                 :ok <-
                   API.create_checkpoint(
                     api_path(pool, spec),
                     if(record["slot"] == "a", do: :a, else: :b)
                   ),
                 :ok <-
                   Checkpoint.copied(
                     pool,
                     spec,
                     authority,
                     Path.join(directory(config, spec), "lock")
                   ),
                 do: finish_pause(config, pool, spec, authority)

          _ ->
            {:error, :checkpoint_unconfirmed}
        end
      end
    end)
  end

  defp finish_pause(config, pool, spec, authority) do
    with :ok <- paused_cleanup_available(config, pool, spec),
         :ok <- Unit.kill_paused(spec),
         {:ok, :stopped} <- Unit.status(spec),
         :ok <- Jail.cleanup(pool, spec),
         :ok <- Lilly.Network.detach(config.network, spec.network),
         {:ok, descriptor} <- Checkpoint.complete(pool, spec, authority),
         :ok <- CheckpointStorage.recycle_other(pool, spec),
         do: {:ok, descriptor}
  end

  defp paused_cleanup_available(config, pool, spec) do
    case Unit.status(spec) do
      {:ok, :stopped} ->
        :ok

      {:ok, :running} ->
        with {:ok, _} <- Observation.check_state(config, pool, spec, [:paused]), do: :ok

      error ->
        error
    end
  end

  # @cc [owner:ghuntley,label:recovery;security] resume-single-use-without-cold-fallback
  # resume/5 MUST verify immutable content and compatibility, durably consume the
  # checkpoint before launching a fresh API-only VMM, retain original guest boot
  # identity, and use explicit snapshot load/resume. A consumed interrupted load
  # cannot retry against mutated disk. The exact verified live restore VMM MAY
  # continue from Paused with PATCH Resumed or be adopted from Running; neither
  # continuation may load the snapshot again or replace its native process.
  @spec resume(Config.t(), Pool.t(), Spec.t(), OverallsProtocol.Checkpoint.t(), keyword()) ::
          result()
  def resume(config, pool, spec, descriptor, options) do
    locked(config, spec, fn ->
      with :ok <- existing_claim(config, pool, spec),
           {:ok, bundle} <- guest_bundle(pool, spec),
           true <-
             OverallsProtocol.NativeAdmission.checkpoint_admitted?(
               bundle,
               config.checkpoint_image_ids
             ),
           {:ok, compatibility} <- Checkpoint.compatibility(config.firecracker),
           {:ok, intent} <-
             Intent.set(directory(config, spec), spec.id, revision(options), :running) do
        authority =
          Map.take(intent, [:placement_id, :execution_epoch, :generation])
          |> stringify_authority()

        case Unit.status(spec) do
          {:ok, :running} ->
            with :ok <- Checkpoint.backing(pool, spec, descriptor, authority),
                 {:ok, boot} <- Boot.current(directory(config, spec), spec.id, revision(options)),
                 true <- Map.get(boot, :checkpoint_id) == descriptor.id,
                 :ok <- resume_live(config, pool, spec, intent, authority),
                 do: Checkpoint.consumed(pool, spec, authority)

          {:ok, :stopped} ->
            with :ok <- not_attempted(config, spec, intent),
                 :ok <- Disk.ready(pool, spec),
                 {:ok, record} <-
                   Checkpoint.consume(pool, spec, descriptor, authority, compatibility),
                 {:ok, boot} <-
                   Boot.continue(
                     directory(config, spec),
                     intent,
                     record["manifest"],
                     descriptor.id
                   ),
                 :ok <- Provisioning.prepare(config, spec, revision(options)),
                 :ok <- Provisioning.launching(config, spec, boot, readiness_budget(pool, spec)),
                 {:ok, bundle} <- Jail.prepare_restore(pool, spec, boot, record["slot"]),
                 :ok <- Lilly.VM.Logging.prepare(config, pool, spec, intent),
                 :ok <-
                   Lilly.Network.attach(
                     config.network,
                     spec.network,
                     intent,
                     Keyword.get(options, :vm_id)
                   ),
                 :ok <- commit(options),
                 :ok <-
                   PrivateFiles.write(
                     directory(config, spec),
                     "launch-attempt.bin",
                     <<intent.placement_id::binary-size(36), intent.execution_epoch::64,
                       intent.generation::64>>
                   ),
                 :ok <- Unit.restore(config, pool, spec, intent, bundle),
                 :ok <- await_api(config, pool, spec, :unconfigured, 5000),
                 :ok <-
                   API.load_checkpoint(
                     api_path(pool, spec),
                     spec.network,
                     OverallsProtocol.GuestAgents.vsock?(bundle.guest_agents)
                   ),
                 {:ok, _} <- Observation.check_state(config, pool, spec, [:paused]),
                 :ok <- API.resume(api_path(pool, spec)),
                 :ok <- await_api(config, pool, spec, :running, 5000),
                 do: Checkpoint.consumed(pool, spec, authority)

          _ ->
            {:error, :execution_unavailable}
        end
      end
    end)
  end

  # A restore interrupted after snapshot/load already owns mutated live RAM.
  # Reconciliation can finish its resume only under that same launch and PID;
  # an API-only process that never loaded memory remains unconfigured and refuses.
  defp resume_live(config, pool, spec, intent, authority) do
    with :ok <- exact_launch_attempt(config, spec, intent),
         true <- Unit.launched?(spec, intent),
         {:ok, vmm} <- Observation.check_state(config, pool, spec, [:running, :paused]),
         {:ok, incarnation} <- Observation.incarnation(vmm),
         {:ok, state} <- API.state(api_path(pool, spec), spec.id),
         {:ok, record} <- Checkpoint.read(pool, spec.id),
         {:ok, action} <- Checkpoint.restore_action(record, authority, state),
         :ok <- continue_live(config, pool, spec, intent, vmm, incarnation, action),
         do: :ok,
         else: (_ -> {:error, :checkpoint_unconfirmed})
  end

  defp continue_live(config, pool, spec, intent, vmm, incarnation, action) do
    state = if(action == :resume, do: :paused, else: :running)

    with {:ok, ^vmm} <- Observation.check_state(config, pool, spec, [state]),
         {:ok, ^incarnation} <- Observation.incarnation(vmm),
         true <- Unit.launched?(spec, intent),
         :ok <- if(action == :resume, do: API.resume(api_path(pool, spec)), else: :ok),
         :ok <- await_api(config, pool, spec, :running, 5000),
         {:ok, ^vmm} <- Observation.check_state(config, pool, spec, [:running]),
         {:ok, ^incarnation} <- Observation.incarnation(vmm),
         true <- Unit.launched?(spec, intent),
         do: :ok,
         else: (_ -> {:error, :checkpoint_unconfirmed})
  end

  defp exact_launch_attempt(config, spec, intent) do
    expected =
      <<intent.placement_id::binary-size(36), intent.execution_epoch::64, intent.generation::64>>

    case PrivateFiles.read_secret(Path.join(directory(config, spec), "launch-attempt.bin")) do
      {:ok, ^expected} -> :ok
      _ -> {:error, :checkpoint_unconfirmed}
    end
  end

  defp await_api(config, pool, spec, state, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_api(config, pool, spec, state, deadline)
  end

  defp wait_api(config, pool, spec, state, deadline) do
    observation =
      if state == :unconfigured,
        do: Observation.preboot(config, pool, spec),
        else: Observation.check_state(config, pool, spec, [state])

    case observation do
      {:ok, _} ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(25)
          wait_api(config, pool, spec, state, deadline)
        else
          {:error, :checkpoint_unconfirmed}
        end
    end
  end

  defp api_path(pool, spec), do: Path.join(Jail.root(pool, spec), "api.sock")

  defp stringify_authority(authority),
    do: Map.new(authority, fn {key, value} -> {Atom.to_string(key), value} end)

  # @cc [owner:ghuntley,label:recovery;concurrency] launch-steps-fenced
  # launch/5 MUST run as separate steps (begin, disk, boot, jail, network,
  # commit), each holding the placement lease only for its own duration
  # (ADR-0176 decision 2). Every step after begin MUST first re-read the
  # launch fence: the exact launch intent begin set, no deletion tombstone, a
  # stopped unit and no launch attempt at or beyond this revision. A changed
  # fence MUST return {:error, :preempted} before that step's effects. The
  # commit step checks the caller's commit, persists launch-attempt.bin and
  # starts the unit in one section, so the attempt is written at most once.
  defp launch(config, pool, spec, options, prepare_disk) do
    vm_id = Keyword.get(options, :vm_id)

    case locked_value(config, spec, fn -> begin_launch(config, pool, spec, options) end) do
      {:launch, intent} ->
        with :ok <-
               launch_section(config, spec, intent, fn ->
                 with :ok <- launch_step(prepare_disk.(), spec, :disk),
                      do: CheckpointStorage.prepare(pool, spec)
               end),
             {:ok, boot} <-
               launch_section(config, spec, intent, fn ->
                 boot_step(config, pool, spec, intent)
               end),
             {:ok, bundle} <-
               launch_section(config, spec, intent, fn ->
                 launch_step(Jail.prepare(pool, spec, boot, vm_id), spec, :jail)
               end),
             :ok <-
               launch_section(config, spec, intent, fn ->
                 with :ok <- Lilly.VM.Logging.prepare(config, pool, spec, intent),
                      :ok <- Lilly.Network.attach(config.network, spec.network, intent, vm_id),
                      do: remove_log(Unit.boot_log(config, spec))
               end) do
          launch_section(config, spec, intent, fn ->
            commit_launch(config, pool, spec, intent, bundle, options)
          end)
        end
        |> lifecycle_result()

      other ->
        lifecycle_result(other)
    end
  end

  # The first step claims the placement and sets running intent. A unit that
  # is already running is adopted in this same section; nothing else follows.
  defp begin_launch(config, pool, spec, options) do
    with {_, true} <-
           {:socket_path, byte_size(Path.join(Jail.root(pool, spec), "api.sock")) < 108},
         {_, :ok} <- {:bootstrap_inputs, bootstrap_inputs(config, spec)},
         {_, :ok} <- {:claim, claim(config, pool, spec)},
         {_, {:error, :enoent}} <-
           {:tombstone,
            Lilly.Host.Privilege.lstat(Path.join(directory(config, spec), "deleted.json"))},
         {_, {:ok, intent}} <-
           {:intent, Intent.set(directory(config, spec), spec.id, revision(options), :running)} do
      case Unit.status(spec) do
        {:ok, :running} ->
          with :ok <- adoption_observation(config, pool, spec),
               do: preserve_running_boot(config, spec, intent)

        {:ok, :stopped} ->
          with {_, :ok} <- {:not_attempted, not_attempted(config, spec, intent)},
               {_, :ok} <- {:checkpoint, cold_checkpoint_empty(pool, spec)},
               {_, :ok} <- {:provisioning, Provisioning.prepare(config, spec, revision(options))} do
            {:launch, intent}
          else
            {stage, result} -> launch_refused(spec, stage, result)
          end

        error ->
          error
      end
    else
      {stage, result} -> launch_refused(spec, stage, result)
    end
  end

  @launch_contention [
    :execution_unavailable,
    :network_unavailable,
    :provisioning_busy,
    :storage_busy,
    :unit_state_unavailable
  ]

  # @cc [owner:ghuntley,label:observability;recovery] launch-refusal-names-stage
  # A launch or retained restart refused before any systemd submission MUST
  # emit vm.launch_refused once with the closed stage atom and, when the step
  # returned `{:error, atom}`, that atom (otherwise `:refused`), and MUST
  # return the step's original result unchanged. Contention reasons that the
  # executor retries MUST NOT emit. Paths, file contents and native output MUST
  # NOT be attached.
  @spec launch_refused(Spec.t(), atom(), term()) :: term()
  defp launch_refused(_spec, _stage, {:error, reason} = result) when reason in @launch_contention,
    do: result

  defp launch_refused(spec, stage, result) do
    reason =
      case result do
        {:error, reason} when is_atom(reason) and not is_nil(reason) and not is_boolean(reason) ->
          reason

        _ ->
          :refused
      end

    Lilly.Events.emit("vm.launch_refused", placement_id: spec.id, stage: stage, reason: reason)
    result
  end

  # @cc [owner:ghuntley,label:recovery;security] retained-memory-forbids-cold-launch
  # A stopped unit with retained or consumed continuation state MUST NOT accept
  # an ordinary cold launch. Only explicit stop/retirement may discard RAM; a
  # failed restore never becomes a new InstanceStart attempt.
  defp cold_checkpoint_empty(pool, spec) do
    case Checkpoint.read(pool, spec.id) do
      {:ok, nil} -> :ok
      {:ok, %{"phase" => "empty"}} -> :ok
      _ -> {:error, :checkpoint_unconfirmed}
    end
  end

  defp boot_step(config, pool, spec, intent) do
    with {:ok, agents} <- guest_agents(pool, spec),
         {:ok, boot} <- Boot.prepare(directory(config, spec), intent),
         :ok <-
           Provisioning.launching(
             config,
             spec,
             boot,
             OverallsProtocol.GuestAgents.readiness_budget_ms(agents, spec.network.profile)
           ),
         do: {:ok, boot}
  end

  defp commit_launch(config, pool, spec, intent, bundle, options) do
    vm_id = Keyword.get(options, :vm_id)

    with :ok <- commit(options),
         :ok <-
           PrivateFiles.write(
             directory(config, spec),
             "launch-attempt.bin",
             <<intent.placement_id::binary-size(36), intent.execution_epoch::64,
               intent.generation::64>>
           ),
         :ok <- Unit.start(config, pool, spec, intent, bundle, vm_id),
         do: launched(vm_id, intent)
  end

  # One step: wait (FIFO, at most 2 s) for the placement lease, so a brief
  # observation between steps does not abort the create, then re-read the
  # fence and run the step.
  defp launch_section(config, spec, intent, step) do
    locked_value(config, spec, 2000, fn ->
      case launch_fence(config, spec, intent) do
        :ok -> step.()
        {:error, _} = error -> error
      end
    end)
  end

  @doc false
  # @cc [owner:ghuntley,label:recovery;concurrency] launch-fence-exact
  # launch_fence/3 MUST return :ok only when intent.bin still holds exactly
  # the given intent, deleted.json is absent, the unit is stopped and no
  # launch attempt exists at or beyond the intent's revision; otherwise
  # {:error, :preempted}, or the unit's own unavailable result.
  @spec launch_fence(Config.t(), Spec.t(), Intent.t()) :: :ok | {:error, atom()}
  def launch_fence(config, spec, intent) do
    directory = directory(config, spec)

    with {:ok, ^intent} <- Intent.read(directory),
         {:error, :enoent} <- Lilly.Host.Privilege.lstat(Path.join(directory, "deleted.json")),
         {:ok, :stopped} <- Unit.status(spec),
         :ok <- not_attempted(config, spec, intent) do
      :ok
    else
      {:error, :unit_state_unavailable} = error -> error
      _ -> {:error, :preempted}
    end
  end

  defp lifecycle_result(:ok), do: :ok
  defp lifecycle_result({:error, reason}) when is_atom(reason), do: {:error, reason}
  defp lifecycle_result(_), do: {:error, :execution_unconfirmed}

  # @cc [owner:ghuntley,label:recovery] resize-owned-stopped-placement
  # Resize MUST journal both VM bindings before changing storage or ownership.
  # Only exact source/target records may resume; confirmed stopped unit, cleaned
  # jail and stopped launch intent are required before any disk mutation.
  @spec resize(Config.t(), Pool.t(), Spec.t(), Spec.t(), keyword()) :: result()
  def resize(config, pool, source, target, options) do
    locked(config, source, fn ->
      before = identity(config, pool, source)
      after_resize = identity(config, pool, target)
      transition = %{"source" => before, "target" => after_resize}
      journal_name = "resize-#{Keyword.fetch!(options, :request_id)}.json"
      directory = directory(config, source)

      with true <-
             Map.drop(Spec.encode(source), ~w(vcpu memory_bytes disk_bytes)) ==
               Map.drop(Spec.encode(target), ~w(vcpu memory_bytes disk_bytes)),
           true <- target.disk_bytes >= source.disk_bytes,
           {:ok, bytes} <- PrivateFiles.read_secret(Path.join(directory, "vm.json")),
           {:ok, current} <- JSON.decode(bytes),
           true <- current in [before, after_resize],
           {:ok, :stopped} <- Unit.status(source),
           :ok <- Jail.cleanup(pool, source),
           :ok <- Lilly.Network.detach(config.network, source.network),
           {:ok, _} <- Intent.set(directory, source.id, revision(options), :stopped),
           :ok <- resize_journal(directory, journal_name, transition, current == before),
           :ok <- Disk.resize(pool, source, target, Keyword.fetch!(options, :request_id)),
           :ok <- PrivateFiles.write(directory, "vm.json", JSON.encode!(after_resize)) do
        :ok
      else
        # Contention is inconclusive and retryable; everything else is a
        # definite refusal (ADR-0140: slowness is never evidence).
        {:error, :unit_state_unavailable} -> {:error, :execution_unavailable}
        {:error, :storage_busy} = busy -> busy
        _ -> {:error, :resize_unconfirmed}
      end
    end)
  end

  defp resize_journal(directory, name, transition, original?) do
    case Lilly.Host.Privilege.lstat(Path.join(directory, name)) do
      {:ok, _} ->
        with {:ok, bytes} <- PrivateFiles.read_secret(Path.join(directory, name)),
             {:ok, ^transition} <- JSON.decode(bytes),
             do: :ok,
             else: (_ -> {:error, :resize_conflict})

      {:error, :enoent} when original? ->
        PrivateFiles.write(directory, name, JSON.encode!(transition))

      _ ->
        {:error, :resize_conflict}
    end
  end

  @doc "Confirm guest readiness for exact current running authority, without holding a lock while waiting."
  # @cc [owner:ghuntley,label:recovery;security] guest-readiness-rechecks-authority-after-wait
  # ready/4 MUST verify the local VM claim, current running intent, boot identity and
  # VMM confinement under the placement lock before and after its socket wait. The
  # boot record MUST remain identical across the wait. It MUST NOT hold the placement
  # lock across the guest wait or grant source cleanup authority on its own.
  @spec ready(Config.t(), Pool.t(), Spec.t(), keyword()) :: result()
  def ready(config, pool, spec, options) do
    with {:ok, capabilities} <- guest_capabilities(pool, spec),
         :ok <- readiness_capability(capabilities),
         {:ok, _} <- ready_boot(config, pool, spec, options) do
      :ok
    else
      error -> error
    end
  end

  @doc "Which guest agent set the placement's durable boot bundle declares."
  # @cc [owner:ghuntley,label:security] guest-agents-from-portable-bundle
  # guest_agents/2 MUST read the agent set only from the validated placement-local
  # boot bundle, never from the image catalog, the guest or peer input, so launch,
  # restart and adoption derive identity from one durable authority. Guest
  # operations MUST additionally apply guest_capabilities/2's native review gate.
  @spec guest_agents(Pool.t(), Spec.t()) ::
          {:ok, OverallsProtocol.WorkloadBundle.guest_agents()}
          | {:error, :invalid_workload_bundle}
  def guest_agents(pool, spec) do
    with {:ok, bundle} <-
           Lilly.VM.WorkloadBundle.load(Lilly.Host.ZFSDataset.directory(pool, spec), spec),
         do: {:ok, bundle.guest_agents}
  end

  # @cc [owner:ghuntley,label:security] guest-capabilities-from-reviewed-bundle
  # Guest operations MUST derive capabilities from the validated placement-local
  # bundle and exact native admission identity. An agent-set name alone MUST NOT
  # activate retained stock or unreviewed native images.
  @spec guest_capabilities(Pool.t(), Spec.t()) ::
          {:ok, OverallsProtocol.GuestAgents.capabilities()} | {:error, :invalid_workload_bundle}
  def guest_capabilities(pool, spec) do
    with {:ok, bundle} <- guest_bundle(pool, spec) do
      {:ok, OverallsProtocol.GuestAgents.capabilities(bundle.guest_agents, bundle)}
    end
  end

  # @cc [owner:ghuntley,label:recovery] readiness-budget-from-bundle
  # A provisioning transition MUST derive its initial deadline from the agent
  # set in the validated placement-local bundle. An unreadable bundle returns
  # nil so legacy recovery callers retain the historical Linux fallback; a
  # readable native bundle never falls through that fallback.
  @spec readiness_budget(Pool.t(), Spec.t()) :: pos_integer() | nil
  defp readiness_budget(pool, spec) do
    case guest_agents(pool, spec) do
      {:ok, agents} ->
        OverallsProtocol.GuestAgents.readiness_budget_ms(agents, spec.network.profile)

      {:error, _} ->
        nil
    end
  end

  @doc "Commit that a guest without agents is running and will never prove readiness."
  # @cc [owner:ghuntley,label:recovery;security] agentless-guest-unattested-not-ready
  # unattested/4 MUST recheck confined authority and the exact current boot under
  # the placement lock, advance provisioning to `unattested` without any guest
  # exchange, and MUST NOT write a ready receipt or report guest readiness. It
  # MUST refuse with `guest_agents_unavailable`, before any lock or write, when
  # the placement's agent set proves readiness, so an agent guest can never be
  # committed as running without its ready line.
  @spec unattested(Config.t(), Pool.t(), Spec.t(), keyword()) :: result()
  def unattested(config, pool, spec, options) do
    case guest_capabilities(pool, spec) do
      {:ok, capabilities} ->
        if capabilities.readiness,
          do: {:error, :guest_agents_unavailable},
          else: commit_unattested(config, pool, spec, options)

      {:error, _} = error ->
        error
    end
  end

  @spec commit_unattested(Config.t(), Pool.t(), Spec.t(), keyword()) :: result()
  defp commit_unattested(config, pool, spec, options) do
    expected = revision(options)
    budget = readiness_budget(pool, spec)

    result =
      locked(config, spec, 2000, fn ->
        with :ok <- readiness_claim(config, pool, spec, expected),
             {:ok, boot} <- Boot.current(directory(config, spec), spec.id, expected),
             :ok <- Provisioning.awaiting_trust(config, spec, boot, budget),
             do: Provisioning.unattested(config, spec, boot)
      end)

    case result do
      :ok -> :ok
      {:error, :provisioning_busy} = error -> error
      _ -> {:error, :readiness_unconfirmed}
    end
  end

  # @cc [owner:ghuntley,label:security;recovery] provision-completion-requires-durable-ssh
  # Completion MUST recheck confined authority even for a cached receipt. A fresh
  # guest exchange uses only the remaining persisted deadline and runs outside
  # placement/audit locks. Commit requires the exact pre-wait boot and current
  # authority; failures never report running or remove cleanup obligations. If
  # the journal has no deadline, the budget MUST come from the validated
  # placement-local bundle's agent set before awaiting trust advances it.
  @spec provisioned(Config.t(), Pool.t(), Spec.t(), keyword()) :: result()
  def provisioned(config, pool, spec, options) do
    expected = revision(options)
    budget = readiness_budget(pool, spec)

    with {:ok, boot, status} <-
           locked_value(config, spec, 2000, fn ->
             with :ok <- readiness_claim(config, pool, spec, expected),
                  {:ok, boot} <- Boot.current(directory(config, spec), spec.id, expected),
                  :ok <- Provisioning.awaiting_trust(config, spec, boot, budget),
                  :ok <- Provisioning.awaiting_ssh(config, spec, boot) do
               case Provisioning.status(config, spec, boot) do
                 {:error, _} = error -> error
                 status -> {:ok, boot, status}
               end
             end
           end) do
      case status do
        {:ready, _boot_id} ->
          if spec.network.profile == :inception,
            do: configure(config, pool, spec, options),
            else: :ok

        {:wait, 0} ->
          {:error, :readiness_timeout}

        {:wait, timeout} ->
          with {:ok, boot_id} <-
                 ready_boot(config, pool, spec, Keyword.put(options, :timeout, timeout)) do
            locked(config, spec, 2000, fn ->
              with :ok <- readiness_claim(config, pool, spec, expected),
                   {:ok, current_boot} <- Boot.current(directory(config, spec), spec.id, expected),
                   true <-
                     Map.delete(current_boot, :guest_boot_id) == Map.delete(boot, :guest_boot_id) do
                Provisioning.ready(config, spec, current_boot, boot_id)
              else
                _ -> {:error, :readiness_unconfirmed}
              end
            end)
          end
      end
    else
      {:error, _} = error -> error
      _ -> {:error, :readiness_unconfirmed}
    end
  end

  # @cc [owner:ghuntley,label:security;recovery] trust-receipt-before-running
  # A running result requires a durable receipt for the exact current boot.
  # The guest exchange runs without the placement lock, with confined authority
  # checked on both sides; old boot receipts cannot authorize a new launch.
  @spec trust(Config.t(), Pool.t(), Spec.t(), keyword()) :: result()
  def trust(%{guest_trust_roots: []}, _pool, _spec, _options), do: :ok

  def trust(config, pool, spec, options) do
    case guest_capabilities(pool, spec) do
      {:ok, capabilities} ->
        if capabilities.trust,
          do: deliver_trust(config, pool, spec, options),
          else: skip_trust(config, pool, spec, options)

      _ ->
        {:error, :trust_boot_unconfirmed}
    end
  end

  # @cc [owner:ghuntley,label:recovery;concurrency] trust-queues-for-placement-lease
  # Every placement lease the trust path takes MUST wait up to @trust_wait_ms
  # in hostd's FIFO queue, as the other readiness steps do, so the per-tick
  # boot probe and outcome journal writers cannot starve trust confirmation
  # of an adopted guest; contention past the wait still retries as
  # trust_lock_unavailable and never fences.
  @trust_wait_ms 2000

  # @cc [owner:ghuntley,label:security;recovery] trust-skipped-receipt-for-agentless-guests
  # A guest without agents MUST never be sent trust material; trust/4 MUST instead
  # persist a `skipped` receipt bound to the exact current boot under the placement
  # lock after rechecking confined authority, emitting the skip once per boot.
  defp skip_trust(config, pool, spec, options) do
    expected = revision(options)
    directory = directory(config, spec)
    budget = readiness_budget(pool, spec)

    config
    |> locked(spec, @trust_wait_ms, fn ->
      with :ok <- readiness_stage(config, pool, spec, expected),
           {:ok, boot} <- current_boot(directory, spec.id, expected),
           :ok <- awaiting_trust(config, spec, boot, budget),
           {:ok, previous} <- trust_journal(directory) do
        if previous && previous.payload["state"] == "skipped" &&
             same_trust_boot?(previous.payload, boot) do
          :ok
        else
          with :ok <- trust_state(directory, trust_payload(config, boot, "skipped", 0)) do
            Lilly.Events.emit("vm.trust_skipped",
              placement_id: spec.id,
              execution_epoch: boot.execution_epoch
            )

            :ok
          end
        end
      end
    end)
    |> trust_result()
  end

  defp deliver_trust(config, pool, spec, options) do
    expected = revision(options)
    directory = directory(config, spec)
    budget = readiness_budget(pool, spec)

    with :ok <-
           locked(config, spec, @trust_wait_ms, fn ->
             with :ok <- readiness_stage(config, pool, spec, expected),
                  {:ok, boot} <- current_boot(directory, spec.id, expected),
                  do: awaiting_trust(config, spec, boot, budget)
           end),
         {:ok, boot} <- current_boot(directory, spec.id, expected),
         {:ok, previous} <- trust_journal(directory) do
      maybe_deliver_trust(config, pool, spec, expected, boot, previous, directory)
    end
    |> trust_result()
  end

  defp maybe_deliver_trust(config, pool, spec, expected, boot, previous, directory) do
    attempts =
      if(previous && same_trust_boot?(previous.payload, boot),
        do: previous.payload["attempts"],
        else: 0
      )

    cond do
      receipt_for_boot?(previous && previous.payload, boot) ->
        locked(config, spec, @trust_wait_ms, fn ->
          with :ok <- readiness_stage(config, pool, spec, expected),
               do: same_boot(directory, spec.id, expected, boot)
        end)

      is_integer(attempts) and attempts >= 3 ->
        {:error, :trust_failed}

      not is_integer(attempts) or attempts < 0 ->
        {:error, :trust_attempts_invalid}

      true ->
        with :ok <-
               locked(config, spec, @trust_wait_ms, fn ->
                 prepare_trust_state(
                   config,
                   pool,
                   spec,
                   expected,
                   boot,
                   previous,
                   directory,
                   attempts
                 )
               end) do
          Lilly.Events.emit("vm.trust_delivering",
            placement_id: spec.id,
            execution_epoch: boot.execution_epoch
          )

          case GuestTrust.deliver(
                 Path.join(Jail.root(pool, spec), "v.sock"),
                 boot,
                 config.guest_trust_roots,
                 trust_timeout(config, spec, boot)
               ) do
            {:ok, boot_id, digest} ->
              installed(config, pool, spec, expected, boot, directory, attempts, boot_id, digest)

            _ ->
              locked(config, spec, @trust_wait_ms, fn ->
                with :ok <- readiness_stage(config, pool, spec, expected),
                     :ok <- same_boot(directory, spec.id, expected, boot),
                     do:
                       trust_state(directory, trust_payload(config, boot, "failed", attempts + 1))
              end)

              Lilly.Events.emit("vm.trust_failed",
                placement_id: spec.id,
                execution_epoch: boot.execution_epoch
              )

              {:error, :trust_delivery_failed}
          end
        end
    end
  end

  defp installed(config, pool, spec, expected, boot, directory, attempts, boot_id, digest) do
    with :ok <-
           locked(config, spec, @trust_wait_ms, fn ->
             with :ok <- readiness_stage(config, pool, spec, expected),
                  :ok <- same_boot(directory, spec.id, expected, boot),
                  do:
                    trust_state(
                      directory,
                      trust_payload(config, boot, "installed", attempts + 1, boot_id, digest)
                    )
           end) do
      Lilly.Events.emit("vm.trust_installed",
        placement_id: spec.id,
        execution_epoch: boot.execution_epoch
      )

      :ok
    end
  end

  defp prepare_trust_state(config, pool, spec, expected, boot, previous, directory, attempts) do
    with :ok <- readiness_stage(config, pool, spec, expected),
         :ok <- same_boot(directory, spec.id, expected, boot),
         :ok <-
           if(previous == nil or not same_trust_boot?(previous.payload, boot),
             do: trust_state(directory, trust_payload(config, boot, "pending", 0)),
             else: :ok
           ) do
      trust_state(directory, trust_payload(config, boot, "delivering", attempts + 1))
    end
  end

  # @cc [owner:ghuntley,label:observability;security] trust-unconfirmed-names-stage
  # trust/4 MUST return :ok, {:error, :trust_failed}, {:error, :provisioning_busy}
  # or exactly one trust_stage() atom naming the first step that could not be
  # confirmed; no other value may escape, so the executor's deferral reason
  # always names the stage. Every stage still retries: naming MUST NOT turn
  # an unconfirmed step into success or a terminal failure.
  @type trust_stage ::
          :trust_lock_unavailable
          | :trust_claim_mismatch
          | :trust_boot_unconfirmed
          | :trust_boot_changed
          | :trust_vmm_unconfirmed
          | :trust_provisioning_unconfirmed
          | :trust_journal_unreadable
          | :trust_state_unwritten
          | :trust_attempts_invalid
          | :trust_delivery_failed
  @trust_stages [
    :trust_lock_unavailable,
    :trust_claim_mismatch,
    :trust_boot_unconfirmed,
    :trust_boot_changed,
    :trust_vmm_unconfirmed,
    :trust_provisioning_unconfirmed,
    :trust_journal_unreadable,
    :trust_state_unwritten,
    :trust_attempts_invalid,
    :trust_delivery_failed
  ]

  @doc "The closed stage atoms trust/4 returns while guest trust is unconfirmed."
  @spec trust_stages() :: [trust_stage(), ...]
  def trust_stages, do: @trust_stages

  defp trust_result(:ok), do: :ok

  defp trust_result({:error, reason}) when reason in [:trust_failed, :provisioning_busy],
    do: {:error, reason}

  defp trust_result({:error, stage}) when stage in @trust_stages, do: {:error, stage}
  defp trust_result(_), do: {:error, :trust_lock_unavailable}

  defp current_boot(directory, placement, expected) do
    case Boot.current(directory, placement, expected) do
      {:ok, boot} -> {:ok, boot}
      _ -> {:error, :trust_boot_unconfirmed}
    end
  end

  defp same_boot(directory, placement, expected, boot) do
    case Boot.current(directory, placement, expected) do
      {:ok, ^boot} -> :ok
      {:ok, _} -> {:error, :trust_boot_changed}
      _ -> {:error, :trust_boot_unconfirmed}
    end
  end

  defp awaiting_trust(config, spec, boot, budget) do
    case Provisioning.awaiting_trust(config, spec, boot, budget) do
      :ok -> :ok
      {:error, :provisioning_busy} = error -> error
      _ -> {:error, :trust_provisioning_unconfirmed}
    end
  end

  defp trust_journal(directory) do
    case Lilly.Lifecycle.Journal.load(Lilly.Lifecycle.GuestTrust, directory, "guest-trust.json") do
      {:ok, previous} -> {:ok, previous}
      _ -> {:error, :trust_journal_unreadable}
    end
  end

  defp trust_state(directory, payload) do
    case write_trust_state(directory, payload) do
      :ok -> :ok
      _ -> {:error, :trust_state_unwritten}
    end
  end

  defp trust_timeout(config, spec, boot) do
    case Provisioning.status(config, spec, boot) do
      {:ready, _} -> 120_000
      {:wait, remaining} -> min(remaining, 120_000)
      _ -> 0
    end
  end

  defp receipt_for_boot?(nil, _), do: false

  defp receipt_for_boot?(receipt, boot) do
    receipt["state"] == "installed" and same_trust_boot?(receipt, boot) and
      OverallsProtocol.uuid?(receipt["boot_id"]) and
      is_binary(receipt["bundle_digest"]) and byte_size(receipt["bundle_digest"]) == 64
  end

  defp same_trust_boot?(receipt, boot) do
    receipt["placement_id"] == boot.placement_id and
      receipt["execution_epoch"] == boot.execution_epoch and
      receipt["generation"] == boot.generation and
      receipt["boot_challenge"] == boot.boot_challenge
  end

  defp trust_payload(config, boot, state, attempts, boot_id \\ nil, digest \\ nil) do
    %{
      "state" => state,
      "host_id" => config.network.host_id,
      "placement_id" => boot.placement_id,
      "execution_epoch" => boot.execution_epoch,
      "generation" => boot.generation,
      "boot_challenge" => boot.boot_challenge,
      "attempts" => attempts,
      "boot_id" => boot_id,
      "bundle_digest" => digest
    }
  end

  defp write_trust_state(directory, payload) do
    with {:ok, lock} <- Lilly.Host.Lock.acquire(Path.join(directory, "audit-lock"), 2000) do
      try do
        Lilly.Lifecycle.Journal.write(
          Lilly.Lifecycle.GuestTrust,
          directory,
          "guest-trust.json",
          payload
        )
      after
        Lilly.Host.Lock.release(lock)
      end
    end
  end

  @doc "Whether this boot's workspace source delivery is already delivered or failed (no lock)."
  @spec workspace_source_settled?(Config.t(), Spec.t(), keyword()) :: boolean()
  def workspace_source_settled?(_config, %{workspace_source: nil}, _options), do: true

  def workspace_source_settled?(config, spec, options) do
    directory = directory(config, spec)

    with {:ok, boot} <- Boot.current(directory, spec.id, revision(options)),
         {:ok, %{payload: payload}} <-
           Lilly.Lifecycle.Journal.load(
             Lilly.Lifecycle.WorkspaceSource,
             directory,
             "workspace-source.json"
           ) do
      WorkspaceSource.settled?(payload, boot, WorkspaceSource.digest(spec.workspace_source))
    else
      _ -> false
    end
  end

  # @cc [owner:ghuntley,label:security;recovery] workspace-source-delivery-current-boot
  # deliver_workspace_source/4 MUST verify confined current execution and the same boot
  # under the placement lock before recording delivering, before every guest attempt and
  # before recording delivered or failed. The placement lock MUST NOT be held across the
  # guest exchange. A settled record for this boot and source MUST NOT be redelivered; a
  # superseded boot MUST NOT be sent the source or recorded. It MUST NOT stop, fail or
  # fence the VM, and events carry only VM/placement identifiers and a closed reason.
  @spec deliver_workspace_source(Config.t(), Pool.t(), Spec.t(), keyword()) :: result()
  def deliver_workspace_source(_config, _pool, %{workspace_source: nil}, _options), do: :ok

  def deliver_workspace_source(config, pool, spec, options) do
    case guest_capabilities(pool, spec) do
      {:ok, capabilities} ->
        if capabilities.workspace,
          do: deliver_workspace_source_to_guest(config, pool, spec, options),
          else: {:error, :workspace_source_unavailable}

      _ ->
        {:error, :workspace_source_unavailable}
    end
  end

  defp deliver_workspace_source_to_guest(config, pool, spec, options) do
    expected = revision(options)
    directory = directory(config, spec)
    digest = WorkspaceSource.digest(spec.workspace_source)
    vm_id = Keyword.get(options, :vm_id)

    current = fn boot ->
      with :ok <- readiness_claim(config, pool, spec, expected),
           {:ok, ^boot} <- Boot.current(directory, spec.id, expected),
           do: :ok,
           else: (_ -> {:error, :workspace_source_fenced})
    end

    fence = fn boot -> fn -> locked(config, spec, 2000, fn -> current.(boot) end) end end

    case locked_value(config, spec, 2000, fn ->
           begin_workspace_source(config, pool, spec, expected, directory, digest)
         end) do
      {:ok, :settled} ->
        :ok

      {:ok, boot, attempts} ->
        result =
          WorkspaceSource.deliver(
            Path.join(Jail.root(pool, spec), "v.sock"),
            Boot.expectation(boot),
            spec.workspace_source,
            timeout: Keyword.get(options, :timeout, 120_000),
            fence: fence.(boot)
          )

        state = if result == :ok, do: :delivered, else: :failed

        recorded =
          locked(config, spec, 2000, fn ->
            with :ok <- current.(boot) do
              write_workspace_source_state(
                directory,
                WorkspaceSource.payload(config.network.host_id, boot, state, attempts, digest)
              )
            end
          end)

        workspace_source_event(vm_id, spec.id, result, recorded)

      _ ->
        # Not yet current or settled authority: no attempt was made; a later
        # reconcile of the current boot retries.
        {:error, :workspace_source_unconfirmed}
    end
  end

  defp begin_workspace_source(config, pool, spec, expected, directory, digest) do
    with :ok <- readiness_claim(config, pool, spec, expected),
         {:ok, boot} <- Boot.current(directory, spec.id, expected),
         {:ok, previous} <-
           Lilly.Lifecycle.Journal.load(
             Lilly.Lifecycle.WorkspaceSource,
             directory,
             "workspace-source.json"
           ) do
      payload = previous && previous.payload

      cond do
        WorkspaceSource.settled?(payload, boot, digest) ->
          {:ok, :settled}

        WorkspaceSource.same_boot?(payload, boot, digest) and
            is_integer(payload["attempts"]) ->
          attempts = payload["attempts"] + 1

          with :ok <-
                 write_workspace_source_state(
                   directory,
                   WorkspaceSource.payload(
                     config.network.host_id,
                     boot,
                     :delivering,
                     attempts,
                     digest
                   )
                 ),
               do: {:ok, boot, attempts}

        true ->
          with :ok <-
                 write_workspace_source_state(
                   directory,
                   WorkspaceSource.payload(config.network.host_id, boot, :pending, 0, digest)
                 ),
               :ok <-
                 write_workspace_source_state(
                   directory,
                   WorkspaceSource.payload(config.network.host_id, boot, :delivering, 1, digest)
                 ),
               do: {:ok, boot, 1}
      end
    else
      _ -> {:error, :workspace_source_fenced}
    end
  end

  defp write_workspace_source_state(directory, payload) do
    with {:ok, lock} <- Lilly.Host.Lock.acquire(Path.join(directory, "audit-lock"), 2000) do
      try do
        Lilly.Lifecycle.Journal.write(
          Lilly.Lifecycle.WorkspaceSource,
          directory,
          "workspace-source.json",
          payload
        )
      after
        Lilly.Host.Lock.release(lock)
      end
    end
  end

  defp workspace_source_event(vm_id, placement_id, result, recorded) do
    if OverallsProtocol.uuid?(vm_id) and OverallsProtocol.uuid?(placement_id) do
      case {result, recorded} do
        {:ok, :ok} ->
          Lilly.Events.emit("lilly.workspace_source_delivered",
            vm_id: vm_id,
            placement_id: placement_id
          )

        {:ok, _} ->
          Lilly.Events.emit("lilly.workspace_source_delivery_failed",
            vm_id: vm_id,
            placement_id: placement_id,
            reason: :workspace_source_fenced
          )

        {{:error, reason}, _} ->
          Lilly.Events.emit("lilly.workspace_source_delivery_failed",
            vm_id: vm_id,
            placement_id: placement_id,
            reason: workspace_source_reason(reason)
          )
      end
    end

    if result == :ok and recorded == :ok, do: :ok, else: {:error, :workspace_source_unconfirmed}
  end

  defp workspace_source_reason(reason)
       when reason in [
              :workspace_source_conflict,
              :workspace_source_rejected,
              :workspace_source_unconfirmed,
              :workspace_source_fenced
            ],
       do: reason

  defp workspace_source_reason(_), do: :workspace_source_unconfirmed

  # @cc [owner:ghuntley,label:security;recovery] readiness-boot-receipt-after-current-authority
  # ready_boot/4 MUST return only the guest UUID verified against local boot
  # challenge and current confined execution before and after its bounded wait.
  # The placement lock MUST NOT be held across that wait.
  # Each authority check MUST tolerate definite placement-lock contention for
  # up to two seconds within the original readiness deadline. Waiting MUST NOT
  # reuse earlier authority or return success after that deadline.
  # SMTP delivery MUST keep its existing ten-minute maximum even when the
  # Inception core readiness budget is longer.
  # Native kernel evidence and readiness MUST name the same guest boot UUID;
  # matching the host challenge alone MUST NOT join two distinct guest boots.
  @doc "Return the verified guest boot ID after rechecking the same local launch authority."
  @spec ready_boot(Config.t(), Pool.t(), Spec.t(), keyword()) ::
          {:ok, OverallsProtocol.uuid()} | {:error, atom()}
  def ready_boot(config, pool, spec, options) do
    expected = revision(options)
    deadline = System.monotonic_time(:millisecond) + Keyword.get(options, :timeout, 120_000)

    with {:ok, capabilities} <- guest_capabilities(pool, spec),
         :ok <- readiness_capability(capabilities),
         :ok <-
           locked(config, spec, min(remaining(deadline), 2000), fn ->
             readiness_claim(config, pool, spec, expected)
           end),
         {:ok, boot} <- Boot.current(directory(config, spec), spec.id, expected),
         {:ok, kernel_boot_id} <-
           verify_native_kernel(
             pool,
             spec,
             boot,
             min(remaining(deadline), native_attestation_timeout(config, spec))
           ),
         :ok <- deliver_credentials(config, pool, spec, boot, min(remaining(deadline), 600_000)),
         {:ok, boot_id} <-
           Readiness.wait(
             Path.join(Jail.root(pool, spec), "v.sock"),
             Boot.expectation(boot),
             remaining(deadline)
           ),
         :ok <- same_attested_boot(kernel_boot_id, boot_id),
         true <- Map.get(boot, :guest_boot_id, boot_id) == boot_id,
         :ok <-
           locked(config, spec, min(remaining(deadline), 2000), fn ->
             with :ok <- readiness_claim(config, pool, spec, expected),
                  {:ok, ^boot} <- Boot.current(directory(config, spec), spec.id, expected) do
               Boot.record_boot_id(directory(config, spec), boot, boot_id)
             else
               _ -> {:error, :readiness_unconfirmed}
             end
           end),
         true <- remaining(deadline) > 0 do
      {:ok, boot_id}
    else
      false -> {:error, :readiness_timeout}
      error -> error
    end
  end

  @spec readiness_capability(OverallsProtocol.GuestAgents.capabilities()) ::
          :ok | {:error, :guest_agents_unavailable}
  defp readiness_capability(capabilities) do
    if capabilities.readiness,
      do: :ok,
      else: {:error, :guest_agents_unavailable}
  end

  # Native guests expose a kernel identity probe before the ordinary readiness
  # exchange. A missing or mismatched descriptor/evidence fails closed. Retain
  # the observed guest boot UUID so readiness cannot substitute a different
  # boot. Linux and agentless firmware have no native kernel evidence.
  @spec verify_native_kernel(Pool.t(), Spec.t(), Boot.t(), pos_integer()) ::
          {:ok, OverallsProtocol.uuid() | nil} | {:error, atom()}
  defp verify_native_kernel(pool, spec, boot, timeout) do
    with {:ok, bundle} <- guest_bundle(pool, spec),
         {:ok, os} <- native_os(bundle),
         kernel when is_map(kernel) <- Map.get(bundle, :kernel),
         digest when is_binary(digest) <- Map.get(kernel, :sha256),
         true <- timeout > 0,
         {:ok, boot_id} <-
           KernelAttestation.verify(
             Path.join(Lilly.VM.Jail.root(pool, spec), "v.sock"),
             Map.merge(Boot.expectation(boot), %{os: os, kernel_sha256: digest}),
             timeout
           ) do
      {:ok, boot_id}
    else
      {:error, :not_native} -> {:ok, nil}
      _ -> {:error, :kernel_attestation_unconfirmed}
    end
  end

  @spec same_attested_boot(OverallsProtocol.uuid() | nil, OverallsProtocol.uuid()) ::
          :ok | {:error, :kernel_attestation_unconfirmed}
  defp same_attested_boot(nil, _boot_id), do: :ok
  defp same_attested_boot(boot_id, boot_id), do: :ok
  defp same_attested_boot(_, _), do: {:error, :kernel_attestation_unconfirmed}

  defp guest_bundle(pool, spec),
    do: Lilly.VM.WorkloadBundle.load(Lilly.Host.ZFSDataset.directory(pool, spec), spec)

  defp native_os(%{os: os}) when os in [:freebsd, :illumos], do: {:ok, os}
  defp native_os(_), do: {:error, :not_native}

  defp native_attestation_timeout(_config, _spec), do: 120_000

  # @cc [owner:ghuntley,label:security;recovery] inception-smtp-current-execution
  # configure/4 MUST derive the destination from the owned placement and recheck
  # current confined execution and the same boot on both sides of delivery.
  # Credential rotation MUST NOT stop a VM or change its execution authority.
  @spec configure(Config.t(), Pool.t(), Spec.t(), keyword()) :: result()
  def configure(config, pool, spec, options) do
    expected = revision(options)

    with :ok <- locked(config, spec, fn -> readiness_claim(config, pool, spec, expected) end),
         {:ok, boot} <- Boot.current(directory(config, spec), spec.id, expected),
         :ok <-
           deliver_credentials(config, pool, spec, boot, Keyword.get(options, :timeout, 5000)) do
      locked(config, spec, fn ->
        with :ok <- readiness_claim(config, pool, spec, expected),
             {:ok, ^boot} <- Boot.current(directory(config, spec), spec.id, expected),
             do: :ok,
             else: (_ -> {:error, :inception_credentials_unavailable})
      end)
    end
  end

  # @cc [owner:ghuntley,label:security] inception-publication-confined-boot
  # Polling MUST require an owned Inception placement and current confined VMM
  # before and after the exchange. The boot record MUST remain identical and
  # the placement lock MUST NOT be held while waiting on the guest. Neither
  # configuration delivery nor publication may create launch authority.
  @spec inception_publication(Config.t(), Pool.t(), Spec.t(), map(), keyword()) ::
          {:ok, map()} | {:error, atom()}
  def inception_publication(
        config,
        pool,
        %{network: %{profile: :inception}} = spec,
        %{label: label, zone: zone, generation: generation} = namespace,
        options
      ) do
    expected = revision(options)
    deadline = System.monotonic_time(:millisecond) + 5000

    with :ok <- locked(config, spec, fn -> readiness_claim(config, pool, spec, expected) end),
         {:ok, boot} <- Boot.current(directory(config, spec), spec.id, expected),
         {:ok, publication} <-
           Lilly.VM.InceptionExchange.poll(
             Path.join(Jail.root(pool, spec), "v.sock"),
             Boot.expectation(boot),
             label,
             zone,
             generation,
             remaining(deadline),
             Map.get(namespace, :public),
             Map.get(namespace, :observations),
             Map.get(namespace, :parent)
           ),
         :ok <-
           locked(config, spec, fn ->
             with :ok <- readiness_claim(config, pool, spec, expected),
                  {:ok, ^boot} <- Boot.current(directory(config, spec), spec.id, expected),
                  true <- remaining(deadline) > 0 do
               :ok
             else
               _ -> {:error, :inception_exchange_unavailable}
             end
           end) do
      {:ok, publication}
    end
  end

  def inception_publication(_, _, _, _, _), do: {:error, :inception_exchange_unavailable}

  defp bootstrap_inputs(config, %{network: %{profile: :inception}} = spec) do
    with true <- spec.image_id == config.inception_image_id,
         true <-
           is_nil(config.inception_proof_file) or
             Lilly.Host.InceptionProof.image_id(config) == spec.image_id,
         {:ok, _} <- Credentials.load(config.inception_smtp_file),
         do: :ok,
         else: (_ -> {:error, :inception_credentials_unavailable})
  end

  defp bootstrap_inputs(_, _), do: :ok

  defp deliver_credentials(config, pool, %{network: %{profile: :inception}} = spec, boot, timeout) do
    with :ok <- bootstrap_inputs(config, spec),
         {:ok, bundle} <- Credentials.load(config.inception_smtp_file) do
      Credentials.deliver(
        Path.join(Jail.root(pool, spec), "v.sock"),
        Boot.expectation(boot),
        bundle,
        timeout
      )
    end
  end

  defp deliver_credentials(_, _, _, _, _), do: :ok
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  # @cc [owner:ghuntley,label:security] roster-bootstrap-fenced-physical-boot
  # boot_proof/4 MUST verify owned specification, exact running intent with the
  # current boot record and full VMM confinement under the placement lock, and
  # recheck intent after observation. It returns only the verified VMM PID and
  # unit cgroup (for the exit watcher); no readiness result or launch mutation is
  # produced. Lock contention for more than one second MUST report
  # :execution_unavailable (inconclusive), never a proof.
  @spec boot_proof(Config.t(), Pool.t(), Spec.t(), keyword()) ::
          {:ok, %{pid: pos_integer(), cgroup: Path.t()}} | {:error, atom()}
  def boot_proof(config, pool, spec, options) do
    locked_value(config, spec, 1000, fn ->
      expected = revision(options)
      directory = directory(config, spec)

      with :ok <- existing_claim(config, pool, spec),
           {:ok, _} <- Boot.current(directory, spec.id, expected),
           {:ok, vmm} <- Observation.vmm(config, pool, spec),
           {:ok, _} <- Boot.current(directory, spec.id, expected) do
        {:ok, vmm}
      else
        _ -> {:error, :readiness_unconfirmed}
      end
    end)
  end

  defp readiness_claim(config, pool, spec, expected) do
    case readiness_stage(config, pool, spec, expected) do
      :ok -> :ok
      {:error, _} -> {:error, :readiness_unconfirmed}
    end
  end

  # The confined-authority proof behind readiness_claim/4, naming the first
  # failing part as a trust stage.
  defp readiness_stage(config, pool, spec, expected) do
    with {:claim, :ok} <- {:claim, existing_claim(config, pool, spec)},
         {:boot, {:ok, _}} <-
           {:boot, Boot.current(directory(config, spec), spec.id, expected)},
         {:vmm, true} <- {:vmm, Observation.running?(config, pool, spec)} do
      :ok
    else
      {:claim, _} -> {:error, :trust_claim_mismatch}
      {:boot, _} -> {:error, :trust_boot_unconfirmed}
      {:vmm, _} -> {:error, :trust_vmm_unconfirmed}
    end
  end

  # @cc [owner:ghuntley,label:security] launch-stage-diagnostics-are-bounded
  # Launch failure diagnostics MUST expose only the fixed stage, local error
  # atom and VM identifier, never host command output, images or console bytes.
  # Expected pool-lock contention MUST remain a quiet retry.
  defp launch_step(:ok, _spec, _stage), do: :ok
  defp launch_step({:ok, _} = result, _spec, _stage), do: result
  defp launch_step({:error, :storage_busy} = result, _spec, _stage), do: result

  defp launch_step({:error, reason} = result, spec, stage) do
    Lilly.Events.emit("vm.launch_preparation_failed",
      vm_id: spec.id,
      stage: stage,
      reason: reason
    )

    result
  end

  defp launched(nil, _intent), do: :ok

  # @cc [owner:ghuntley,label:recovery;observability] launch-confirmed-after-authority
  # vm.launched MUST be emitted only after the durable launch-attempt authority
  # was persisted and the privileged unit start was confirmed, carrying the
  # placement/epoch/generation correlation identity and no other payload.
  defp launched(vm_id, intent) do
    Lilly.Events.emit("vm.launched",
      vm_id: vm_id,
      placement_id: intent.placement_id,
      execution_epoch: intent.execution_epoch,
      generation: intent.generation
    )

    :ok
  end

  # @cc [owner:ghuntley,label:recovery] stop-fences-before-cleanup
  # stop/4 MUST publish non-running launch intent before shutdown and return :ok only after
  # physical stop, jail cleanup and network detach are confirmed; normal stop must retain the
  # persistent disk and bounded private boot log until the next launch or deletion.
  @spec stop(Config.t(), Pool.t(), Spec.t(), keyword()) :: result()
  def stop(config, pool, spec, options \\ []) do
    vm_id = Keyword.get(options, :vm_id)

    locked(config, spec, fn ->
      with :ok <- claim(config, pool, spec),
           {:ok, intent} <-
             Intent.set(
               directory(config, spec),
               spec.id,
               revision(options),
               :stopped
             ),
           :ok <- shutdown(config, pool, spec, intent, vm_id),
           :ok <- Jail.cleanup(pool, spec, vm_id),
           :ok <- Lilly.Network.detach(config.network, spec.network, vm_id),
           :ok <- retire_checkpoints(pool, spec),
           :ok <- Provisioning.cancel(config, spec, revision(options)) do
        stopped(vm_id, intent)
      end
    end)
  end

  defp retire_checkpoints(pool, spec), do: retire_checkpoints(pool, spec, 60)

  defp retire_checkpoints(pool, spec, attempts) when attempts > 0 do
    case CheckpointStorage.retire(pool, spec) do
      {:error, :checkpoint_unconfirmed} when attempts > 1 ->
        Process.sleep(1_000)
        retire_checkpoints(pool, spec, attempts - 1)

      result ->
        result
    end
  end

  defp stopped(nil, _intent), do: :ok

  defp stopped(vm_id, intent) do
    Lilly.Events.emit("vm.stopped",
      vm_id: vm_id,
      placement_id: intent.placement_id,
      execution_epoch: intent.execution_epoch
    )

    :ok
  end

  @doc "Adopt a proven running VM without requiring its image to be staged again."
  # @cc [owner:ghuntley,label:security] adoption-requires-physical-identity
  # adopt/4 MUST require the existing immutable VM claim and a proven confined running VMM before
  # adopting its generation. A missing staged boot image alone must not prevent adoption of that
  # already running VM. Enabled Brady may refresh only its owned flow-label table
  # under the VM/network locks, with confinement verified before and after.
  @spec adopt(Config.t(), Pool.t(), Spec.t(), keyword()) :: result()
  def adopt(config, pool, spec, options) do
    vm_id = Keyword.get(options, :vm_id)

    result =
      locked(config, spec, 2000, fn ->
        with :ok <- adoption_claim(config, pool, spec),
             :ok <- adoption_observation(config, pool, spec),
             {:ok, intent} <-
               Intent.set(
                 directory(config, spec),
                 spec.id,
                 revision(options),
                 :running
               ),
             :ok <- preserve_running_boot(config, spec, intent),
             :ok <- Lilly.Network.refresh_labels(config.network, spec.network, intent),
             :ok <-
               if(is_nil(config.network.brady),
                 do: :ok,
                 else: adoption_observation(config, pool, spec)
               ) do
          adopted(vm_id, spec.id)
        end
      end)

    case result do
      :ok ->
        :ok

      {:error, reason} = error ->
        Lilly.Events.emit("vm.adoption_unconfirmed",
          vm_id: vm_id || spec.id,
          placement_id: spec.id,
          reason: reason
        )

        error
    end
  end

  # @cc [owner:ghuntley,label:security;recovery] running-boot-before-generation-readiness
  # Callers MUST hold placement ownership and prove the confined running VMM.
  # Advancing logical generation MUST retain the same physical boot challenge
  # and epoch before current-generation trust/readiness checks. Missing or
  # unreadable boot state MUST refuse; it never creates a boot proof or bypasses
  # current/3 verification.
  @spec preserve_running_boot(Config.t(), Spec.t(), Intent.t()) :: result()
  defp preserve_running_boot(config, spec, intent) do
    path = directory(config, spec)

    case Boot.read(path) do
      {:ok, %{} = _boot} ->
        case Boot.adopt_generation(path, intent) do
          {:ok, _} -> :ok
          error -> error
        end

      _ ->
        {:error, :boot_identity_unconfirmed}
    end
  end

  defp adoption_claim(config, pool, spec) do
    case existing_claim(config, pool, spec) do
      :ok -> :ok
      _ -> {:error, :vm_claim_unconfirmed}
    end
  end

  defp adoption_observation(config, pool, spec) do
    if Observation.running?(config, pool, spec),
      do: :ok,
      else: {:error, :physical_identity_unconfirmed}
  end

  defp adopted(nil, _placement), do: :ok

  # Reconciliation re-adopts a running VM every second; announce each
  # placement's adoption once per Lilly boot instead of on every pass.
  defp adopted(vm_id, placement) do
    key = {__MODULE__, :adopted, vm_id, placement}

    unless :persistent_term.get(key, false) do
      :persistent_term.put(key, true)
      Lilly.Events.emit("vm.adopted", vm_id: vm_id, placement_id: placement)
    end

    :ok
  end

  @doc "Destroy the disk only after process, mount and TAP cleanup is confirmed."
  # @cc [owner:ghuntley,label:recovery] delete-compute-before-disk
  # delete/4 MUST durably forbid future launches before cleanup and destroy the disk only after
  # the process, jail mounts and TAP have been cleaned up; any unconfirmed step must prevent
  # successful deletion. One bounded idempotent disk retry may absorb delayed kernel mount
  # teardown after every higher-level execution fence and cleanup has already succeeded.
  # The actor delays subsequent cleanup-failed reconciliations up to thirty seconds.
  @spec delete(Config.t(), Pool.t(), Spec.t(), keyword()) :: result()
  def delete(config, pool, spec, options \\ []) do
    vm_id = Keyword.get(options, :vm_id)

    locked(config, spec, fn ->
      with :ok <- claim(config, pool, spec),
           {:ok, intent} <-
             Intent.set(
               directory(config, spec),
               spec.id,
               revision(options),
               :deleted
             ),
           :ok <-
             PrivateFiles.write(
               directory(config, spec),
               "deleted.json",
               JSON.encode!(identity(config, pool, spec))
             ),
           :ok <- shutdown(config, pool, spec, intent, vm_id),
           :ok <- Jail.cleanup(pool, spec, vm_id),
           :ok <- Lilly.Network.detach(config.network, spec.network, vm_id),
           :ok <- remove_log(Unit.boot_log(config, spec)),
           :ok <- retire_checkpoints(pool, spec),
           :ok <- delete_disk(pool, spec),
           :ok <- Provisioning.cancel(config, spec, revision(options)) do
        deleted(vm_id, spec.id)
      end
    end)
  end

  defp delete_disk(pool, spec) do
    case Disk.delete(pool, spec) do
      {:error, :zfs_dataset_cleanup_unconfirmed} ->
        Process.sleep(100)
        Disk.delete(pool, spec, 2000)

      result ->
        result
    end
  end

  defp deleted(nil, _placement), do: :ok

  defp deleted(vm_id, placement) do
    Lilly.Events.emit("vm.deleted", vm_id: vm_id, placement_id: placement)

    :ok
  end

  @doc "Fence this generation before proving failure; no late start may consume released compute."
  # @cc [owner:ghuntley,label:recovery] failure-fence-precedes-release-proof
  # fail/4 MUST fence its exact epoch/generation before proving the unit empty and cleaning
  # mounts/network, so a delayed launch cannot consume compute later released for this failure.
  # The bounded private boot log MUST survive failure cleanup until the next
  # launch or deletion; raw bytes MUST NOT enter application diagnostics.
  @spec fail(Config.t(), Pool.t(), Spec.t(), keyword()) :: result()
  def fail(config, pool, spec, options) do
    vm_id = Keyword.get(options, :vm_id)

    locked(config, spec, fn ->
      with :ok <- cleanup_step(fn -> claim(config, pool, spec) end, vm_id, spec.id, :claim),
           {:ok, intent} <-
             cleanup_step(
               fn ->
                 Intent.set(
                   directory(config, spec),
                   spec.id,
                   revision(options),
                   :failed
                 )
               end,
               vm_id,
               spec.id,
               :intent
             ),
           :ok <-
             cleanup_step(
               fn -> shutdown(config, pool, spec, intent, vm_id, :force) end,
               vm_id,
               spec.id,
               :unit
             ),
           :ok <- cleanup_step(fn -> Jail.cleanup(pool, spec, vm_id) end, vm_id, spec.id, :jail),
           :ok <-
             cleanup_step(
               fn -> Lilly.Network.detach(config.network, spec.network, vm_id) end,
               vm_id,
               spec.id,
               :network
             ),
           do:
             cleanup_step(
               fn -> Provisioning.fail(config, spec, revision(options)) end,
               vm_id,
               spec.id,
               :provisioning
             )
    end)
  end

  defp cleanup_step(fun, vm_id, placement, stage) do
    case fun.() do
      :ok ->
        :ok

      {:ok, _} = result ->
        result

      error ->
        reason =
          case error do
            {:error, reason} when is_atom(reason) -> reason
            _ -> :cleanup_unconfirmed
          end

        Lilly.Events.emit("vm.failure_cleanup_unconfirmed",
          vm_id: vm_id,
          placement_id: placement,
          stage: stage,
          reason: reason
        )

        {:error, reason}
    end
  end

  # @cc [owner:ghuntley,label:security;recovery] paused-terminal-cleanup-never-promotes-capture
  # Terminal cleanup MUST re-read its exact durable intent and verify the local
  # checkpoint journal and fully confined Paused process before forced termination.
  # Capturing never becomes copied/ready through cleanup. Only proven absence
  # permits the caller to detach networking or retire checkpoint storage.
  @spec discard_paused(Config.t(), Pool.t(), Spec.t(), Intent.t()) :: result()
  defp discard_paused(config, pool, spec, intent) do
    with %Lilly.Host.Lease{} <- Lock.current(),
         {:ok, ^intent} <- Intent.read(directory(config, spec)),
         {:ok, record} <- Checkpoint.read(pool, spec.id),
         true <- Checkpoint.discardable_pause?(record, pool, spec, intent),
         {:ok, _} <- Observation.check_state(config, pool, spec, [:paused]),
         do: Unit.kill_paused(spec),
         else: (_ -> {:error, :checkpoint_unconfirmed})
  end

  defp shutdown(config, pool, spec, intent, vm_id, mode \\ :graceful) do
    case Unit.status(spec) do
      {:ok, :stopped} ->
        :ok

      {:ok, :running} ->
        case API.state(api_path(pool, spec), spec.id) do
          {:ok, :paused} -> discard_paused(config, pool, spec, intent)
          _ -> shutdown_running(pool, spec, vm_id, mode)
        end

      _ ->
        Lilly.Events.emit("lilly.unit_stop_unconfirmed",
          vm_id: vm_id || spec.id,
          placement_id: spec.id,
          reason: :stop_unconfirmed
        )

        {:error, :stop_unconfirmed}
    end
  end

  defp shutdown_running(_pool, spec, vm_id, :force), do: Unit.stop(spec, vm_id)

  defp shutdown_running(pool, spec, _vm_id, :graceful) do
    case API.shutdown(api_path(pool, spec)) do
      :ok -> await_shutdown(spec, System.monotonic_time(:millisecond) + 30_000)
      _ -> Unit.stop(spec)
    end
  end

  defp await_shutdown(spec, deadline) do
    case Unit.status(spec) do
      {:ok, :stopped} ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          Unit.stop(spec)
        else
          receive do
          after
            100 -> await_shutdown(spec, deadline)
          end
        end
    end
  end

  # @cc [owner:ghuntley,label:recovery] lifecycle-success-is-explicit
  # Ordinary lifecycle callbacks MUST return :ok explicitly. A successful
  # intermediate probe returned by a failed with guard MUST NOT become success.
  # Only the transfer entry point accepts a value after its explicit guards.
  defp locked(config, spec, fun), do: locked(config, spec, 0, fun)

  defp locked(config, spec, retry_ms, fun) do
    locked_value(config, spec, retry_ms, fn ->
      case fun.() do
        :ok -> :ok
        {:error, reason} when is_atom(reason) -> {:error, reason}
        _ -> {:error, :execution_unconfirmed}
      end
    end)
  end

  defp locked_value(config, spec, fun), do: locked_value(config, spec, 0, fun)

  defp locked_value(config, spec, retry_ms, fun) do
    with {:ok, %File.Stat{uid: 0}} <- Lilly.Host.Privilege.stat("/proc/self"),
         :ok <- PrivateFiles.directory(config.state_dir),
         :ok <- PrivateFiles.directory(directory(config, spec)),
         {:ok, port} <- Lock.acquire(Path.join(directory(config, spec), "lock"), retry_ms) do
      try do
        fun.()
      after
        Lock.release(port)
      end
    else
      _ -> {:error, :execution_unavailable}
    end
  end

  # @cc [owner:ghuntley,label:recovery;concurrency] launch-commit-check
  # launch/5 MUST call the caller's commit check exactly once, after every
  # preparation step and immediately before persisting launch-attempt.bin. A
  # refusal MUST return {:error, :preempted} without persisting the attempt or
  # starting the unit; without a check the launch commits as before (ADR-0176).
  defp commit(options) do
    case Keyword.get(options, :commit) do
      nil -> :ok
      check when is_function(check, 0) -> if check.() == :ok, do: :ok, else: {:error, :preempted}
    end
  end

  defp revision(options),
    do: {Keyword.get(options, :execution_epoch, 1), Keyword.get(options, :generation)}

  defp directory(config, spec), do: Path.join(config.state_dir, spec.id)

  defp not_attempted(config, spec, intent) do
    path = Path.join(directory(config, spec), "launch-attempt.bin")

    case Lilly.Host.Privilege.lstat(path) do
      {:error, :enoent} ->
        :ok

      {:ok, _} ->
        with {:ok, <<placement::binary-size(36), epoch::64, previous::64>>} <-
               PrivateFiles.read_secret(path),
             true <-
               placement == intent.placement_id and epoch in 1..9_223_372_036_854_775_807 and
                 previous in 1..9_223_372_036_854_775_807 and
                 {epoch, previous} < {intent.execution_epoch, intent.generation},
             do: :ok,
             else: (_ -> {:error, :launch_already_attempted})

      _ ->
        {:error, :launch_already_attempted}
    end
  end

  defp identity(config, pool, spec) do
    common = %{
      "version" => 1,
      "host_id" => config.network.host_id,
      "pool_path" => pool.path,
      "filesystem_id" => pool.filesystem_id,
      "spec" => Spec.encode(spec)
    }

    Map.put(common, "storage", OverallsProtocol.Storage.encode(pool.storage))
  end

  defp claim(config, pool, spec) do
    case Lilly.Host.Privilege.lstat(Path.join(directory(config, spec), "vm.json")) do
      {:error, :enoent} ->
        with {:ok, :stopped} <- Unit.status(spec),
             true <-
               Enum.all?(
                 [Jail.root(pool, spec), Path.dirname(Disk.path(pool, spec))],
                 &(Lilly.Host.Privilege.lstat(&1) == {:error, :enoent})
               ),
             do:
               PrivateFiles.write(
                 directory(config, spec),
                 "vm.json",
                 JSON.encode!(identity(config, pool, spec))
               )

      {:ok, _} ->
        existing_claim(config, pool, spec)

      _ ->
        :error
    end
  end

  defp existing_claim(config, pool, spec) do
    with {:ok, bytes} <- PrivateFiles.read_secret(Path.join(directory(config, spec), "vm.json")),
         {:ok, value} <- JSON.decode(bytes),
         true <- value == identity(config, pool, spec),
         do: :ok
  end

  defp remove_log(path) do
    case File.rm(path) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      error -> error
    end
  end

  defp remove_socket(path) do
    case Lilly.Host.Privilege.lstat(path) do
      {:error, :enoent} -> :ok
      {:ok, %File.Stat{type: :other, uid: 0}} -> File.rm(path)
      _ -> :error
    end
  end
end
