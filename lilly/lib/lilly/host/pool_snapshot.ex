defmodule Lilly.Host.PoolSnapshot do
  @moduledoc """
  One pool-locked read of native ZFS state (ADR-0152): the whole-pool
  observation, one ownership-tag listing and one mount table. Classification,
  the allocation and template audits, the dataset claim and the final
  verification of a preparation all derive from it instead of re-reading.
  A snapshot grants nothing by itself and is valid only while the exact lock
  it was read under is still held. A fenced snapshot (read_fenced/2) is read
  without the lock for capacity reports only; it is valid only while the pool
  generation token it was read under is unchanged (ADR-0274), and never
  gates a mutation.
  """
  alias Lilly.Host.{Lock, Pool, ZFS}
  alias Lilly.Transfer.SnapshotOwnership

  @enforce_keys [:lock, :observation, :owners, :mounts]
  defstruct @enforce_keys ++ [usage: :exact, fence: nil]

  @typedoc "Exact observations may grant capacity credit; identity observations never do."
  @type usage :: :exact | :identity

  @type t :: %__MODULE__{
          lock: Lilly.Host.Lease.t() | nil,
          fence: {Pool.t(), binary()} | nil,
          observation: map(),
          owners: %{String.t() => %{String.t() => String.t()}},
          mounts: [ZFS.mount()],
          usage: usage()
        }

  @typedoc "Which read failed: the lock fence, the observation (with its reason), owners or mounts."
  @type read_error :: :lock | {:observe, atom()} | :owner_set | :mounts

  # @cc [owner:ghuntley,label:capacity;concurrency] pool-snapshot-read-under-lock
  # read/2 MUST run with a current host lock and read every native fact after
  # that lock was acquired: snapshot expectations, then the observation (two
  # whole-pool reads with identity checks), then owners, then mounts. A failed
  # read MUST NOT yield a partial snapshot. Consumers that authorize a mutation
  # MUST check held?/1 so a snapshot never outlives the lock acquisition it was
  # read under (ADR-0152); capacity classification may use current?/1 (ADR-0274).
  # A placement UUID makes the observation diagnostic: an incoherent read emits
  # only that UUID and catalogued stage/reason atoms, never native output.
  # `:identity` usage tolerates usage-only movement between the two reads
  # (ZFS.observe_identity/2); such a snapshot keeps every identity, ownership,
  # snapshot, policy and accounting check but MUST NOT grant capacity credit.
  @spec read(Pool.t(), OverallsProtocol.uuid() | nil, usage()) ::
          {:ok, t()} | {:error, read_error()}
  def read(pool, placement \\ nil, usage \\ :exact) when usage in [:exact, :identity] do
    read_with(pool, usage, fn ->
      with {:ok, expected} <- SnapshotOwnership.expectations(pool),
           do: observe(pool, expected, placement, usage)
    end)
  end

  # @cc [owner:ghuntley,label:capacity;concurrency] pool-snapshot-reread-after-mutation
  # reread/3 re-verifies the whole pool once after this preparation's own native
  # mutations, under the same still-held lock. It reuses only the snapshot
  # expectations derived under that lock: local journals and other datasets'
  # snapshot markers cannot change in that window. Every native row, owner tag
  # and mount is read again.
  @spec reread(Pool.t(), t(), OverallsProtocol.uuid() | nil) ::
          {:ok, t()} | {:error, read_error()}
  def reread(pool, %__MODULE__{} = snapshot, placement \\ nil) do
    if held?(snapshot),
      do:
        read_with(pool, snapshot.usage, fn ->
          observe(pool, snapshot.observation.snapshots, placement, snapshot.usage)
        end),
      else: {:error, :lock}
  end

  # @cc [owner:ghuntley,label:capacity;concurrency] fenced-snapshot-reports-only
  # read_fenced/2 reads the same native facts as read/3 with :exact usage but
  # without a pool lock, under a generation token read under the lock
  # (Storage.observe/4). Its snapshot MUST NOT satisfy held?/1, so no
  # mutation, preparation or readiness path accepts it; current?/1 accepts it
  # only while the pool's generation still equals that token.
  @spec read_fenced(Pool.t(), binary()) :: {:ok, t()} | {:error, read_error()}
  def read_fenced(pool, token) when is_binary(token) do
    identity = Pool.zfs_identity(pool)

    with {:observe, {:ok, observation}} <-
           {:observe,
            with(
              {:ok, expected} <- SnapshotOwnership.expectations(pool),
              do: observe(pool, expected, nil, :exact)
            )},
         {:owner_set, {:ok, owners}} <- {:owner_set, ZFS.owners(identity)},
         {:mounts, {:ok, mounts}} <- {:mounts, ZFS.mounts()} do
      {:ok,
       %__MODULE__{
         lock: nil,
         fence: {pool, token},
         observation: observation,
         owners: owners,
         mounts: mounts,
         usage: :exact
       }}
    else
      {:observe, {:error, reason}} -> {:error, {:observe, reason}}
      {stage, _} -> {:error, stage}
    end
  end

  @doc "Whether the lock this snapshot was read under is still held by this process."
  @spec held?(term()) :: boolean()
  def held?(%__MODULE__{lock: nil}), do: false
  def held?(%__MODULE__{lock: lock}), do: Lock.held?(lock)
  def held?(_), do: false

  @doc "Whether the snapshot is still current: its lock is held, or its fence is unchanged."
  @spec current?(term()) :: boolean()
  def current?(%__MODULE__{fence: {pool, token}, lock: nil}),
    do: Lilly.Host.Storage.generation(pool) == {:ok, token}

  def current?(snapshot), do: held?(snapshot)

  @spec observe(Pool.t(), ZFS.snapshots(), OverallsProtocol.uuid() | nil, usage()) ::
          {:ok, map()} | {:error, atom()}
  defp observe(pool, expected, nil, :exact), do: ZFS.observe(Pool.zfs_identity(pool), expected)

  defp observe(pool, expected, nil, :identity),
    do: ZFS.observe_identity(Pool.zfs_identity(pool), expected)

  defp observe(pool, expected, placement, usage),
    do:
      ZFS.observe_for_readiness(
        Pool.zfs_identity(pool),
        expected,
        placement,
        MapSet.new(),
        usage
      )

  @spec read_with(Pool.t(), usage(), (-> {:ok, map()} | {:error, atom()})) ::
          {:ok, t()} | {:error, read_error()}
  defp read_with(pool, usage, observe) do
    identity = Pool.zfs_identity(pool)

    with {:lock, lock} when is_struct(lock, Lilly.Host.Lease) <- {:lock, Lock.current()},
         {:observe, {:ok, observation}} <- {:observe, observe.()},
         {:owner_set, {:ok, owners}} <- {:owner_set, ZFS.owners(identity)},
         {:mounts, {:ok, mounts}} <- {:mounts, ZFS.mounts()} do
      {:ok,
       %__MODULE__{
         lock: lock,
         observation: observation,
         owners: owners,
         mounts: mounts,
         usage: usage
       }}
    else
      {:observe, {:error, reason}} -> {:error, {:observe, reason}}
      {stage, _} -> {:error, stage}
    end
  end
end
