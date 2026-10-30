defmodule Lilly.Host.ImageTemplate do
  @moduledoc "Sealed per-pool artifacts with native leases and conservative bounded storage."
  require Lilly.Events

  alias Lilly.Host.{
    Command,
    Image,
    Lock,
    Pool,
    PrivateFiles,
    Storage,
    ZFS,
    ZFSDataset,
    ZFSNamespaceMounts
  }

  alias Lilly.Lifecycle.{ImageTemplate, Journal}
  @timeout 300_000
  @catalog_limit 4096
  @type result :: :ok | {:error, atom()}

  # @cc [owner:ghuntley,label:security;concurrency] template-reader-authority
  # The callback MUST run only with a freshly hashed image or an exact ready
  # incarnation under a native shared lease. Seal, ownership, GUID and file
  # identities MUST be checked before use. The lease covers utility children;
  # callers copy bytes outside the pool lock so its release cannot outlive I/O.
  # A returned template image MUST carry the exact validated record and
  # incarnation UUIDs; verified uncached images MUST carry neither.
  @spec with_image(Pool.t(), Image.t(), (Image.t() -> result())) :: result()
  def with_image(pool, image, fun) do
    case ensure(pool, image) do
      :ok ->
        result =
          lease(pool, image.id, :shared, fn ->
            with {:ok, record} when not is_nil(record) <- current(pool, image.id),
                 "ready" <- record.payload["state"] do
              case validate_ready(pool, record.payload) do
                {:ok, sealed} ->
                  lease =
                    Path.join([
                      base(pool),
                      "locks",
                      String.replace_prefix(image.id, "sha256:", ""),
                      "owner.lock"
                    ])

                  with :ok <- touch(pool, record.payload),
                       do:
                         fun.(%{
                           sealed
                           | source_lease: lease,
                             template_record_id: record.id,
                             template_incarnation: record.payload["incarnation"]
                         })

                {:error, :storage_busy} ->
                  {:error, :storage_busy}

                _ ->
                  {:quarantine, record.payload["incarnation"]}
              end
            else
              _ -> {:error, :template_unconfirmed}
            end
          end)

        case result do
          {:quarantine, id} ->
            lease(pool, image.id, :exclusive, fn ->
              with {:ok, record} when not is_nil(record) <- current(pool, image.id),
                   true <- record.payload["incarnation"] == id,
                   do: quarantine(pool, record.payload, :ready_validation)
            end)

          other ->
            other
        end

      :uncached ->
        verified(image, fun)

      error ->
        error
    end
  end

  defp verified(image, fun) do
    with {:ok, verified} <- Image.load(image.path),
         true <- verified.id == image.id,
         do: fun.(verified),
         else: (_ -> {:error, :invalid_local_image})
  end

  @doc "Use an immutable configured image without creating a ZFS template."
  @spec with_uncached_image(Image.t(), (Image.t() -> result())) :: result()
  def with_uncached_image(image, fun), do: immutable_verified(image, fun)

  defp immutable_verified(image, fun) do
    with {:ok, verified} <- Image.load_immutable(image.path),
         true <- verified.id == image.id,
         do: fun.(verified),
         else: (_ -> {:error, :invalid_local_image})
  end

  defp validate_ready(pool, value) do
    with :ok <- native(pool, value, :on),
         {:ok, files} <- File.ls(directory(pool, value)),
         {:ok, sealed} <- Image.sealed(directory(pool, value), value["identities"]),
         true <- Enum.sort(files) == Enum.sort(Image.file_names(sealed)),
         true <- sealed.id == value["image_id"],
         :ok <- native(pool, value, :on) do
      {:ok, sealed}
    else
      {:error, :storage_busy} -> {:error, :storage_busy}
      _ -> {:error, :template_unconfirmed}
    end
  end

  # @cc [owner:ghuntley,label:recovery;capacity] template-single-builder
  # A builder MUST own the image's exclusive lease and, in a BEAM that runs the
  # TemplateSteward, MUST be that steward's single build for the pool and image
  # (template-build-single-flight). Reserve a bounded artifact
  # charge and create intent under the pool lock before native creation. Bulk
  # staging/hashing MUST occur outside that lock. Images larger than the positive
  # per-pool budget use the verified uncached path; corrupt or uncertain
  # incarnations fail closed.
  @doc "Whether the image's artifacts fit the pool's template budget (a size check, no hashing)."
  # @cc [owner:ghuntley,label:capacity] template-cacheable-is-a-size-check
  # cacheable?/2 MUST decide from the staged artifact sizes and the pool budget
  # alone, so callers can exclude an uncacheable image
  # without reading or hashing its bytes.
  @spec cacheable?(Pool.t(), Image.t()) :: boolean()
  def cacheable?(pool, image), do: bytes(image) <= pool.template_budget_bytes

  # A ready template is used without the steward; a miss waits for the one
  # build of this pool and image, by default for at most two minutes.
  @spec ensure(Pool.t(), Image.t(), pos_integer()) :: result() | :uncached
  def ensure(pool, image, wait_ms \\ 120_000) do
    cond do
      bytes(image) > pool.template_budget_bytes -> :uncached
      ready?(pool, image) -> :ok
      true -> Lilly.Host.TemplateSteward.ensure(pool, image, wait_ms)
    end
  end

  @doc false
  @spec build_now(Pool.t(), Image.t()) :: result()
  def build_now(pool, image), do: ensure_cached(pool, image) |> normalize()

  defp ready?(pool, image) do
    match?({:ok, %{state: :ready}}, current(pool, image.id)) and within_budget?(pool)
  end

  defp ensure_cached(pool, image) do
    # The read path never contends with another reader merely to establish that
    # a template exists. Failed validation is not converted to a cache miss.
    with {:ok, record} <- current(pool, image.id) do
      if record && record.state == :ready && within_budget?(pool) do
        :ok
      else
        lease(pool, image.id, :exclusive, fn ->
          with {:ok, record} <- reserve(pool, image),
               do: build(pool, image, record)
        end)
      end
    end
  end

  defp reserve(pool, image) do
    Storage.locked(
      pool,
      fn ->
        with :ok <- ZFSDataset.bind(pool),
             :ok <- directories(pool),
             {:ok, record} <- current(pool, image.id),
             {:ok, record} <- recover_retirement(pool, record) do
          if record do
            with :ok <- room(pool, 0), do: {:ok, record}
          else
            bytes = bytes(image)

            with :ok <- catalog_room(pool),
                 :ok <- room(pool, bytes),
                 id = Lilly.UUID.generate(),
                 value = %{
                   "state" => "staging",
                   "host_id" => pool.host_id,
                   "pool_id" => pool.id,
                   "image_id" => image.id,
                   "incarnation" => id,
                   "nonce" => Base.encode16(:crypto.strong_rand_bytes(32), case: :lower),
                   "guid" => nil,
                   "bytes" => bytes,
                   "identities" => %{}
                 },
                 :ok <- write(pool, value),
                 {:ok, record} <- load(pool, id) do
              {:ok, record}
            end
          end
        end
      end,
      1000,
      :template_reserve
    )
  end

  # A quarantined incarnation never becomes ready again. Reuse of the image
  # requires confirmed retirement and a fresh journal/nonce plus full hashing.
  defp recover_retirement(pool, %{state: state, payload: value})
       when state in [:quarantined, :retiring] do
    with :ok <- retire(pool, value), do: {:ok, nil}
  end

  defp recover_retirement(_, record), do: {:ok, record}

  defp bytes(image), do: Enum.sum(Enum.map(image.files, fn {_, {_, stat}} -> stat.size end))

  defp within_budget?(pool) do
    case records(pool) do
      {:ok, records} ->
        records
        |> Enum.reject(&(&1.state == :deleted))
        |> Enum.map(& &1.payload["bytes"])
        |> Enum.sum()
        |> Kernel.<=(pool.template_budget_bytes)

      _ ->
        false
    end
  end

  # Tombstones and interrupted empty publication directories are retained. The
  # catalog never grows past its scan bound, even when no artifact bytes remain.
  defp catalog_room(pool) do
    case File.ls(Path.join(base(pool), "records")) do
      {:ok, ids} when length(ids) < @catalog_limit -> :ok
      {:ok, _} -> :uncached
      _ -> {:error, :template_unconfirmed}
    end
  end

  defp build(pool, image, %{state: :staging, payload: value}) do
    with {:ok, guid} <- create(pool, value),
         :ok <- copy_files(pool, value, image),
         next = value |> Map.put("guid", guid) |> Map.put("state", "verifying"),
         :ok <- write(pool, next),
         {:ok, record} <- load(pool, next["incarnation"]) do
      build(pool, image, record)
    end
  end

  defp build(pool, image, %{state: :verifying, payload: value}) do
    with :ok <- native(pool, value, :off) do
      case Image.stage(directory(pool, value)) do
        {:ok, _staged} -> verify_hashed(pool, image, value)
        {:error, _reason} -> quarantine(pool, value, :verifying_image_stage)
      end
    else
      _ -> quarantine(pool, value, :verifying_native)
    end
  end

  defp build(pool, _image, %{state: :sealing, payload: value}) do
    with :ok <- native(pool, value, :either),
         {:ok, _} <- Image.sealed(directory(pool, value), value["identities"]),
         {:ok, _} <- Command.run(:zfs_set, ["readonly=on", name(pool, value)]),
         :ok <- native(pool, value, :on),
         {:ok, _} <- Image.sealed(directory(pool, value), value["identities"]),
         :ok <- write(pool, Map.put(value, "state", "ready")) do
      :ok
    else
      _ -> quarantine(pool, value, :sealing)
    end
  end

  defp build(_, _, %{state: :ready}), do: :ok
  defp build(_, _, _), do: {:error, :template_unconfirmed}

  defp verify_hashed(pool, image, value) do
    case Image.load(directory(pool, value)) do
      {:ok, staged} when staged.id == image.id ->
        if Enum.sort(Map.keys(staged.files)) == Enum.sort(Image.file_names(image)) do
          with :ok <- flush(directory(pool, value)),
               {:ok, identities} <- Image.identities(staged),
               next =
                 value |> Map.put("identities", identities) |> Map.put("state", "sealing"),
               :ok <- write(pool, next),
               {:ok, record} <- load(pool, next["incarnation"]) do
            build(pool, image, record)
          else
            _ -> quarantine(pool, value, :verifying_identities)
          end
        else
          quarantine(pool, value, :verifying_file_set)
        end

      {:ok, _staged} ->
        quarantine(pool, value, :verifying_image_id)

      {:error, _reason} ->
        quarantine(pool, value, :verifying_digest)
    end
  end

  defp quarantine(pool, value, stage) do
    Lilly.Events.emit("lilly.image_template_quarantined", pool_id: pool.id, stage: stage)

    with :ok <- write(pool, Map.put(value, "state", "quarantined")),
         do: {:error, :template_quarantined}
  end

  defp create(pool, value) do
    Storage.locked(
      pool,
      fn ->
        with :ok <- ZFSDataset.bind(pool),
             {:ok, owners} <- ZFS.owners(Pool.zfs_identity(pool)) do
          case owners[name(pool, value)] do
            nil ->
              with {:error, :enoent} <- Lilly.Host.Privilege.lstat(directory(pool, value)),
                   {:ok, _} <-
                     Command.run(:zfs_create, [
                       "-o",
                       "mountpoint=" <> directory(pool, value),
                       "-o",
                       "compression=lz4",
                       "-o",
                       "reservation=none",
                       "-o",
                       "refreservation=none",
                       "-o",
                       "quota=none",
                       "-o",
                       "refquota=none",
                       "-o",
                       "dedup=off",
                       "-o",
                       "sync=standard",
                       "-o",
                       "readonly=off",
                       "-o",
                       "canmount=on",
                       "-o",
                       "exec=off",
                       "-o",
                       "devices=off",
                       "-o",
                       "setuid=off",
                       "-o",
                       "lilly:host=" <> pool.host_id,
                       "-o",
                       "lilly:pool=" <> pool.id,
                       "-o",
                       "lilly:vm=-",
                       "-o",
                       "lilly:nonce=" <> value["nonce"],
                       name(pool, value)
                     ]),
                   :ok <- Lilly.Host.Privilege.claim_directory(directory(pool, value)),
                   :ok <- native(pool, value, :off),
                   do: ZFS.template_child(Pool.zfs_identity(pool), name(pool, value), nil, :off)

            owner ->
              with true <- owner?(owner, pool, value),
                   :ok <- remount(pool, value),
                   {:ok, _} <-
                     ZFS.template_child(
                       Pool.zfs_identity(pool),
                       name(pool, value),
                       value["guid"],
                       :off
                     ),
                   {:ok, %{type: :directory, uid: 0}} <-
                     Lilly.Host.Privilege.lstat(directory(pool, value)),
                   :ok <- Lilly.Host.Privilege.claim_directory(directory(pool, value)),
                   :ok <- native(pool, value, :off),
                   do: {:ok, owner["guid"]},
                   else: (_ -> {:error, :template_unconfirmed})
          end
        end
      end,
      1000,
      :template_create
    )
  end

  # @cc [owner:ghuntley,label:recovery] template-interrupted-create-remounts
  # A create interrupted after ZFS made the dataset but before it mounted
  # leaves an owned, unmounted template that accounting refuses. The builder,
  # holding the exclusive image lease and the pool lock, mounts only a child
  # whose owner already matched the staging record.
  defp remount(pool, value) do
    case Command.run(:zfs_get, ["-H", "-o", "value", "mounted", name(pool, value)]) do
      {:ok, "yes\n"} ->
        :ok

      {:ok, "no\n"} ->
        with {:ok, _} <- Command.run(:zfs_mount, [name(pool, value)]), do: :ok

      _ ->
        {:error, :template_unconfirmed}
    end
  end

  defp copy_files(pool, value, image) do
    with :ok <- PrivateFiles.directory(directory(pool, value)) do
      Enum.reduce_while(Image.file_names(image), :ok, fn file, :ok ->
        {source, stat} = Map.fetch!(image.files, file)
        target = Path.join(directory(pool, value), file)

        result =
          case Lilly.Host.Privilege.lstat(target) do
            {:error, :enoent} -> copy_file(source, target, stat.size, pool.image_io_timeout_ms)
            {:ok, %{type: :regular, uid: 0, links: 1, size: size}} when size == stat.size -> :ok
            _ -> {:error, :template_unconfirmed}
          end

        if result == :ok, do: {:cont, :ok}, else: {:halt, result}
      end)
    end
  end

  # @cc [owner:ghuntley,label:recovery] template-copy-durable
  # copy_file/4 MUST run the image copy as a durable hostd job keyed by its
  # source, pending path and size, so a copy in flight survives a Lilly
  # restart. It MUST attach to such a job before touching the pending file,
  # and remove a stale pending file only when no job is known for the key or
  # the known job finished with a utility failure (template-copy-failure-not-replayed).
  defp copy_file(source, target, size, timeout) do
    pending = target <> ".pending"
    arguments = ["copy", source, pending, Integer.to_string(size)]
    key = :crypto.hash(:sha256, Enum.join(["template-copy" | arguments], <<0>>))

    with {:ok, "copy\n"} <- durable_copy(pending, arguments, timeout, key),
         :ok <- Lilly.Host.Privilege.chmod(pending, 0o444),
         :ok <- flush(pending),
         {:ok, _} <- Command.run(:mv, ["--no-target-directory", "--", pending, target]),
         do: flush(Path.dirname(target))
  end

  @typep copy_ops :: %{
           attach: (<<_::256>>, 0..120_000 -> Command.durable_result()),
           run_durable: (Command.name(), [String.t()], pos_integer(), <<_::256>> ->
                           Command.durable_result()),
           remove_pending: (Path.t() -> :ok | {:error, atom()})
         }

  # A copy started before a Lilly restart still runs, or has finished, under
  # its key: wait for it. Otherwise clear any stale pending file and start one.

  # @cc [owner:ghuntley,label:recovery] template-copy-failure-not-replayed
  # durable_copy/5 MUST treat a finished copy job whose stored result is a
  # utility failure (failed, timed out, output limit or utility unavailable)
  # like an unknown job: clear the pending file and start one new copy under
  # the same key, returning that copy's result. Hostd keeps a finished result
  # attachable for ten minutes; replaying it MUST NOT fail later builds without
  # a copy. A running job (from attach or from the re-run) MUST surface as
  # :job_running and MUST NOT start a second copy; a stored success and every
  # other error are returned unchanged.
  @doc false
  @spec durable_copy(Path.t(), [String.t()], pos_integer(), <<_::256>>, copy_ops()) ::
          Command.durable_result()
  def durable_copy(pending, arguments, timeout, key, ops \\ default_copy_ops()) do
    case ops.attach.(key, min(timeout, 120_000)) do
      {:error, reason}
      when reason in [
             :job_unknown,
             :command_failed,
             :command_timeout,
             :command_output_limit,
             :utility_unavailable
           ] ->
        with :ok <- ops.remove_pending.(pending),
             do: ops.run_durable.(:image_copy, arguments, timeout, key)

      result ->
        result
    end
  end

  @spec default_copy_ops() :: copy_ops()
  defp default_copy_ops,
    do: %{
      attach: &Command.attach/2,
      run_durable: &Command.run_durable/4,
      remove_pending: &remove_pending/1
    }

  defp remove_pending(path) do
    case Lilly.Host.Privilege.lstat(path) do
      {:error, :enoent} ->
        :ok

      {:ok, %{type: :regular, uid: 0, links: 1}} ->
        with {:ok, _} <- Command.run(:rm, ["--", path]), do: :ok

      _ ->
        {:error, :template_unconfirmed}
    end
  end

  # @cc [owner:ghuntley,label:capacity;security] template-accounting-no-vm-credit
  # Every native template child MUST join an active durable incarnation and exact
  # owner nonce/GUID. Ready children MUST remain sealed. Unknown children and
  # missing confirmed templates withhold capacity; template bytes earn no VM credit.
  # `children` MUST be the pool-locked observation's template children: each
  # row's mountpoint, seal and GUID are joined from it (ADR-0152), so a pool
  # with many templates costs no per-template native command. The exec/setuid/
  # devices seal is checked when a template is sealed and when a reader validates it.
  @spec audit(Pool.t(), %{String.t() => ZFS.observed_child()}, map()) :: result()
  def audit(pool, children, owners) do
    with {:ok, records} <- records(pool),
         :ok <- audit_records(pool, records, children, owners),
         true <- Enum.all?(Map.keys(children), &private_directory?(pool, &1)),
         do: :ok,
         else: (_ -> {:error, :template_unconfirmed})
  end

  @typedoc "A durable template record: its lifecycle state and journal payload."
  @type template_record :: %{
          required(:state) => atom(),
          required(:payload) => map(),
          optional(atom()) => term()
        }

  # @cc [owner:ghuntley,label:capacity;security] template-audit-joins-observation
  # audit_records/4 is the pure join of durable records, owner tags and observed
  # rows. It MUST refuse every child without an active record, a foreign or
  # mismatched owner, a replaced GUID, a wrong mountpoint or an unsealed ready
  # template, and every confirmed record whose child is missing.
  @doc false
  @spec audit_records(Pool.t(), [template_record()], %{String.t() => ZFS.observed_child()}, map()) ::
          result()
  def audit_records(pool, records, children, owners) do
    identity = Pool.zfs_identity(pool)
    active = Enum.reject(records, &(&1.state == :deleted))
    known = Map.new(active, &{name(pool, &1.payload), &1.payload})

    if Enum.all?(children, fn {name, _child} ->
         value = known[name]

         value && owner?(owners[name], pool, value) &&
           match?(
             {:ok, _},
             ZFS.observed_artifact(
               identity,
               children,
               name,
               value["guid"],
               seal(value),
               :template
             )
           )
       end) and
         Enum.all?(known, fn {name, value} ->
           Map.has_key?(children, name) or value["state"] in ~w(staging retiring)
         end),
       do: :ok,
       else: {:error, :template_unconfirmed}
  end

  defp seal(%{"state" => "ready"}), do: :on
  defp seal(_), do: :either

  # The template directory stays root-owned and private (a local stat, not a
  # native command), exactly as the reader's native validation requires.
  defp private_directory?(pool, name) do
    id = String.replace_prefix(name, pool.storage.dataset <> "/template-", "")

    match?(
      {:ok, %{type: :directory, uid: 0, mode: mode}} when Bitwise.band(mode, 0o777) == 0o700,
      Lilly.Host.Privilege.lstat(Path.join([pool.path, "templates", id]))
    )
  end

  defp native(pool, value, seal) do
    with {:ok, _} <-
           ZFS.template_child(Pool.zfs_identity(pool), name(pool, value), value["guid"], seal),
         {:ok, owners} <- ZFS.owners(Pool.zfs_identity(pool)),
         true <- owner?(owners[name(pool, value)], pool, value),
         {:ok, %{type: :directory, uid: 0, mode: mode}} <-
           Lilly.Host.Privilege.lstat(directory(pool, value)),
         true <- Bitwise.band(mode, 0o777) == 0o700 do
      :ok
    else
      _ -> {:error, :template_unconfirmed}
    end
  end

  defp owner?(owner, pool, value) when is_map(owner) do
    owner["host"] == pool.host_id and owner["pool"] == pool.id and owner["vm"] == "-" and
      owner["nonce"] == value["nonce"] and
      (is_nil(value["guid"]) or owner["guid"] == value["guid"])
  end

  defp owner?(_, _, _), do: false

  defp room(pool, bytes) when bytes > pool.template_budget_bytes, do: :uncached

  defp room(pool, bytes) do
    with {:ok, records} <- records(pool) do
      active = Enum.reject(records, &(&1.state == :deleted))

      needed =
        Enum.sum(Enum.map(active, & &1.payload["bytes"])) + bytes - pool.template_budget_bytes

      remaining =
        active
        |> Enum.filter(&(&1.state in [:ready, :quarantined, :retiring]))
        |> Enum.sort_by(&last_used(pool, &1.payload))
        |> Enum.take(16)
        |> Enum.reduce_while(needed, fn record, remaining ->
          if remaining <= 0 do
            {:halt, remaining}
          else
            result =
              lease(pool, record.payload["image_id"], :exclusive, fn ->
                retire(pool, record.payload)
              end)

            {:cont, if(result == :ok, do: remaining - record.payload["bytes"], else: remaining)}
          end
        end)

      if remaining <= 0, do: :ok, else: :uncached
    end
  end

  # @cc [owner:ghuntley,label:capacity;recovery] template-unconfigured-retirement
  # retire_unconfigured/2 MUST retire only non-deleted incarnations whose image is
  # no longer configured, each under its image's exclusive lease and the pool
  # lock, after re-reading the record unchanged. An owned child left unmounted
  # by an interrupted build is mounted first so the ordinary ownership-checked
  # destroy can run. Templates of configured images are never touched; derived
  # VM disks are independent copies and are unaffected.
  @spec retire_unconfigured(Pool.t(), [String.t()]) :: {:ok, non_neg_integer()} | {:error, atom()}
  def retire_unconfigured(pool, configured) do
    result =
      with {:ok, records} <- records(pool) do
        # One incarnation's failure never stops the others from retiring.
        records
        |> Enum.reject(&(&1.state == :deleted or &1.payload["image_id"] in configured))
        |> Enum.reduce({:ok, 0}, fn record, acc ->
          outcome =
            lease(pool, record.payload["image_id"], :exclusive, fn ->
              Storage.locked(pool, fn -> retire_recorded(pool, record.payload) end)
            end)

          # The first failing stage (closed atoms: bind, record, owner, remount,
          # retire, storage_busy, template_unconfirmed) is kept for diagnosis.
          case {outcome, acc} do
            {:ok, {:ok, count}} -> {:ok, count + 1}
            {{:error, stage}, {:ok, _}} when is_atom(stage) -> {:error, stage}
            {_, {:ok, _}} -> {:error, :template_unconfirmed}
            {_, error} -> error
          end
        end)
      end

    {outcome, stage} =
      case result do
        {:ok, _} -> {:ready, :none}
        {:error, :storage_busy} -> {:busy, :storage_busy}
        {:error, stage} when is_atom(stage) -> {:unconfirmed, stage}
        _ -> {:unconfirmed, :template_unconfirmed}
      end

    Lilly.Events.emit("lilly.template_sweep_finished",
      pool_id: pool.id,
      outcome: outcome,
      stage: stage
    )

    result
  end

  defp retire_recorded(pool, value) do
    with {:bind, :ok} <- {:bind, ZFSDataset.bind(pool)},
         {:record, {:ok, %{payload: ^value}}} <- {:record, load(pool, value["incarnation"])},
         {:owner, {:ok, owners}} <- {:owner, ZFS.owners(Pool.zfs_identity(pool))},
         {:remount, :ok} <- {:remount, remount_owned(pool, value, owners[name(pool, value)])},
         {:retire, :ok} <- {:retire, retire(pool, value)} do
      :ok
    else
      {stage, _} -> {:error, stage}
    end
  end

  defp remount_owned(_pool, _value, nil), do: :ok

  # An interrupted create may also die before the template root became private;
  # the root belongs to this owned dataset, so its mode is restored too.
  defp remount_owned(pool, value, owner) do
    with true <- owner?(owner, pool, value),
         :ok <- remount(pool, value),
         {:ok, %{type: :directory, uid: 0, mode: mode}} <-
           Lilly.Host.Privilege.lstat(directory(pool, value)),
         # Sealed templates are read-only and already private; only an
         # interrupted build's root needs its mode restored.
         :ok <-
           if(Bitwise.band(mode, 0o777) == 0o700,
             do: :ok,
             else: Lilly.Host.Privilege.claim_directory(directory(pool, value))
           ) do
      :ok
    else
      _ -> {:error, :template_unconfirmed}
    end
  end

  # Caller holds both exclusive image lease and pool mutation lock. No recursive
  # destroy, forced unmount or unknown-content deletion is allowed.
  defp retire(pool, value) do
    with :ok <- write(pool, Map.put(value, "state", "retiring")),
         {:ok, owners} <- ZFS.owners(Pool.zfs_identity(pool)),
         :ok <- destroy(pool, value, owners[name(pool, value)]),
         {:ok, after_owners} <- ZFS.owners(Pool.zfs_identity(pool)),
         false <- Map.has_key?(after_owners, name(pool, value)),
         do: write(pool, Map.put(value, "state", "deleted"))
  end

  defp destroy(_, _, nil), do: :ok

  defp destroy(pool, value, owner) do
    with true <- owner?(owner, pool, value),
         :ok <- native(pool, value, :either),
         {:ok, files} <- File.ls(directory(pool, value)),
         true <- Enum.all?(files, &(&1 in known_files(value))),
         true <-
           Enum.all?(files, fn file ->
             case Lilly.Host.Privilege.lstat(Path.join(directory(pool, value), file)) do
               {:ok, %{type: :regular, uid: 0, links: 1}} -> true
               _ -> false
             end
           end),
         # Services started while the template was mounted keep copies that
         # make the destroy busy after the host copy is unmounted.
         {:ok, _} <- ZFSNamespaceMounts.detach(name(pool, value), directory(pool, value)),
         {:ok, _} <- Command.run(:zfs_destroy, [name(pool, value)], 30_000),
         do: :ok,
         else: (_ -> {:error, :template_retirement_unconfirmed})
  end

  # @cc [owner:ghuntley,label:recovery;security] template-destroy-known-files
  # A template dataset MUST be destroyed only when every file in its root is
  # one its record names (or that file's interrupted `.pending` copy): the
  # sealed identities when the record has any, so a template of an image kind
  # this release no longer supports can still be retired; otherwise any file
  # a supported kind may stage. Anything else refuses the destroy.
  defp known_files(%{"identities" => identities}) when map_size(identities) > 0,
    do: with_pending(Map.keys(identities))

  defp known_files(_), do: with_pending(Enum.uniq(List.flatten(Image.file_sets())))

  defp with_pending(files), do: files ++ Enum.map(files, &(&1 <> ".pending"))

  defp touch(pool, value) do
    with {:ok, lock} <- Lock.acquire(Path.join(record_directory(pool, value), "access-lock")) do
      try do
        PrivateFiles.write(
          record_directory(pool, value),
          "access.json",
          JSON.encode!(%{"at" => System.system_time(:millisecond)})
        )
      after
        Lock.release(lock)
      end
    else
      {:error, :host_already_owned} -> :ok
      _ -> {:error, :template_unconfirmed}
    end
  end

  defp last_used(pool, value) do
    case Lilly.Host.Privilege.lstat(Path.join(record_directory(pool, value), "access.json"),
           time: :posix
         ) do
      {:ok, %{type: :regular, uid: 0, mtime: time}} -> time
      _ -> 0
    end
  end

  defp current(pool, image) do
    with {:ok, records} <- records(pool) do
      case Enum.filter(records, &(&1.payload["image_id"] == image and &1.state != :deleted)) do
        [] -> {:ok, nil}
        [record] -> {:ok, record}
        _ -> {:error, :template_unconfirmed}
      end
    end
  end

  defp records(pool) do
    case File.ls(Path.join(base(pool), "records")) do
      {:error, :enoent} ->
        {:ok, []}

      {:ok, ids} when length(ids) <= @catalog_limit ->
        Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
          with true <- OverallsProtocol.uuid?(id),
               {:ok, %{type: :directory, uid: 0, mode: mode}} <-
                 Lilly.Host.Privilege.lstat(Path.join([base(pool), "records", id])),
               true <- Bitwise.band(mode, 0o777) == 0o700,
               {:ok, record} <- load(pool, id) do
            cond do
              is_nil(record) ->
                # No native effect is authorized before journal publication.
                # Orphan directories stay counted; unmatched native children
                # are still refused independently by audit/3.
                {:cont, {:ok, acc}}

              record.payload["incarnation"] == id and record.payload["host_id"] == pool.host_id and
                  record.payload["pool_id"] == pool.id ->
                {:cont, {:ok, [record | acc]}}

              true ->
                {:halt, {:error, :template_unconfirmed}}
            end
          else
            _ -> {:halt, {:error, :template_unconfirmed}}
          end
        end)

      _ ->
        {:error, :template_unconfirmed}
    end
  end

  defp write(pool, value) do
    directory = record_directory(pool, value)

    with :ok <- PrivateFiles.directory(directory),
         {:ok, lock} <- Lock.acquire(Path.join(directory, "audit-lock"), 2000) do
      try do
        Journal.write(ImageTemplate, directory, "template.json", value)
      after
        Lock.release(lock)
      end
    else
      # Audit-lock contention is transient storage contention, not a failed
      # template: report it as storage_busy so builds retry instead of quarantining.
      {:error, :host_already_owned} -> {:error, :storage_busy}
      error -> error
    end
  end

  defp load(pool, id),
    do: Journal.load(ImageTemplate, Path.join([base(pool), "records", id]), "template.json")

  defp base(pool), do: Path.join(pool.path, ".lilly-templates")
  defp name(pool, value), do: pool.storage.dataset <> "/template-" <> value["incarnation"]
  defp directory(pool, value), do: Path.join([pool.path, "templates", value["incarnation"]])
  defp record_directory(pool, value), do: Path.join([base(pool), "records", value["incarnation"]])

  defp directories(pool) do
    Enum.reduce_while(
      [
        base(pool),
        Path.join(base(pool), "records"),
        Path.join(base(pool), "locks"),
        Path.join(pool.path, "templates")
      ],
      :ok,
      fn path, :ok ->
        case PrivateFiles.directory(path) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end
    )
  end

  # @cc [owner:ghuntley,label:security;concurrency] template-lock-parent-owned
  # A template reader or builder MUST claim its digest lock directory for the
  # configured service UID while holding the native owner.lock lease, before
  # invoking the callback. This keeps root-assisted callers compatible with
  # the image-copy helper's source-lease owner and parent-owner checks.
  defp lease(pool, "sha256:" <> digest, mode, fun) do
    with :ok <- directories(pool),
         directory = Path.join([base(pool), "locks", digest]),
         {:ok, lock} <-
           if(mode == :shared, do: Lock.shared(directory), else: Lock.acquire(directory)) do
      # Root-launched maintenance and fixture workers use the same hostd
      # service UID as the production BEAM. The lock inode is handed to that
      # UID by hostd; claim its parent while the lock is held as well so the
      # leased image copier can verify the native owner/parent handoff.
      try do
        with :ok <- Lilly.Host.Privilege.claim_directory(directory),
             do: fun.() |> normalize()
      after
        Lock.release(lock)
      end
    else
      {:error, :host_already_owned} -> {:error, :storage_busy}
      _ -> {:error, :template_unconfirmed}
    end
  end

  defp normalize(result) when result in [:ok, :uncached], do: result
  defp normalize({:quarantine, _} = result), do: result
  defp normalize({:error, reason}) when is_atom(reason), do: {:error, reason}
  defp normalize(_), do: {:error, :template_unconfirmed}

  defp flush(path), do: with({:ok, _} <- Command.run(:sync, ["--", path], @timeout), do: :ok)
end
