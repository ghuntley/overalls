defmodule Marshall.Compute.Evacuations do
  @moduledoc "Host-serialized evacuation intent and bounded durable relocation scheduling."
  alias Marshall.Authorization.SystemActor
  alias Marshall.Accounts.{AdminEvent, User}

  alias Marshall.Compute.{
    Evacuation,
    EvacuationItem,
    Host,
    Ledger,
    RelocationCapacity,
    RelocationGuard,
    VirtualMachine
  }

  require Ash.Query
  require Marshall.Events

  # @cc [owner:ghuntley,label:security;concurrency;product] evacuation-fixed-authorized-cohort
  # Request MUST recheck current administrator authority under the source host
  # lock and atomically exclude new admission, record a fixed VM/placement/epoch
  # cohort and enqueue advancement. Existing ingress/SSH serving MUST stay enabled.
  # Reusing a request ID with different host/actor meaning MUST fail. Existing
  # relocation or non-running/stopped intent MUST reject without partial changes.
  @spec request(map(), Marshall.Accounts.User.t()) :: {:ok, map()} | {:error, term()}
  def request(args, actor) do
    Ledger.transaction(
      fn ->
        Ecto.Adapters.SQL.query!(
          Marshall.Repo,
          "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
          ["evacuation:" <> args.request_id],
          log: false
        )

        host = Ledger.lock!(Host, args.host_id) || Ledger.rollback(:unknown_host)
        require_admin!(actor)

        case Ledger.read!(Evacuation, id: args.request_id) do
          [existing] ->
            retain_admin!(actor)

            unless existing.host_id == host.id and existing.requested_by_id == actor.id,
              do: Ledger.rollback(:idempotency_conflict)

            {projection(existing), []}

          [] ->
            unless host.enabled and host.maintenance_mode == :normal,
              do: Ledger.rollback(:host_in_maintenance)

            if RelocationGuard.host_busy?(host.id), do: Ledger.rollback(:relocation_in_progress)

            vms =
              VirtualMachine
              |> Ash.Query.filter(host_id == ^host.id)
              |> Ash.Query.sort(:id)
              |> Ash.Query.limit(1001)
              |> Ash.Query.lock(:for_update)
              |> Ash.read!(actor: SystemActor.compute())

            if length(vms) > 1000, do: Ledger.rollback(:evacuation_workload_limit)

            unless Enum.all?(vms, &(&1.desired_state in [:running, :stopped])),
              do: Ledger.rollback(:workload_not_stable)

            retain_admin!(actor)

            campaign =
              Ledger.create!(Evacuation, :record, %{
                id: args.request_id,
                host_id: host.id,
                requested_by_id: actor.id
              })

            Enum.each(vms, fn vm ->
              Ledger.create!(EvacuationItem, :record, %{
                evacuation_id: campaign.id,
                vm_id: vm.id,
                placement_id: vm.current_placement_id,
                execution_epoch: vm.execution_epoch,
                original_state: vm.desired_state
              })
            end)

            Ledger.update!(host, :maintenance, %{maintenance_mode: :evacuating, enabled: true})
            audit!(actor, campaign.id, :evacuation_request)
            {projection(campaign), [{:requested, campaign.id, host.id}]}
        end
      end,
      actor
    )
    |> finish()
  end

  @spec control(map(), Marshall.Accounts.User.t()) :: {:ok, map()} | {:error, term()}
  def control(args, actor) do
    Ledger.transaction(
      fn ->
        {host, campaign} = lock!(args.id)
        retain_admin!(actor)

        unless is_nil(campaign.closed_at), do: Ledger.rollback(:campaign_closed)

        campaign =
          if args.command in [:resume, :retire] do
            unless campaign.status == :ready and host.maintenance_mode == :evacuating and
                     empty?(host),
                   do: Ledger.rollback(:host_not_quiescent)

            {mode, enabled, status} =
              if args.command == :resume,
                do: {:normal, true, :resumed},
                else: {:retired, false, :retired}

            if args.command == :retire,
              do: {:ok, :ok} = Marshall.Compute.Credentials.revoke(host.id)

            Ledger.update!(host, :maintenance, %{maintenance_mode: mode, enabled: enabled})

            campaign =
              Ledger.update!(campaign, status_action(status), %{
                closed_at: Ledger.now(),
                controlled_by_id: actor.id
              })

            audit!(actor, campaign.id, :evacuation_control)
            campaign
          else
            unless campaign.status in [:active, :paused], do: Ledger.rollback(:campaign_closed)
            status = if args.command == :pause, do: :paused, else: :active

            campaign =
              Ledger.update!(campaign, status_action(status), %{controlled_by_id: actor.id})

            audit!(actor, campaign.id, :evacuation_control)
            campaign
          end

        {projection(campaign), [{:controlled, campaign.id, host.id, campaign.status}]}
      end,
      actor
    )
    |> finish()
  end

  # @cc [owner:ghuntley,label:security;product] evacuation-downtime-placement-bound
  # Full stopped-copy approval MUST record the current administrator and time for
  # one fixed running workload's placement/epoch. Approval MUST reject changed
  # workloads or already accepted moves; it MUST NOT grant approval to other VMs.
  @spec approve(map(), Marshall.Accounts.User.t()) :: {:ok, map()} | {:error, term()}
  def approve(args, actor) do
    Ledger.transaction(
      fn ->
        {_host, campaign} = lock!(args.id)
        require_admin!(actor)

        unless is_nil(campaign.closed_at) and campaign.status in [:active, :paused],
          do: Ledger.rollback(:campaign_closed)

        item = Ledger.lock!(EvacuationItem, args.item_id) || Ledger.rollback(:unknown_workload)

        unless item.evacuation_id == campaign.id and is_nil(item.relocation_id) and
                 is_nil(item.resolved_at) and item.request_key == args.expected_key,
               do: Ledger.rollback(:invalid_workload)

        vm = Ledger.lock!(VirtualMachine, item.vm_id)
        retain_admin!(actor)

        unless matches?(item, vm) and item.original_state == :running,
          do: Ledger.rollback(:workload_changed)

        if is_nil(item.approved_at),
          do:
            Ledger.update!(item, :approve, %{approved_at: Ledger.now(), approved_by_id: actor.id})

        audit!(actor, item.id, :evacuation_approve)

        {%{id: item.id, approved: true}, [{:approved, campaign.id, item.vm_id}]}
      end,
      actor
    )
    |> finish()
  end

  # @cc [owner:ghuntley,label:security;recovery] evacuation-explicit-replan
  # Re-planning MUST require current administrator permission and the displayed
  # item revision, reject unfinished moves/resizes, bind the current placement,
  # epoch and desired state, and clear prior downtime approval. A fresh request
  # key MUST prevent reuse of a cancelled relocation. Already removed workloads
  # may be resolved, but readiness still requires physical source cleanup.
  @spec replan(map(), Marshall.Accounts.User.t()) :: {:ok, map()} | {:error, term()}
  def replan(args, actor) do
    Ledger.transaction(
      fn ->
        {host, campaign} = lock!(args.id)
        require_admin!(actor)

        unless is_nil(campaign.closed_at) and campaign.status in [:active, :paused],
          do: Ledger.rollback(:campaign_closed)

        item = Ledger.lock!(EvacuationItem, args.item_id) || Ledger.rollback(:unknown_workload)

        unless item.evacuation_id == campaign.id and item.request_key == args.expected_key,
          do: Ledger.rollback(:workload_changed)

        vm = Ledger.lock_history!(VirtualMachine, item.vm_id)
        retain_admin!(actor)
        unless vm, do: Ledger.rollback(:unknown_workload)
        if RelocationGuard.vm_busy?(vm.id), do: Ledger.rollback(:relocation_in_progress)
        removed = not is_nil(vm.archived_at) or vm.host_id != host.id

        unless removed or vm.desired_state in [:running, :stopped],
          do: Ledger.rollback(:workload_not_stable)

        values = %{
          request_key: Ash.UUID.generate(),
          replanned_by_id: actor.id,
          approved_at: nil,
          approved_by_id: nil,
          attempted_at: nil,
          blocker: nil,
          relocation_id: nil,
          resolved_at: if(removed, do: Ledger.now())
        }

        values =
          if removed,
            do: values,
            else:
              Map.merge(values, %{
                placement_id: vm.current_placement_id,
                execution_epoch: vm.execution_epoch,
                original_state: vm.desired_state
              })

        item = Ledger.update!(item, if(removed, do: :resolve, else: :replan), values)
        audit!(actor, item.id, :evacuation_replan)

        {Map.take(item, [:id, :request_key, :resolved_at]),
         [{:replanned, campaign.id, item.vm_id}]}
      end,
      actor
    )
    |> finish()
  end

  # @cc [owner:ghuntley,label:recovery;capacity;security] evacuation-durable-bounded-scheduling
  # Each advance MUST lock all candidate hosts in UUID order before campaign/VM
  # state, admit at most one fixed cohort workload and commit its relocation link
  # with reservations/jobs. Pausing MUST prevent new admissions but MUST NOT cancel
  # accepted moves. Accepted campaign authority survives requester demotion.
  # Blocked workloads rotate by attempt time; blockers MUST be fixed safe codes.
  @spec advance(String.t()) :: {:ok, atom()} | {:error, term()}
  def advance(id) do
    candidates =
      EvacuationItem
      |> Ash.Query.filter(evacuation_id == ^id and is_nil(relocation_id) and is_nil(resolved_at))
      |> Ash.Query.sort(attempted_at: :asc_nils_first, id: :asc)
      |> Ash.Query.limit(1)
      |> Ash.read!(actor: SystemActor.compute())

    item_id =
      case candidates do
        [item] -> item.id
        [] -> nil
      end

    expected_key =
      case candidates do
        [item] -> item.request_key
        [] -> nil
      end

    result =
      Ledger.transaction(fn ->
        campaign = fetch!(id)

        hosts =
          Host
          |> Ash.Query.sort(:id)
          |> Ash.Query.limit(129)
          |> Ash.read!(actor: SystemActor.compute())

        if length(hosts) > 128, do: Ledger.rollback(:evacuation_host_limit)
        hosts = Enum.map(hosts, &Ledger.lock!(Host, &1.id))
        campaign = Ledger.lock!(Evacuation, campaign.id)
        source = Enum.find(hosts, &(&1.id == campaign.host_id))

        if campaign.status == :active and is_nil(campaign.closed_at) and not is_nil(source) and
             source.enabled and source.maintenance_mode == :evacuating do
          item = if item_id, do: Ledger.lock!(EvacuationItem, item_id)

          case item do
            nil ->
              if empty?(source) do
                Ledger.update!(campaign, :confirm_ready, %{ready_at: Ledger.now()})
                :ready
              else
                :awaiting_cleanup
              end

            %{relocation_id: relocation_id} when not is_nil(relocation_id) ->
              :already_scheduled

            %{request_key: key} when key != expected_key ->
              :plan_changed

            item ->
              vm = Ledger.lock!(VirtualMachine, item.vm_id)
              unless matches?(item, vm), do: Ledger.rollback(:workload_changed)

              relocation =
                RelocationCapacity.reserve_evacuation_locked!(vm, hosts, campaign, item)

              Ledger.update!(item, :schedule, %{
                relocation_id: relocation.id,
                attempted_at: Ledger.now(),
                blocker: nil
              })

              :scheduled
          end
        else
          :paused
        end
      end)

    case result do
      {:error, reason}
      when reason in [
             :workload_changed,
             :workload_not_stable,
             :source_unavailable,
             :transfer_busy,
             :insufficient_capacity,
             :downtime_approval_required,
             :resize_in_progress,
             :relocation_in_progress,
             :clone_in_progress
           ] and not is_nil(item_id) ->
        record_blocker(id, item_id, expected_key, reason)

      other ->
        other
    end
  end

  defp record_blocker(id, item_id, expected_key, reason) do
    result =
      Ledger.transaction(fn ->
        {host, campaign} = lock!(id)
        item = Ledger.lock!(EvacuationItem, item_id)

        if campaign.status == :active and is_nil(item.relocation_id) and is_nil(item.resolved_at) and
             item.request_key == expected_key,
           do: Ledger.update!(item, :block, %{attempted_at: Ledger.now(), blocker: reason})

        {:blocked, host.id}
      end)

    case result do
      {:ok, {:blocked, host_id}} ->
        unless Marshall.Repo.in_transaction?() do
          Marshall.Events.emit("evacuation.blocked",
            evacuation_id: id,
            host_id: host_id,
            reason: reason
          )
        end

        {:ok, :blocked}

      other ->
        other
    end
  end

  defp finish(result) do
    case result do
      {:ok, {value, events}} ->
        unless Marshall.Repo.in_transaction?() do
          Enum.each(events, &emit/1)
        end

        {:ok, value}

      other ->
        other
    end
  end

  defp emit({:requested, evacuation_id, host_id}),
    do:
      Marshall.Events.emit("evacuation.requested", evacuation_id: evacuation_id, host_id: host_id)

  defp emit({:controlled, evacuation_id, host_id, status}),
    do:
      Marshall.Events.emit("evacuation.controlled",
        evacuation_id: evacuation_id,
        host_id: host_id,
        operation_status: status
      )

  defp emit({:approved, evacuation_id, vm_id}),
    do: Marshall.Events.emit("evacuation.approved", evacuation_id: evacuation_id, vm_id: vm_id)

  defp emit({:replanned, evacuation_id, vm_id}),
    do: Marshall.Events.emit("evacuation.replanned", evacuation_id: evacuation_id, vm_id: vm_id)

  # @cc [owner:ghuntley,label:recovery;capacity] evacuation-ready-physical-empty
  # Readiness and resume/retirement MUST require fresh execution-ready host and
  # pool reports, no current workloads, no held resources and no unfinished move.
  # Enqueued/completed jobs, elapsed time and old readiness timestamps MUST NOT
  # establish physical cleanup. Resume restores admission without moving guests back.
  defp empty?(host) do
    now = Ledger.now()

    host.inventory["execution_ready"] == true and
      Marshall.Compute.HostLiveness.capacity_fresh?(host.reported_at, now) and
      not RelocationGuard.host_busy?(host.id) and
      not present?(VirtualMachine |> Ash.Query.filter(host_id == ^host.id)) and
      not present?(
        Marshall.Compute.Reservation
        |> Ash.Query.filter(
          host_id == ^host.id and
            (compute_held or disk_held or temporary_disk_bytes > 0)
        )
      ) and
      Enum.all?(
        Ledger.read!(Marshall.Compute.StoragePool, host_id: host.id),
        &(Marshall.Compute.HostLiveness.capacity_fresh?(&1.reported_at, now) and
            &1.allocations == %{})
      )
  end

  defp present?(query),
    do: query |> Ash.Query.limit(1) |> Ash.read!(actor: SystemActor.compute()) != []

  @doc "Caller holds the source host lock; this permits only a campaign-bound outgoing move."
  @spec source_allowed?(Host.t(), map()) :: boolean()
  def source_allowed?(host, relocation) do
    host.enabled and
      (host.maintenance_mode == :normal or
         (host.maintenance_mode == :evacuating and host.id == relocation.source_host_id and
            not is_nil(relocation.evacuation_id) and
            case Ledger.read!(Evacuation,
                   id: relocation.evacuation_id,
                   host_id: host.id,
                   closed_at: [is_nil: true]
                 ) do
              [%{status: status}] -> status in [:active, :paused]
              _ -> false
            end))
  end

  @doc false
  def matches?(item, vm),
    do:
      vm != nil and vm.current_placement_id == item.placement_id and
        vm.execution_epoch == item.execution_epoch and vm.desired_state == item.original_state

  defp fetch!(id) do
    case Ledger.read!(Evacuation, id: id) do
      [campaign] -> campaign
      _ -> Ledger.rollback(:unknown_evacuation)
    end
  end

  defp lock!(id) do
    campaign = fetch!(id)
    host = Ledger.lock!(Host, campaign.host_id)
    {host, Ledger.lock!(Evacuation, id)}
  end

  defp audit!(actor, target_id, kind) do
    Ledger.create!(AdminEvent, :record, %{actor_id: actor.id, target_id: target_id, kind: kind})
    :ok
  end

  defp require_admin!(actor) do
    unless Marshall.Authorization.control_plane?(actor, "admin_operate"),
      do: Ledger.rollback(:forbidden)
  end

  # @cc [owner:ghuntley,label:security;concurrency] evacuation-control-authority-commit
  # New user controls MUST retain current actor authority through commit, after
  # all Host/campaign/item/VM locks. Guest identity allocation locks VM before User;
  # evacuation MUST preserve that order. The actor lock MUST permit ordinary
  # foreign-key references while excluding role, elevation and login changes.
  # Durable worker advancement MUST NOT reacquire original requester authority.
  @spec retain_admin!(User.t()) :: :ok
  defp retain_admin!(actor) do
    User
    |> Ash.Query.for_read(:internal_lookup, %{}, actor: SystemActor.compute())
    |> Ash.Query.filter(id == ^actor.id)
    |> Ash.Query.lock("FOR NO KEY UPDATE")
    |> Ash.read_one!()

    require_admin!(actor)
    :ok
  end

  defp projection(campaign),
    do: Map.take(campaign, [:id, :host_id, :status, :ready_at, :closed_at])

  defp status_action(:paused), do: :pause
  defp status_action(:active), do: :continue
  defp status_action(:resumed), do: :resume
  defp status_action(:retired), do: :retire
end
