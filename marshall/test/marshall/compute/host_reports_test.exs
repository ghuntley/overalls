defmodule Marshall.Compute.HostReportsTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  import Marshall.ComputeFixtures
  alias Marshall.Compute.{Host, HostReports, Ledger, StoragePool}

  setup do
    host_fixture()
  end

  # @cc [owner:ghuntley,label:verification;capacity] generated-report-ordering
  # A rejected stale, wrong-epoch or partial report MUST leave host and pool
  # capacity state unchanged. A reconnect may reset sequence only while its
  # epoch advances and host freshness is revoked.
  property "generated report histories preserve epoch order and atomic rejection",
    test_cases: 100 do
    actions =
      draw(
        "actions",
        list_of(member_of([:advance, :duplicate, :older, :old_epoch, :partial, :reconnect]),
          min_length: 1,
          max_length: 8
        )
      )

    fixture = host_fixture()
    host_id = fixture.host.id
    pool_id = fixture.pool.id

    Enum.reduce(actions, {fixture.epoch, 1}, fn action, {epoch, sequence} ->
      before_host = report_host_snapshot(host_id)
      before_pool = report_pool_snapshot(pool_id)
      free_bytes = 10_737_418_240 - (sequence + 1) * 1_048_576

      next_pool =
        fixture.report.pools
        |> hd()
        |> Map.put(:free_bytes, free_bytes)
        |> Map.put(:storage, storage_observation(fixture.pool, 10_737_418_240, free_bytes))

      next = %{
        fixture.report
        | sequence: sequence + 1,
          sampled_at: Ledger.now(),
          capacity:
            capacity(5 - rem(sequence + 1, 4), 4_294_967_296 - (sequence + 1) * 1_048_576),
          pools: [next_pool]
      }

      case action do
        :reconnect ->
          assert {:ok, new_epoch} = HostReports.connect(host_id)
          assert new_epoch > epoch
          after_host = report_host_snapshot(host_id)
          assert after_host.connection_epoch == new_epoch
          assert after_host.report_sequence == 0
          assert after_host.reported_at == nil
          assert report_pool_snapshot(pool_id) == before_pool
          {new_epoch, 0}

        :advance ->
          assert {:ok, :ok} = HostReports.ingest(host_id, epoch, next)
          after_host = report_host_snapshot(host_id)
          assert after_host.connection_epoch == epoch
          assert after_host.report_sequence == sequence + 1
          assert after_host.reported_at != nil
          assert after_host.effective_cores == next.effective_cores
          assert after_host.effective_memory_bytes == next.effective_memory_bytes
          assert after_host.capacity == next.capacity
          assert after_host.inventory == next.inventory
          after_pool = report_pool_snapshot(pool_id)
          assert after_pool.total_bytes == next_pool.total_bytes
          assert after_pool.free_bytes == next_pool.free_bytes
          assert after_pool.allocations == next_pool.allocations

          assert after_pool.storage_observation ==
                   OverallsProtocol.Storage.encode(next_pool.storage)

          {epoch, sequence + 1}

        rejected ->
          {sent_epoch, sent_report, reason} =
            case rejected do
              :duplicate ->
                {epoch, %{next | sequence: sequence},
                 if(sequence == 0, do: :invalid_report, else: :stale_report)}

              :older ->
                {epoch, %{next | sequence: max(0, sequence - 1)},
                 if(sequence <= 1, do: :invalid_report, else: :stale_report)}

              :old_epoch ->
                {epoch - 1, next, :stale_connection}

              :partial ->
                {epoch, %{next | pools: []}, :invalid_report}
            end

          assert {:error, ^reason} = HostReports.ingest(host_id, sent_epoch, sent_report)
          assert report_host_snapshot(host_id) == before_host
          assert report_pool_snapshot(pool_id) == before_pool
          {epoch, sequence}
      end
    end)
  end

  @spec report_host_snapshot(String.t()) :: map()
  defp report_host_snapshot(id) do
    [host] = Ledger.read!(Host, id: id)

    Map.take(host, [
      :connection_epoch,
      :report_sequence,
      :reported_at,
      :effective_cores,
      :effective_memory_bytes,
      :capacity,
      :inventory
    ])
  end

  @spec report_pool_snapshot(String.t()) :: map()
  defp report_pool_snapshot(id) do
    [pool] = Ledger.read!(StoragePool, id: id)

    Map.take(pool, [
      :reported_at,
      :total_bytes,
      :free_bytes,
      :allocations,
      :storage_observation
    ])
  end

  test "reports cannot move backwards or outlive their connection", %{
    host: host,
    epoch: epoch,
    report: report
  } do
    assert {:error, :stale_report} = HostReports.ingest(host.id, epoch, report)
    assert {:ok, new_epoch} = HostReports.connect(host.id)
    assert new_epoch > epoch
    assert [%{reported_at: nil}] = Ledger.read!(Host, id: host.id)

    assert {:error, :stale_connection} =
             HostReports.ingest(host.id, epoch, %{report | sequence: 2})

    assert {:ok, :ok} = HostReports.ingest(host.id, new_epoch, report)
    assert {:ok, :ok} = HostReports.disconnect(host.id, epoch)
    assert [%{reported_at: %DateTime{}}] = Ledger.read!(Host, id: host.id)
    assert {:ok, :ok} = HostReports.disconnect(host.id, new_epoch)
    assert [%{reported_at: nil}] = Ledger.read!(Host, id: host.id)

    assert {:error, :stale_connection} =
             HostReports.ingest(host.id, new_epoch, %{report | sequence: 2})
  end

  test "report diagnostics use closed rejection reasons and connection resets", %{
    host: host,
    epoch: epoch,
    report: report
  } do
    old_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: old_level) end)

    rejected =
      ExUnit.CaptureLog.capture_log([metadata: [:event, :host_id, :reason]], fn ->
        assert {:error, :stale_report} = HostReports.ingest(host.id, epoch, report)
      end)

    assert rejected =~ "Host report rejected"
    assert rejected =~ "event=host.report_rejected"
    assert rejected =~ "host_id=" <> host.id
    assert rejected =~ "reason=stale_report"

    reset =
      ExUnit.CaptureLog.capture_log([metadata: [:event, :host_id]], fn ->
        assert {:ok, _} = HostReports.connect(host.id)
      end)

    assert reset =~ "Host control connection reset"
    assert reset =~ "event=host.connection_reset"
    assert reset =~ "host_id=" <> host.id
  end

  # @cc [owner:ghuntley,label:verification;capacity] late-report-accepted-not-capacity-fresh
  # A report sampled within the authority window but beyond the capacity window
  # MUST be accepted (keeping the exchange) while its capacity stays stale.
  test "a late sample is accepted, keeps the host authoritative and stays capacity-stale", %{
    host: host,
    epoch: epoch,
    report: report
  } do
    late = %{report | sequence: 2, sampled_at: DateTime.add(report.sampled_at, -10, :second)}
    assert {:ok, :ok} = HostReports.ingest(host.id, epoch, late)
    [stored] = Ledger.read!(Host, id: host.id)
    now = Ledger.now()
    refute Marshall.Compute.HostLiveness.capacity_fresh?(stored.reported_at, now)

    # The accepted sample's age classifies as late for a connected session.
    assert Marshall.Compute.HostLiveness.state("session", stored.reported_at, now) == :late
  end

  # @cc [owner:ghuntley,label:verification;capacity] busy-pool-entry-preserves-observation
  # A busy entry MUST leave the pool's previous numbers and measurement time
  # untouched while the host itself advances; within the busy grace it MAY
  # extend the measurement's freshness, past the grace it MUST let it age; a
  # busy entry naming another storage identity MUST reject the whole report.
  test "a busy pool keeps its measurement and extends freshness only within the grace", %{
    host: host,
    pool: pool,
    epoch: epoch,
    report: report
  } do
    measured_at = Ledger.now()

    assert {:ok, :ok} =
             HostReports.ingest(host.id, epoch, %{report | sequence: 2, sampled_at: measured_at})

    [before] = Ledger.read!(StoragePool, id: pool.id)
    assert %DateTime{} = before.reported_at
    assert before.observed_at == before.reported_at

    busy = %{
      id: pool.id,
      busy: true,
      storage:
        Map.take(hd(report.pools).storage, [:backend, :zpool_guid, :dataset_guid, :dataset])
    }

    within = Ledger.now()
    later = %{report | sequence: 3, pools: [busy], sampled_at: within}

    assert {:ok, decoded} =
             later
             |> OverallsProtocol.encode_report()
             |> JSON.encode!()
             |> JSON.decode!()
             |> OverallsProtocol.report()

    assert {:ok, :ok} = HostReports.ingest(host.id, epoch, decoded)
    [kept] = Ledger.read!(StoragePool, id: pool.id)

    assert Map.take(kept, [:observed_at, :allocations, :storage_observation, :free_bytes]) ==
             Map.take(before, [:observed_at, :allocations, :storage_observation, :free_bytes])

    assert DateTime.compare(kept.reported_at, before.reported_at) == :gt
    assert Marshall.Compute.HostLiveness.capacity_fresh?(kept.reported_at, within)
    assert [%{report_sequence: 3}] = Ledger.read!(Host, id: host.id)

    # Past the grace (shrunk to one millisecond here) a busy entry no longer
    # extends the measurement, so capacity ages out as before.
    grace = Application.get_env(:marshall, :pool_busy_grace_ms)
    Application.put_env(:marshall, :pool_busy_grace_ms, 1)
    Process.sleep(5)

    try do
      assert {:ok, :ok} =
               HostReports.ingest(host.id, epoch, %{
                 later
                 | sequence: 4,
                   sampled_at: Ledger.now()
               })
    after
      Application.put_env(:marshall, :pool_busy_grace_ms, grace)
    end

    [aged] = Ledger.read!(StoragePool, id: pool.id)
    assert aged.reported_at == kept.reported_at and aged.observed_at == before.observed_at

    assert {:error, :invalid_report} =
             HostReports.ingest(host.id, epoch, %{
               later
               | sequence: 5,
                 pools: [put_in(busy, [:storage, :dataset_guid], "999")]
             })
  end

  # @cc [owner:ghuntley,label:verification;capacity] pool-observed-at-ingest
  # A pool entry's observed_at MUST become the pool's observed_at while the row
  # takes the report's freshness; a re-sent observation MUST extend it only
  # within the busy grace, an older observation MUST leave the row unchanged,
  # and an observation after its report MUST reject the whole report.
  test "pool observation times bound freshness independently of the report", %{
    host: host,
    pool: pool,
    epoch: epoch,
    report: report
  } do
    # Report times stay in the past, as a real host's would: the observation
    # follows the fixture's own, and the report comes 2.5 s after it.
    [fixture_pool] = Ledger.read!(StoragePool, id: pool.id)
    observed = DateTime.add(fixture_pool.observed_at, 1, :millisecond)
    Process.sleep(2500)
    sampled = Ledger.now()
    entry = Map.put(hd(report.pools), :observed_at, observed)

    assert {:ok, decoded} =
             %{report | sequence: 2, sampled_at: sampled, pools: [entry]}
             |> OverallsProtocol.encode_report()
             |> JSON.encode!()
             |> JSON.decode!()
             |> OverallsProtocol.report()

    assert {:ok, :ok} = HostReports.ingest(host.id, epoch, decoded)
    [first] = Ledger.read!(StoragePool, id: pool.id)
    assert first.observed_at == observed
    assert first.reported_at == sampled
    assert Marshall.Compute.HostLiveness.capacity_fresh?(first.reported_at, sampled)

    # The same observation re-sent with a later report extends freshness.
    Process.sleep(1000)
    resent = Ledger.now()

    assert {:ok, :ok} =
             HostReports.ingest(host.id, epoch, %{
               decoded
               | sequence: 3,
                 sampled_at: resent
             })

    [extended] = Ledger.read!(StoragePool, id: pool.id)
    assert extended.observed_at == observed and extended.reported_at == resent

    # An observation older than the recorded one never replaces it.
    older = put_in(decoded, [:pools, Access.at(0), :observed_at], DateTime.add(observed, -1))

    assert {:ok, :ok} =
             HostReports.ingest(host.id, epoch, %{
               older
               | sequence: 4,
                 sampled_at: Ledger.now()
             })

    assert [^extended] = Ledger.read!(StoragePool, id: pool.id)

    # Past the busy grace a re-sent observation no longer refreshes the pool.
    grace = Application.get_env(:marshall, :pool_busy_grace_ms)
    Application.put_env(:marshall, :pool_busy_grace_ms, 1000)

    try do
      assert {:ok, :ok} =
               HostReports.ingest(host.id, epoch, %{
                 decoded
                 | sequence: 5,
                   sampled_at: Ledger.now()
               })
    after
      Application.put_env(:marshall, :pool_busy_grace_ms, grace)
    end

    assert [^extended] = Ledger.read!(StoragePool, id: pool.id)
    assert [%{report_sequence: 5}] = Ledger.read!(Host, id: host.id)

    now = Ledger.now()
    future = put_in(decoded, [:pools, Access.at(0), :observed_at], DateTime.add(now, 4, :second))

    assert {:error, :invalid_report} =
             HostReports.ingest(host.id, epoch, %{future | sequence: 6, sampled_at: now})
  end

  test "partial, duplicate, malformed or delayed snapshots never refresh capacity", %{
    host: host,
    pool: pool,
    epoch: epoch,
    report: report
  } do
    for invalid <- [
          %{report | pools: []},
          %{report | inventory: %{architecture: "aarch64"}},
          %{report | pools: report.pools ++ report.pools},
          # Beyond the host authority window (ADR-0140); a merely late sample is accepted.
          %{
            report
            | sampled_at:
                DateTime.add(
                  report.sampled_at,
                  -(Marshall.Compute.HostLiveness.authority_ms() + 10_000),
                  :millisecond
                )
          },
          %{report | sampled_at: DateTime.add(report.sampled_at, 10, :second)},
          %{report | pools: [%{hd(report.pools) | free_bytes: -1}]},
          %{report | pools: [%{hd(report.pools) | allocations: %{"vm" => "bad"}}]},
          %{report | pools: [%{hd(report.pools) | allocations: %{"vm" => 1}}]},
          %{report | pools: [nil]}
        ] do
      assert {:error, :invalid_report} =
               HostReports.ingest(host.id, epoch, %{invalid | sequence: 2})
    end

    assert [%{report_sequence: 1}] = Ledger.read!(Host, id: host.id)
    assert [%{free_bytes: free}] = Ledger.read!(StoragePool, id: pool.id)
    assert free == hd(report.pools).free_bytes
  end

  test "an unavailable pool preserves neighbor admission and reservations, then recovers", %{
    host: host,
    pool: pool,
    epoch: epoch,
    report: report
  } do
    {:ok, original} = Marshall.Compute.provision(request(), actor: user())
    before = Ledger.read!(Marshall.Compute.Reservation, vm_id: original.id)

    neighbor =
      pool_fixture(host, %{
        name: "neighbor",
        zpool_guid: "3",
        dataset_guid: "4",
        dataset: "other/lilly"
      })

    healthy = hd(report(neighbor).pools)

    unavailable = %{
      id: pool.id,
      unavailable: true,
      storage:
        Map.take(hd(report.pools).storage, [:backend, :zpool_guid, :dataset_guid, :dataset])
    }

    mixed = %{report | sequence: 2, pools: [unavailable, healthy], sampled_at: Ledger.now()}

    assert {:ok, decoded} =
             mixed
             |> OverallsProtocol.encode_report()
             |> JSON.encode!()
             |> JSON.decode!()
             |> OverallsProtocol.report()

    assert {:ok, :ok} = HostReports.ingest(host.id, epoch, decoded)

    assert [%{reported_at: nil, allocations: allocations, storage_observation: observation}] =
             Ledger.read!(StoragePool, id: pool.id)

    assert allocations == %{} and observation == %{}
    assert [%{reported_at: %DateTime{}}] = Ledger.read!(StoragePool, id: neighbor.id)
    assert before == Ledger.read!(Marshall.Compute.Reservation, vm_id: original.id)
    assert {:ok, moved_admission} = Marshall.Compute.provision(request(), actor: user())
    assert moved_admission.pool_id == neighbor.id

    for invalid <- [
          Map.put(unavailable, :total_bytes, 0),
          put_in(unavailable, [:storage, :dataset_guid], "999")
        ] do
      assert {:error, :invalid_report} =
               HostReports.ingest(host.id, epoch, %{
                 mixed
                 | sequence: 3,
                   pools: [invalid, healthy]
               })
    end

    assert {:ok, :ok} =
             HostReports.ingest(host.id, epoch, %{
               mixed
               | sequence: 3,
                 pools: [hd(report.pools), healthy]
             })

    assert [%{reported_at: %DateTime{}}] = Ledger.read!(StoragePool, id: pool.id)
  end

  test "one filesystem cannot be enrolled as two capacity pools", %{host: host} do
    assert_raise Ash.Error.Invalid, fn ->
      pool_fixture(host, %{name: "duplicate"})
    end
  end

  test "a known zero limit stays fresh and denies admission without releasing a VM", %{
    host: host,
    epoch: epoch,
    report: report
  } do
    {:ok, vm} = Marshall.Compute.provision(request(), actor: user())

    report = %{
      report
      | sequence: 2,
        effective_cores: 0,
        effective_memory_bytes: 0,
        capacity: capacity(0, 0)
    }

    assert {:ok, :ok} = HostReports.ingest(host.id, epoch, report)

    assert [%{reported_at: %DateTime{}, effective_cores: 0, effective_memory_bytes: 0}] =
             Ledger.read!(Host, id: host.id)

    assert {:error, error} = Marshall.Compute.provision(request(), actor: user())
    assert Exception.message(error) =~ "insufficient_capacity"

    assert [%{compute_held: true, disk_held: true}] =
             Ledger.read!(Marshall.Compute.Reservation, vm_id: vm.id)
  end
end
