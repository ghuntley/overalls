defmodule Marshall.Compute.HostReports do
  @moduledoc """
  Ordered, complete host snapshots applied under the admission lock.

  Connection epochs come from Marshall; reconnect invalidates previous reports.
  Host UTC sample time must be within the freshness window and at most one
  second ahead of database time. Missing or invalid pools reject the whole
  report. Explicit unavailable entries invalidate only that pool. Network handlers must authenticate the host before calling here.
  """
  alias Marshall.Compute.{Host, Ledger, StoragePool, StartupHolds}
  require Marshall.Events

  @type report :: OverallsProtocol.report()

  # An identity-only pool entry: unavailable (no observation) or busy (transient).
  defguardp is_identity_entry(snapshot)
            when (is_map_key(snapshot, :unavailable) and
                    :erlang.map_get(:unavailable, snapshot) == true) or
                   (is_map_key(snapshot, :busy) and :erlang.map_get(:busy, snapshot) == true)

  @spec connect(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def connect(host_id) do
    Ledger.transaction(fn ->
      host = Ledger.lock!(Host, host_id)

      updated =
        Ledger.update!(host, :connect, %{
          connection_epoch: host.connection_epoch + 1,
          connection_session_id: nil,
          report_sequence: 0,
          reported_at: nil
        })

      updated.connection_epoch
    end)
    |> case do
      {:ok, _epoch} = ok ->
        unless Marshall.Repo.in_transaction?() do
          Marshall.Events.emit("host.connection_reset", host_id: host_id)
        end

        ok

      other ->
        other
    end
  end

  @spec disconnect(String.t(), non_neg_integer()) :: {:ok, :ok} | {:error, term()}
  def disconnect(host_id, epoch) do
    Ledger.transaction(fn ->
      host = Ledger.lock!(Host, host_id)

      if host.connection_epoch == epoch do
        Ledger.update!(host, :disconnect, %{
          reported_at: nil,
          connection_epoch: epoch + 1,
          connection_session_id: nil
        })

        :reset
      else
        :unchanged
      end
    end)
    |> case do
      {:ok, :reset} ->
        unless Marshall.Repo.in_transaction?() do
          Marshall.Events.emit("host.connection_reset", host_id: host_id)
        end

        {:ok, :ok}

      {:ok, :unchanged} ->
        {:ok, :ok}

      other ->
        other
    end
  end

  @spec ingest(String.t(), non_neg_integer(), report()) :: {:ok, :ok} | {:error, term()}
  def ingest(host_id, epoch, report) do
    Ledger.transaction(fn ->
      host = Ledger.lock!(Host, host_id)
      ingest_locked!(host, epoch, report)
    end)
    |> case do
      {:ok, :ok} = ok ->
        ok

      {:error, reason} when reason in [:invalid_report, :stale_report, :stale_connection] ->
        unless Marshall.Repo.in_transaction?() do
          Marshall.Events.emit("host.report_rejected", host_id: host_id, reason: reason)
        end

        {:error, reason}

      other ->
        other
    end
  end

  # @cc [owner:ghuntley,label:capacity] reports-complete-current-snapshot
  # A report MUST match the current nonzero connection epoch, advance its sequence
  # and contain exactly one valid observation or unavailable entry per enrolled pool. Invalid,
  # duplicate, partial or stale reports MUST NOT refresh any capacity or history.

  # @cc [owner:ghuntley,label:capacity] reports-sample-time
  # Accepted sample age MUST be within the host authority window
  # (HostLiveness.authority_ms) and at most one second ahead of database time;
  # accepted future samples MUST be clamped to that time. reported_at keeps the
  # sample time, so a late sample refreshes liveness but not capacity freshness.

  # @cc [owner:ghuntley,label:security] reports-v1-not-executable
  # Only an authenticated v4 session may establish execution readiness.
  @doc "Trusted coordinator only: caller must hold the host row lock in a ledger transaction."
  @spec ingest_locked!(Host.t(), pos_integer(), report()) :: :ok
  def ingest_locked!(host, epoch, report) do
    _transitions = ingest_with_events_locked!(host, epoch, report)
    :ok
  end

  # @cc [owner:ghuntley,label:capacity;recovery] report-resumes-awaiting-restarts
  # An accepted report MUST re-decide this host's resizes and crash recoveries
  # that await fresh capacity (event-driven, ADR-0140) inside the same
  # host-locked transaction,
  # returning their transitions for after-commit diagnostics.
  @doc "As ingest_locked!/3, returning resize transitions resumed by this report."
  @spec ingest_with_events_locked!(Host.t(), pos_integer(), report()) ::
          [Marshall.Compute.Outcomes.transition()]
  def ingest_with_events_locked!(host, epoch, report) do
    pools = Ledger.read!(StoragePool, host_id: host.id)
    now = Ledger.now()
    unless valid?(report, pools, now), do: Ledger.rollback(:invalid_report)
    capacity = Map.get(report, :capacity)
    unless OverallsProtocol.Capacity.valid?(capacity), do: Ledger.rollback(:invalid_report)

    if capacity &&
         (capacity["cpu_headroom_millicores"] > report.effective_cores * 1000 or
            capacity["memory_headroom_bytes"] > report.effective_memory_bytes),
       do: Ledger.rollback(:invalid_report)

    # Inventory is string-keyed wire data; any other key spelling is refused so
    # duplicate spellings cannot bypass validation on the JSON round trip.
    unless Enum.all?(Map.keys(report.inventory), &is_binary/1),
      do: Ledger.rollback(:invalid_report)

    images = Map.get(report.inventory, "images", [])

    unless OverallsProtocol.ImageManifest.ids?(images),
      do: Ledger.rollback(:invalid_report)

    unless Map.get(report.inventory, "architecture") == Atom.to_string(host.architecture),
      do: Ledger.rollback(:invalid_report)

    # Readiness belongs to the authenticated execution session.
    inventory =
      report.inventory
      |> Map.put(
        "execution_ready",
        Map.get(report.inventory, "execution_ready") == true
      )
      |> Map.put("images", images)

    if epoch != host.connection_epoch or epoch == 0, do: Ledger.rollback(:stale_connection)
    if report.sequence <= host.report_sequence, do: Ledger.rollback(:stale_report)

    reported_at =
      if DateTime.compare(report.sampled_at, now) == :gt, do: now, else: report.sampled_at

    # @cc [owner:ghuntley,label:capacity] busy-pool-entry-extends-measured-freshness
    # A busy entry is positive evidence that the host reached its pool and
    # found it momentarily locked; it MUST keep the previous numbers untouched
    # and MAY extend their freshness only while the last real measurement is
    # within the busy grace window. Past that window the row ages out as
    # before, and an unavailable entry still revokes at once (ADR-0163).
    pools =
      Enum.map(pools, fn pool ->
        case Enum.find(report.pools, &(&1.id == pool.id)) do
          %{busy: true} ->
            if within_busy_grace?(pool, reported_at),
              do: Ledger.update!(pool, :extend_freshness, %{reported_at: reported_at}),
              else: pool

          %{unavailable: true} = snapshot ->
            Ledger.update!(pool, :report, pool_attributes(snapshot, reported_at, nil))

          snapshot ->
            observed = observed_at(snapshot, reported_at)

            if current_observation?(pool, observed, reported_at),
              do: Ledger.update!(pool, :report, pool_attributes(snapshot, reported_at, observed)),
              else: pool
        end
      end)

    host =
      Ledger.update!(
        host,
        :report,
        report
        |> Map.take([:effective_cores, :effective_memory_bytes, :inventory])
        |> Map.put(:capacity, capacity)
        |> Map.put(:inventory, inventory)
        |> Map.merge(%{report_sequence: report.sequence, reported_at: reported_at})
      )

    StartupHolds.settle_locked!(host, pools)

    Marshall.Compute.Resize.resume_awaiting_locked!(host) ++
      Marshall.Compute.Outcomes.resume_recoveries_locked!(host)
  end

  defp valid?(
         %{
           sequence: sequence,
           sampled_at: %DateTime{} = sampled_at,
           effective_cores: cores,
           effective_memory_bytes: memory,
           inventory: inventory,
           pools: snapshots
         },
         pools,
         now
       )
       when is_integer(sequence) and sequence > 0 and is_integer(cores) and cores >= 0 and
              is_integer(memory) and memory >= 0 and is_map(inventory) and
              is_list(snapshots) do
    age = DateTime.diff(now, sampled_at, :millisecond)

    # A late sample is still a valid observation: accept it up to the authority
    # window and let its age gate capacity. Rejecting it would roll back the
    # whole exchange, losing the host's outcomes and acknowledgements (ADR-0140).
    age >= -1000 and age <= Marshall.Compute.HostLiveness.authority_ms() and
      Enum.all?(snapshots, &valid_pool?/1) and
      Enum.all?(snapshots, &observed_before?(&1, sampled_at)) and
      Enum.sort(Enum.map(snapshots, & &1.id)) == Enum.sort(Enum.map(pools, & &1.id)) and
      Enum.all?(snapshots, fn snapshot ->
        storage_matches?(snapshot, Enum.find(pools, &(&1.id == snapshot.id)))
      end)
  end

  defp valid?(_, _, _), do: false

  # A pool observation cannot postdate the report that carries it.
  defp observed_before?(%{observed_at: %DateTime{} = observed}, sampled_at),
    do: DateTime.compare(observed, sampled_at) != :gt

  defp observed_before?(_snapshot, _sampled_at), do: true

  # @cc [owner:ghuntley,label:capacity] unavailable-pool-revokes-freshness
  # An unavailable entry MUST clear only its pool's freshness, allocation credit
  # and storage observation in the accepted report transaction. Retained totals
  # remain historical; reservations and enrolled identity MUST NOT change.

  # @cc [owner:ghuntley,label:capacity] busy-pool-keeps-previous-observation
  # A busy entry (transient lock or usage contention, not evidence of loss) MUST
  # leave its pool row unchanged: the previous observation keeps its original
  # reported_at and credit, so capacity freshness expires on its own schedule as
  # if the report were late. It MUST still match the enrolled storage identity.
  defp within_busy_grace?(%{observed_at: %DateTime{} = observed}, reported_at),
    do:
      DateTime.diff(reported_at, observed, :millisecond) in 0..Marshall.Compute.HostLiveness.busy_grace_ms()

  defp within_busy_grace?(_pool, _reported_at), do: false

  # @cc [owner:ghuntley,label:capacity] pool-observation-time-bounds-freshness
  # An observed entry's observed_at (absent means the report's sampled_at)
  # MUST be recorded as the pool's observed_at, never later than the report.
  # It MUST refresh the pool only while observed_at is within the busy grace
  # window of the report and not older than the pool's recorded observation;
  # otherwise the row is left unchanged and ages out (ADR-0140, ADR-0163).
  defp observed_at(%{observed_at: %DateTime{} = observed}, reported_at),
    do: if(DateTime.compare(observed, reported_at) == :gt, do: reported_at, else: observed)

  defp observed_at(_snapshot, reported_at), do: reported_at

  defp current_observation?(pool, observed, reported_at) do
    not_older =
      case pool do
        %{observed_at: %DateTime{} = recorded} -> DateTime.compare(observed, recorded) != :lt
        _ -> true
      end

    not_older and
      DateTime.diff(reported_at, observed, :millisecond) <=
        Marshall.Compute.HostLiveness.busy_grace_ms()
  end

  defp pool_attributes(%{unavailable: true}, _reported_at, _observed),
    do: %{
      reported_at: nil,
      observed_at: nil,
      allocations: %{},
      checkpoint_allocations: %{},
      storage_observation: %{}
    }

  defp pool_attributes(snapshot, reported_at, observed) do
    snapshot
    |> Map.take([:total_bytes, :free_bytes, :allocations])
    |> Map.put(:checkpoint_allocations, Map.get(snapshot, :checkpoint_allocations, %{}))
    |> Map.put(:storage_observation, storage_observation(snapshot))
    |> Map.put(:reported_at, reported_at)
    |> Map.put(:observed_at, observed)
  end

  defp valid_pool?(%{id: id, storage: storage} = snapshot)
       when map_size(snapshot) == 3 and is_identity_entry(snapshot) do
    OverallsProtocol.uuid?(id) and is_map(storage) and
      map_size(storage) == 4 and OverallsProtocol.Storage.valid_identity?(storage)
  end

  defp valid_pool?(
         %{
           id: id,
           total_bytes: total,
           free_bytes: free,
           allocations: allocations
         } = snapshot
       )
       when not is_map_key(snapshot, :unavailable) and not is_map_key(snapshot, :busy) and
              is_binary(id) and is_integer(total) and
              is_integer(free) and total >= 0 and free >= 0 and
              free <= total and is_map(allocations) do
    Enum.all?(allocations, fn {vm_id, bytes} ->
      is_binary(vm_id) and is_integer(bytes) and bytes >= 0
    end) and is_map(Map.get(snapshot, :checkpoint_allocations, %{})) and
      Enum.all?(Map.get(snapshot, :checkpoint_allocations, %{}), fn {placement, bytes} ->
        OverallsProtocol.uuid?(placement) and is_integer(bytes) and bytes >= 0
      end) and
      Enum.sum(Map.values(allocations)) +
        Enum.sum(Map.values(Map.get(snapshot, :checkpoint_allocations, %{}))) <= total - free
  end

  defp valid_pool?(_), do: false

  # @cc [owner:ghuntley,label:capacity] reports-bind-storage-backend
  # ZFS reports MUST match the enrolled pool/dataset GUIDs and name and agree
  # with physical accounting.
  defp storage_matches?(%{storage: identity} = snapshot, %{backend: :zfs} = pool)
       when is_identity_entry(snapshot) do
    Enum.all?(
      [:zpool_guid, :dataset_guid, :dataset],
      &(Map.get(identity, &1) == Map.get(pool, &1))
    ) and
      OverallsProtocol.Storage.filesystem_id(identity) == pool.filesystem_id
  end

  defp storage_matches?(%{storage: observation} = snapshot, %{backend: :zfs} = pool) do
    OverallsProtocol.Storage.coherent?(observation, snapshot.total_bytes, snapshot.free_bytes) and
      Enum.all?(
        [:zpool_guid, :dataset_guid, :dataset],
        &(Map.get(observation, &1) == Map.get(pool, &1))
      ) and
      OverallsProtocol.Storage.filesystem_id(observation) == pool.filesystem_id
  end

  defp storage_matches?(_, _), do: false

  defp storage_observation(%{storage: storage}), do: OverallsProtocol.Storage.encode(storage)
end
