defmodule Marshall.Compute.EvacuationViews do
  @moduledoc "Bounded current-administrator Lilly node and campaign projections."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Authorization.SystemActor
  alias Marshall.Administration.JobSnapshot

  alias Marshall.Compute.{
    Evacuation,
    EvacuationItem,
    Budget,
    Host,
    Ledger,
    Relocation,
    RelocationCapacity,
    RelocationStatus,
    Reservation,
    StoragePool,
    VirtualMachine
  }

  require Ash.Query

  @host_fields [
    :id,
    :name,
    :architecture,
    :enabled,
    :maintenance_mode,
    :reported_at,
    :overhead_cores,
    :overhead_memory_bytes
  ]
  @host_select_fields @host_fields ++ [:inventory]
  @blockers ~w(workload_changed workload_not_stable source_unavailable transfer_busy insufficient_capacity downtime_approval_required resize_in_progress relocation_in_progress clone_in_progress)a

  # @cc [owner:ghuntley,label:security;capacity] evacuation-admin-bounded-projections
  # Recheck current Control room read authority before reads. Return at most 50 nodes or 20
  # cohort/workload rows per keyset page, never credentials/transfer endpoints.
  # Preview MUST be explicit, advisory and write-free, using actual admission
  # selection. Progress MUST describe the linked relocation, not a newer VM move.
  @impl true
  def run(input, _, %{actor: actor}) do
    if Marshall.Authorization.control_plane?(actor, "admin_read") do
      case input.action.name do
        :nodes_for_admin -> nodes(input.arguments)
        :inspect_for_admin -> inspect_node(input.arguments)
        :capacity_for_admin -> capacity(input.arguments)
        :timeline_for_admin -> timeline(input.arguments)
      end
    else
      {:error, Ash.Error.Forbidden.exception([])}
    end
  end

  defp nodes(args) do
    query = Host |> Ash.Query.select(@host_select_fields) |> Ash.Query.sort(:id)

    with {:ok, hosts} <- Ash.read(page(query, args[:after], 50), actor: SystemActor.compute()) do
      now = Ledger.now()

      {:ok,
       %{items: Enum.map(Enum.take(hosts, 50), &host(&1, now)), next_cursor: cursor(hosts, 50)}}
    end
  end

  # @cc [owner:ghuntley,label:capacity;security] admin-capacity-complete-holds
  # Capacity detail MUST include all active startup/copy/resize holds across host
  # pools. Above 10000 active records, fail rather than truncate arithmetic. Return
  # at most 20 pool explanations per page and distinguish freshness/admission mode
  # from raw arithmetic; observations never authorize a mutation.
  defp capacity(args) do
    case Ledger.read!(Host, id: args.host_id) do
      [source] ->
        now = Ledger.now()

        reservations =
          Reservation
          |> Ash.Query.filter(
            host_id == ^source.id and
              (compute_held or disk_held or temporary_disk_bytes > 0 or pending_disk_bytes > 0)
          )
          |> Ash.Query.limit(10_001)
          |> Ash.read!(actor: SystemActor.compute())

        if length(reservations) > 10_000 do
          {:error, "Capacity detail exceeds the bounded read limit"}
        else
          pools =
            StoragePool
            |> Ash.Query.filter(host_id == ^source.id)
            |> Ash.Query.sort(:id)
            |> page(args[:after], 20)
            |> Ash.read!(actor: SystemActor.compute())

          {:ok,
           %{
             host: host(source, now),
             observed_at: now,
             admission_enabled: source.enabled and source.maintenance_mode == :normal,
             execution_ready: source.inventory["execution_ready"] == true,
             pools:
               Enum.map(Enum.take(pools, 20), fn pool ->
                 %{
                   id: pool.id,
                   name: pool.name,
                   fresh: Marshall.Compute.HostLiveness.capacity_fresh?(pool.reported_at, now),
                   budget: Budget.explain(source, pool, reservations)
                 }
               end),
             next_cursor: cursor(pools, 20)
           }}
        end

      _ ->
        {:error, "Unknown node"}
    end
  end

  defp inspect_node(args) do
    case Ledger.read!(Host, id: args.host_id) do
      [source] ->
        campaign =
          Evacuation
          |> Ash.Query.filter(host_id == ^source.id and is_nil(closed_at))
          |> Ash.Query.sort(inserted_at: :desc, id: :desc)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(actor: SystemActor.compute())

        campaign_history = campaigns_for_host(source.id)

        {rows, next_cursor} = workloads(source, campaign, args[:after])

        hosts =
          if args.preview,
            do:
              Host
              |> Ash.Query.sort(:id)
              |> Ash.Query.limit(129)
              |> Ash.read!(actor: SystemActor.compute()),
            else: []

        rows =
          Enum.map(rows, fn {item, vm} ->
            projection = %{
              id: if(item, do: item.id, else: vm.id),
              vm_id: if(item, do: item.vm_id, else: vm.id),
              name: if(vm, do: vm.name, else: "Removed workload"),
              desired_state: if(vm, do: vm.desired_state),
              observed_state: if(vm, do: vm.observed_state),
              item:
                if(item,
                  do:
                    Map.take(item, [
                      :id,
                      :relocation_id,
                      :request_key,
                      :blocker,
                      :approved_at,
                      :original_state,
                      :resolved_at,
                      :attempted_at
                    ])
                ),
              progress: progress(item),
              preview: nil
            }

            if args.preview and not is_nil(vm) and
                 (is_nil(item) or (is_nil(item.relocation_id) and is_nil(item.resolved_at))) do
              Map.put(projection, :preview, preview(vm, hosts, source.maintenance_mode))
            else
              projection
            end
          end)

        timeline =
          (timeline_events(campaign, rows) ++
             Enum.flat_map(campaign_history, &historical_campaign_events/1))
          |> Enum.sort_by(& &1.at, {:desc, DateTime})
          |> Enum.take(200)

        {:ok,
         %{
           host: host(source, Ledger.now()),
           campaign:
             if(campaign,
               do: Map.take(campaign, [:id, :status, :inserted_at, :ready_at, :closed_at])
             ),
           items: rows,
           next_cursor: next_cursor,
           preview: args.preview,
           timeline: timeline,
           campaign_history:
             Enum.map(
               campaign_history,
               &Map.take(&1, [:id, :status, :inserted_at, :ready_at, :closed_at])
             )
         }}

      _ ->
        {:error, "Unknown node"}
    end
  end

  defp timeline(%{host_id: host_id}) do
    case Ledger.read!(Host, id: host_id) do
      [source] ->
        campaign =
          Evacuation
          |> Ash.Query.filter(host_id == ^source.id and is_nil(closed_at))
          |> Ash.Query.sort(inserted_at: :desc, id: :desc)
          |> Ash.Query.limit(1)
          |> Ash.read_one!(actor: SystemActor.compute())

        campaign_history = campaigns_for_host(source.id)

        if campaign do
          {rows, _} = workloads(source, campaign, nil)

          timeline =
            (timeline_events(campaign, rows) ++
               Enum.flat_map(campaign_history, &historical_campaign_events/1))
            |> Enum.sort_by(& &1.at, {:desc, DateTime})
            |> Enum.take(200)

          {:ok, %{host: host(source, Ledger.now()), timeline: timeline}}
        else
          {:ok,
           %{
             host: host(source, Ledger.now()),
             timeline: Enum.flat_map(campaign_history, &historical_campaign_events/1)
           }}
        end

      _ ->
        {:error, "Unknown node"}
    end
  end

  defp timeline_events(nil, _rows), do: []

  defp timeline_events(campaign, rows) do
    requested_at = campaign.inserted_at || campaign.ready_at || DateTime.utc_now()

    campaign_events =
      [
        %{
          at: requested_at,
          kind: :campaign_requested,
          campaign_id: campaign.id,
          vm_id: nil,
          relocation_id: nil
        },
        %{
          at: campaign.ready_at,
          kind: :source_ready,
          campaign_id: campaign.id,
          vm_id: nil,
          relocation_id: nil
        },
        %{
          at: campaign.closed_at,
          kind: :campaign_closed,
          campaign_id: campaign.id,
          vm_id: nil,
          relocation_id: nil
        }
      ]

    item_events =
      Enum.flat_map(rows, fn
        %{item: item, vm_id: vm_id} -> timeline_item_events(item, vm_id)
        {item, vm} -> timeline_item_events(item, if(item, do: item.vm_id, else: vm.id))
      end)

    job_events = job_timeline_events(rows)
    relocation_events = relocation_timeline_events(rows)

    (campaign_events ++ item_events ++ job_events ++ relocation_events)
    |> Enum.reject(&is_nil(&1.at))
    |> Enum.sort_by(& &1.at, {:desc, DateTime})
    |> Enum.take(200)
  end

  # Retained relocation milestones provide the command/readiness/cleanup side of
  # the timeline without loading raw command payloads or terminal contents.
  defp relocation_timeline_events(rows) do
    ids =
      rows
      |> Enum.map(fn %{item: item} -> if(item, do: item[:relocation_id]) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    if ids == [] do
      []
    else
      Relocation
      |> Ash.Query.filter(id in ^ids)
      |> Ash.Query.select([
        :id,
        :vm_id,
        :committed_at,
        :source_restored_at,
        :source_snapshot_cleanup_offered_at,
        :source_snapshots_cleaned_at,
        :destination_cleanup_offered_at,
        :destination_cleaned_at,
        :cancellation_requested_at
      ])
      |> Ash.read!(actor: SystemActor.compute())
      |> Enum.flat_map(fn relocation ->
        [
          {:relocation_committed, relocation.committed_at},
          {:source_restored, relocation.source_restored_at},
          {:source_cleanup_requested, relocation.source_snapshot_cleanup_offered_at},
          {:source_cleanup_confirmed, relocation.source_snapshots_cleaned_at},
          {:destination_cleanup_requested, relocation.destination_cleanup_offered_at},
          {:destination_cleanup_confirmed, relocation.destination_cleaned_at},
          {:cancellation_requested, relocation.cancellation_requested_at}
        ]
        |> Enum.reject(fn {_kind, at} -> is_nil(at) end)
        |> Enum.map(fn {kind, at} ->
          %{at: at, kind: kind, vm_id: relocation.vm_id, relocation_id: relocation.id}
        end)
      end)
    end
  end

  defp historical_campaign_events(campaign) do
    requested_at = campaign.inserted_at || campaign.ready_at || DateTime.utc_now()

    [
      %{
        at: requested_at,
        kind: :campaign_requested,
        campaign_id: campaign.id,
        vm_id: nil,
        relocation_id: nil
      },
      %{
        at: campaign.ready_at,
        kind: :source_ready,
        campaign_id: campaign.id,
        vm_id: nil,
        relocation_id: nil
      },
      %{
        at: campaign.closed_at,
        kind: :campaign_closed,
        campaign_id: campaign.id,
        vm_id: nil,
        relocation_id: nil
      }
    ]
    |> Enum.reject(&is_nil(&1.at))
  end

  # @cc [owner:ghuntley,label:recovery;security] evacuation-job-correlation
  # Timeline enrichment MUST use retained redacted job snapshots, bounded by the
  # displayed cohort's relocation IDs. Raw Oban arguments and error payloads never
  # enter the maintenance projection.
  defp job_timeline_events(rows) do
    relocation_to_vm =
      rows
      |> Enum.map(fn
        %{item: %{relocation_id: id}, vm_id: vm_id} when not is_nil(id) -> {id, vm_id}
        {%{relocation_id: id}, vm} when not is_nil(id) -> {id, vm.id}
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)
      |> Map.new()

    ids = Map.keys(relocation_to_vm)

    if ids == [] do
      []
    else
      JobSnapshot
      |> Ash.Query.filter(subject_kind == :relocation and subject_id in ^ids)
      |> Ash.Query.sort(captured_at: :desc, id: :desc)
      |> Ash.Query.limit(201)
      |> Ash.read!(actor: SystemActor.compute())
      |> Enum.take(200)
      |> Enum.map(fn job ->
        %{
          at: job.captured_at,
          kind: :job_state,
          vm_id: relocation_to_vm[job.subject_id],
          relocation_id: job.subject_id,
          job_id: job.id,
          state: job.state,
          attempt: job.attempt
        }
      end)
    end
  end

  defp timeline_item_events(nil, vm_id),
    do: [%{at: nil, kind: :workload_observed, vm_id: vm_id, relocation_id: nil}]

  defp timeline_item_events(item, vm_id) do
    if item do
      [
        %{
          at: item.approved_at,
          kind: :downtime_approved,
          vm_id: vm_id,
          relocation_id: item[:relocation_id]
        },
        %{
          at: item.attempted_at,
          kind: :relocation_started,
          vm_id: vm_id,
          relocation_id: item[:relocation_id]
        },
        %{
          at: item.resolved_at,
          kind: :workload_resolved,
          vm_id: vm_id,
          relocation_id: item[:relocation_id]
        }
      ]
    else
      []
    end
  end

  defp workloads(source, nil, after_id) do
    rows =
      VirtualMachine
      |> Ash.Query.filter(host_id == ^source.id)
      |> Ash.Query.sort(:id)
      |> page(after_id, 20)
      |> Ash.read!(actor: SystemActor.compute())

    {Enum.map(Enum.take(rows, 20), &{nil, &1}), cursor(rows, 20)}
  end

  defp workloads(_source, campaign, after_id) do
    rows =
      EvacuationItem
      |> Ash.Query.filter(evacuation_id == ^campaign.id)
      |> Ash.Query.sort(:id)
      |> page(after_id, 20)
      |> Ash.read!(actor: SystemActor.compute())

    ids = Enum.map(Enum.take(rows, 20), & &1.vm_id)

    vms =
      VirtualMachine
      |> Ash.Query.filter(id in ^ids)
      |> Ash.read!(actor: SystemActor.compute())
      |> Map.new(&{&1.id, &1})

    {Enum.map(Enum.take(rows, 20), &{&1, vms[&1.vm_id]}), cursor(rows, 20)}
  end

  defp campaigns_for_host(host_id) do
    Evacuation
    |> Ash.Query.filter(host_id == ^host_id)
    |> Ash.Query.sort(inserted_at: :desc, id: :desc)
    |> Ash.Query.limit(21)
    |> Ash.read!(actor: SystemActor.compute())
  end

  defp preview(vm, hosts, mode) when length(hosts) <= 128 and mode in [:normal, :evacuating] do
    case RelocationCapacity.preview(vm, hosts, mode) do
      {:ok, plan} -> plan
      {:error, reason} when reason in @blockers -> %{blocker: reason}
      _ -> %{blocker: :unavailable}
    end
  end

  defp preview(_, _, _), do: %{blocker: :unavailable}
  defp progress(nil), do: nil
  defp progress(%{relocation_id: nil}), do: nil

  defp progress(item) do
    case Ledger.read!(Relocation, id: item.relocation_id, evacuation_id: item.evacuation_id) do
      [relocation] -> RelocationStatus.describe(relocation)
      _ -> nil
    end
  end

  defp page(query, after_id, limit) do
    query = if after_id, do: Ash.Query.filter(query, id > ^after_id), else: query
    Ash.Query.limit(query, limit + 1)
  end

  defp cursor(rows, limit), do: if(length(rows) > limit, do: Enum.at(rows, limit - 1).id)

  defp host(record, now) do
    fresh = Marshall.Compute.HostLiveness.capacity_fresh?(record.reported_at, now)
    terminal_protocol = if is_map(record.inventory), do: record.inventory["terminal_protocol"]

    record
    |> Map.take(@host_fields)
    |> Map.merge(%{
      fresh: fresh,
      terminal_protocol: terminal_protocol,
      terminal_report_ready: fresh and terminal_protocol == 2,
      terminal_stream_ready: Marshall.Terminal.Relay.ready?(record.id)
    })
  end
end
