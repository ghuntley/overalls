defmodule Lilly.Host.Pool do
  @moduledoc "Bound native ZFS pools with canonical identity and non-overlapping backing extents."
  require Lilly.Events
  alias Lilly.Host.ZFS
  @enforce_keys [:id, :path, :filesystem_id]
  defstruct [
    :id,
    :path,
    :filesystem_id,
    :max_iops,
    :max_iops_source,
    :storage,
    :host_id,
    extents: [],
    template_budget_bytes: 34_359_738_368,
    image_io_timeout_ms: 300_000,
    backend: :zfs
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          path: Path.t(),
          filesystem_id: String.t(),
          max_iops: pos_integer() | nil,
          max_iops_source: String.t() | nil,
          backend: :zfs | :controlled,
          storage: OverallsProtocol.Storage.identity(),
          extents: [ZFS.extent()],
          host_id: String.t() | nil,
          template_budget_bytes: 1..1_099_511_627_776,
          image_io_timeout_ms: 1_000..14_400_000
        }
  @spec inspect_path(Path.t()) :: {:ok, ZFS.t()} | {:error, atom()}
  def inspect_path(path), do: ZFS.inspect_path(path)

  @options [
    :storage,
    :host_id,
    :max_iops,
    :max_iops_source,
    :template_budget_bytes,
    :image_io_timeout_ms
  ]

  # @cc [owner:ghuntley,label:capacity] pool-options-closed
  # new/4 MUST reject any option outside the bound pool fields; the retired
  # `logical_budget_bytes` MUST NOT be silently accepted or ignored (ADR-0159).
  @spec new(String.t(), Path.t(), String.t(), keyword()) :: {:ok, t()} | {:error, atom()}
  def new(id, path, filesystem_id, options \\ []) do
    with true <- Keyword.keyword?(options) and Keyword.keys(options) -- @options == [],
         true <- OverallsProtocol.uuid?(id),
         {:ok, identity} <- inspect_path(path),
         true <- identity.filesystem_id == filesystem_id,
         {:ok, backend} <- backend(identity, options),
         max_iops = Keyword.get(options, :max_iops),
         source = Keyword.get(options, :max_iops_source),
         template_budget = Keyword.get(options, :template_budget_bytes, 34_359_738_368),
         true <- is_integer(template_budget) and template_budget in 1..1_099_511_627_776,
         io_timeout = Keyword.get(options, :image_io_timeout_ms, 300_000),
         true <- is_integer(io_timeout) and io_timeout in 1_000..14_400_000,
         true <-
           (is_nil(max_iops) and is_nil(source)) or
             (is_integer(max_iops) and max_iops > 0 and max_iops <= 9_223_372_036_854_775_807 and
                is_binary(source) and byte_size(source) in 1..256) do
      {:ok,
       struct!(
         __MODULE__,
         identity
         |> Map.merge(backend)
         |> Map.merge(%{
           id: id,
           max_iops: max_iops,
           max_iops_source: source,
           template_budget_bytes: template_budget,
           image_io_timeout_ms: io_timeout
         })
       )}
    else
      _ -> {:error, :invalid_pool_configuration}
    end
  end

  defp backend(%{storage: storage}, options) do
    with {:ok, ^storage} <- OverallsProtocol.Storage.identity(Keyword.get(options, :storage)),
         host = Keyword.get(options, :host_id),
         true <- OverallsProtocol.uuid?(host) do
      {:ok, %{backend: :zfs, host_id: host}}
    else
      _ -> :error
    end
  end

  @configuration_keys ~w(id path filesystem_id storage max_iops max_iops_source template_budget_bytes image_io_timeout_ms)

  # @cc [owner:ghuntley,label:capacity;security] config-pools-closed-shape
  # A configured pool MUST contain only the keys Lilly binds (identity, path,
  # monitoring IOPS metadata, the template budget and the image I/O
  # deadline). Any other key,
  # including the retired `logical_budget_bytes`, MUST fail startup instead of
  # being silently ignored (ADR-0159).
  @doc "Whether a runtime-configuration pool object carries only bound pool keys."
  @spec configuration_keys?(map()) :: boolean()
  def configuration_keys?(value) when is_map(value),
    do: Enum.all?(Map.keys(value), &(&1 in @configuration_keys))

  @spec zfs_identity(t()) :: ZFS.t()
  def zfs_identity(pool), do: Map.take(pool, [:path, :filesystem_id, :storage, :extents])

  @doc "Immutable ZFS identity recorded in the host ownership binding and matched against Marshall sessions."
  @type session_identity :: %{
          required(String.t()) => String.t() | %{optional(String.t()) => term()}
        }
  @spec session_identity(t()) :: session_identity()
  def session_identity(pool) do
    %{
      "id" => pool.id,
      "filesystem_id" => pool.filesystem_id,
      "storage" => OverallsProtocol.Storage.encode(pool.storage)
    }
  end

  @session_identity_keys ~w(id filesystem_id storage)

  # @cc [owner:ghuntley,label:capacity;protocol] session-pools-match-identity-only
  # A Marshall session matches the configured pools when both sets have the same
  # id, filesystem_id and storage identities. Descriptor shape (exactly id, name,
  # filesystem_id and storage) is enforced by the control client before matching;
  # the descriptive name MUST NOT take part in the comparison.
  @doc "Whether Marshall session pool descriptors name exactly the configured pool identities."
  @spec session_matches?([t()], [map()]) :: boolean()
  def session_matches?(pools, descriptors) do
    expected = pools |> Enum.map(&session_identity/1) |> Enum.sort()
    Enum.sort(Enum.map(descriptors, &Map.take(&1, @session_identity_keys))) == expected
  end

  # @cc [owner:ghuntley,label:capacity] pool-capacity-not-double-counted
  # distinct?/1 MUST reject duplicate filesystem identities and overlapping extents on the same
  # backing device, including whole-disk plus partition aliases; disjoint extents may remain
  # separate pools. ZFS siblings MUST NOT duplicate a zpool's capacity.
  @spec distinct?([t() | ZFS.t()]) :: boolean()
  def distinct?(pools) do
    pools
    |> Enum.with_index()
    |> Enum.all?(fn {a, index} ->
      Enum.all?(Enum.drop(pools, index + 1), fn b ->
        a.filesystem_id != b.filesystem_id and
          not same_zpool?(a, b) and
          distinct_extents?(a.extents ++ b.extents)
      end)
    end)
  end

  defp same_zpool?(%{storage: %{zpool_guid: a}}, %{storage: %{zpool_guid: b}}), do: a == b
  defp same_zpool?(_, _), do: false

  @doc "Rejects overlapping plain block-device extents, independent of dataset identity."
  @spec distinct_extents?([ZFS.extent()]) :: boolean()
  def distinct_extents?(extents) do
    extents
    |> Enum.with_index()
    |> Enum.all?(fn {a, index} ->
      Enum.all?(Enum.drop(extents, index + 1), fn b ->
        a.backing_device != b.backing_device or
          a.start_sector + a.sectors <= b.start_sector or
          b.start_sector + b.sectors <= a.start_sector
      end)
    end)
  end

  @doc "Capacity report entry; failed observation invalidates only this configured pool."
  # @cc [owner:ghuntley,label:capacity] failed-pool-observation-has-no-credit
  # report/1 MUST preserve successful verified observations. Transient contention
  # (the pool lock held, or usage counters moving between the two exact reads)
  # MUST produce configured identity and busy=true, so Marshall keeps the previous
  # observation until it ages out; every other snapshot error MUST produce
  # unavailable=true. Neither carries totals or allocation credit. Configuration
  # MUST NOT stand in for measured capacity. Slowness is not evidence (ADR-0140).
  @spec report(t(), mode()) :: OverallsProtocol.pool()
  def report(pool, mode \\ :fenced) do
    case snapshot(pool, mode) do
      {:ok, observation} ->
        availability_changed(pool, :available)
        observation

      {:error, stage} when stage in [:storage_busy, :usage_moving] ->
        availability_changed(pool, stage)
        %{id: pool.id, busy: true, storage: pool.storage}

      {:error, stage} ->
        availability_changed(pool, stage)
        %{id: pool.id, unavailable: true, storage: pool.storage}
    end
  end

  # @cc [owner:ghuntley,label:observability;capacity] pool-availability-transitions-only
  # A withheld pool MUST be reported once per change of withholding stage, and
  # recovery once, never per collection. Only the pool UUID and a fixed stage atom
  # may leave this boundary. The diagnostic grants no credit and changes no report.
  @spec availability_changed(t(), :available | snapshot_stage()) :: :ok
  defp availability_changed(pool, state) do
    key = {__MODULE__, :availability, pool.id}
    previous = :persistent_term.get(key, :available)

    cond do
      previous == state ->
        :ok

      not OverallsProtocol.uuid?(pool.id) ->
        :ok

      state == :available ->
        :persistent_term.put(key, state)
        Lilly.Events.emit("pool.snapshot_recovered", pool_id: pool.id)

      true ->
        :persistent_term.put(key, state)
        Lilly.Events.emit("pool.snapshot_withheld", pool_id: pool.id, stage: state)
    end
  end

  @doc "Serialized ZFS physical allocation evidence."
  # @cc [owner:ghuntley,label:capacity;recovery] snapshot-credit-serialized-with-disks
  # snapshot/2 MUST be serializable with disk mutations (read under the pool lock, or
  # fenced by a generation token unchanged across the whole read) and verify current pool
  # identity under the lock before reporting allocation credit. ZFS credits exclusive physical bytes only after matching
  # durable ownership and ready disk shape.
  # Why a snapshot was withheld: the pool lock, binding, native observation or
  # one allocation-ownership check (see ZFSDataset.classify_allocations/2).
  @type snapshot_stage ::
          :storage_busy
          | :usage_moving
          | :bind
          | :observe
          | :snapshot_expectations
          | :owner_set
          | :mounts
          | Lilly.Host.ZFSDataset.allocation_rejection()

  @typedoc """
  How a capacity snapshot is read: `:fenced` holds the pool lock only to bind
  the pool and read its generation token, then reads outside the lock;
  `:locked` reads the whole snapshot under the lock.
  """
  @type mode :: :fenced | :locked

  # @cc [owner:ghuntley,label:capacity;concurrency] fenced-capacity-snapshot
  # snapshot/2 in :fenced mode MUST hold the pool lock only to bind the pool
  # and read its generation token (Storage.observe/4); the native reads and
  # allocation classification run outside the lock. A snapshot whose read
  # straddled the start of any pool section MUST be withheld as storage_busy,
  # never reported, and none of its errors reported as unavailable. :locked
  # mode keeps the whole snapshot under the lock.
  @spec snapshot(t(), mode()) :: {:ok, OverallsProtocol.pool()} | {:error, snapshot_stage()}
  # A capacity observation waits briefly for the pool lock (ADR-0163): most
  # mutation sections are far shorter than the sampling interval, so a short
  # wait turns a withheld sample into a fresh one without serializing writers.
  @snapshot_wait_ms 200
  def snapshot(pool, mode \\ :fenced)

  def snapshot(pool, :locked) do
    Lilly.Host.Storage.locked(pool, fn -> snapshot_locked(pool) end, @snapshot_wait_ms, :snapshot)
  end

  def snapshot(%{backend: :zfs} = pool, :fenced) do
    Lilly.Host.Storage.observe(
      pool,
      fn ->
        case Lilly.Host.ZFSDataset.bind(pool) do
          :ok -> :ok
          _ -> {:error, :bind}
        end
      end,
      fn token -> entry(pool, Lilly.Host.PoolSnapshot.read_fenced(pool, token)) end,
      @snapshot_wait_ms
    )
  end

  defp snapshot_locked(%{backend: :zfs} = pool) do
    with {:bind, :ok} <- {:bind, Lilly.Host.ZFSDataset.bind(pool)} do
      entry(pool, Lilly.Host.PoolSnapshot.read(pool))
    else
      {stage, _} -> {:error, stage}
    end
  end

  @spec entry(t(), {:ok, Lilly.Host.PoolSnapshot.t()} | {:error, term()}) ::
          {:ok, OverallsProtocol.pool()} | {:error, snapshot_stage()}
  defp entry(pool, read) do
    with {:read, {:ok, snapshot}} <- {:read, read},
         {:allocations, {:ok, allocations}} <-
           {:allocations, Lilly.Host.ZFSDataset.classify_allocations(pool, snapshot)},
         checkpoint_children =
           Map.filter(snapshot.observation.children, fn {name, _} ->
             String.starts_with?(name, pool.storage.dataset <> "/checkpoint-")
           end),
         {:allocations, {:ok, checkpoint_allocations}} <-
           {:allocations,
            Lilly.VM.CheckpointStorage.audit(
              pool,
              checkpoint_children,
              snapshot.owners,
              snapshot.mounts
            )} do
      observation = snapshot.observation

      {:ok,
       %{
         id: pool.id,
         total_bytes: observation.total_bytes,
         free_bytes: observation.free_bytes,
         storage: observation.storage,
         allocations: allocations,
         checkpoint_allocations: checkpoint_allocations
       }}
    else
      {:allocations, {:error, check}} ->
        {:error, check}

      {:read, {:error, {:observe, :storage_busy}}} ->
        {:error, :usage_moving}

      {:read, {:error, {:observe, :snapshot_ownership_unconfirmed}}} ->
        {:error, :snapshot_expectations}

      {:read, {:error, stage}} when stage in [:owner_set, :mounts] ->
        {:error, stage}

      {:read, _} ->
        {:error, :observe}
    end
  end

  @doc "Reads a plain block device or partition extent; stacked and loop devices are unsupported."
  @spec device_extent(Path.t(), String.t()) :: {:ok, map()} | :error
  def device_extent(sys_root, device) do
    link = Path.join([sys_root, "dev/block", device])

    with true <- Regex.match?(~r/\A\d+:\d+\z/, device),
         {:ok, target} <- File.read_link(link),
         path = Path.expand(target, Path.dirname(link)),
         true <- String.starts_with?(path, Path.expand(sys_root) <> "/devices/"),
         {:ok, size} <- read_number(Path.join(path, "size")) do
      if File.exists?(Path.join(path, "partition")) do
        parent = Path.dirname(path)

        with :ok <- plain_device(parent),
             {:ok, parent_device} <- File.read(Path.join(parent, "dev")),
             {:ok, start} <- read_number(Path.join(path, "start")),
             {:ok, parent_size} <- read_number(Path.join(parent, "size")),
             true <- size > 0 and start + size <= parent_size do
          {:ok, %{backing_device: String.trim(parent_device), start_sector: start, sectors: size}}
        else
          _ -> :error
        end
      else
        with :ok <- plain_device(path), true <- size > 0 do
          {:ok, %{backing_device: device, start_sector: 0, sectors: size}}
        else
          _ -> :error
        end
      end
    else
      _ -> :error
    end
  end

  defp plain_device(path) do
    with {:ok, []} <- File.ls(Path.join(path, "slaves")),
         false <- File.exists?(Path.join(path, "loop")) or File.exists?(Path.join(path, "dm")) do
      :ok
    else
      _ -> :error
    end
  end

  defp read_number(path),
    do: with({:ok, value} <- File.read(path), do: number(String.trim(value)))

  defp number(text) do
    case Integer.parse(text) do
      {n, ""} when n >= 0 and n <= 9_223_372_036_854_775_807 -> {:ok, n}
      _ -> :error
    end
  end
end
