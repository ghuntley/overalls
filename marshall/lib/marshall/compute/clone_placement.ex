defmodule Marshall.Compute.ClonePlacement do
  @moduledoc "Atomic placement and capacity preparation before any source interruption."
  alias Marshall.Compute.{
    AddressAllocation,
    Budget,
    CloneRequest,
    Host,
    Ledger,
    NetworkAddress,
    Operation,
    Reservation,
    RestartCapacity,
    StoragePool,
    TransferSlot,
    VirtualMachine,
    WorkloadPlacement
  }

  # @cc [owner:ghuntley,label:capacity;concurrency] clone-placement-before-interruption
  # The source queue lock precedes profile and sorted host locks, then VM
  # locks. Destination identity, both capacity holds and distinct-host transfer
  # slots MUST commit together before a stop operation can be created.
  @spec reserve!(CloneRequest.t()) :: CloneRequest.t()
  def reserve!(request) do
    Marshall.Accounts.AccountLifecycle.admit!(request.requested_by_id)

    source =
      case Ledger.read!(VirtualMachine, id: request.source_vm_id) do
        [source] -> source
        [] -> Ledger.rollback(:vm_deleted)
      end

    Marshall.Compute.GitIdentity.require_image!(source.image_id)

    slot = AddressAllocation.next_slot!(source.profile)

    hosts =
      Host |> Ledger.read!() |> Enum.sort_by(& &1.id) |> Enum.map(&Ledger.lock!(Host, &1.id))

    vm = Ledger.lock!(VirtualMachine, source.id) || Ledger.rollback(:vm_deleted)

    actor =
      Ash.get!(Marshall.Accounts.User, request.requested_by_id,
        action: :internal_lookup,
        actor: Marshall.Authorization.SystemActor.compute()
      )

    unless Marshall.Authorization.control_plane?(actor, "provision"),
      do: Ledger.rollback(:forbidden)

    Marshall.Access.Authorization.require!(vm, actor, "manage")

    case Marshall.Compute.Profiles.validate(vm) do
      :ok -> :ok
      {:error, reason} -> Ledger.rollback(reason)
    end

    unless {vm.current_placement_id, vm.execution_epoch} ==
             {source.current_placement_id, source.execution_epoch},
           do: Ledger.rollback(:placement_changed)

    # A previous copy's retained snapshot keeps the source clone-busy; report
    # that as the transient source_cleanup_pending before the generic guard.
    [source_hold] = Ledger.read!(Reservation, placement_id: vm.current_placement_id)
    if source_hold.temporary_disk_bytes != 0, do: Ledger.rollback(:source_cleanup_pending)
    if Marshall.Compute.RelocationGuard.vm_busy?(vm.id), do: Ledger.rollback(:vm_busy)

    unless vm.desired_state in [:running, :stopped] and vm.observed_state == vm.desired_state and
             Enum.all?(
               Ledger.read!(Operation, vm_id: vm.id),
               &(&1.status in [:completed, :cancelled])
             ),
           do: Ledger.rollback(:workload_not_stable)

    source_host = Enum.find(hosts, &(&1.id == vm.host_id)) || Ledger.rollback(:source_unavailable)
    [source_pool] = Ledger.read!(StoragePool, id: vm.pool_id)

    # Distinguish the transient refusals a queued request waits out from a
    # source that cannot be cloned at all: a busy transfer slot and a previous
    # request's retained snapshot clear on their own; staleness does not.
    if transfer_busy?(source_host.id), do: Ledger.rollback(:transfer_busy)

    unless eligible?(source_host, vm) and
             Marshall.Compute.HostLiveness.capacity_fresh?(source_pool.reported_at, Ledger.now()) and
             source_hold.disk_held,
           do: Ledger.rollback(:source_unavailable)

    needed = OverallsProtocol.VMShape.reservation(vm)

    if Budget.physical_disk_available(
         source_host,
         source_pool,
         Ledger.read!(Reservation, host_id: source_host.id)
       ) < needed.disk_bytes,
       do: Ledger.rollback(:insufficient_capacity)

    if vm.desired_state == :running and not RestartCapacity.fits?(source_host, vm, source_hold),
      do: Ledger.rollback(:insufficient_capacity)

    Ledger.update!(source_hold, :hold_temporary_disk, %{temporary_disk_bytes: needed.disk_bytes})

    if vm.desired_state == :running,
      do: Ledger.update!(source_hold, :hold_compute, %{memory_bytes: source_hold.memory_bytes})

    {host, pool} =
      Enum.find_value(hosts, fn host ->
        if eligible?(host, vm) and Marshall.Compute.Profiles.host_ready?(vm, host.inventory) and
             not transfer_busy?(host.id) do
          holds = Ledger.read!(Reservation, host_id: host.id)

          StoragePool
          |> Ledger.read!(host_id: host.id)
          |> Enum.sort_by(& &1.id)
          |> Enum.find_value(fn pool ->
            available = Budget.available(host, pool, holds)

            fits =
              if vm.desired_state == :running,
                do: Budget.fits?(available, needed),
                else: available.disk_bytes >= needed.disk_bytes

            if fits and
                 Marshall.Compute.HostLiveness.capacity_fresh?(pool.reported_at, Ledger.now()),
               do: {host, pool}
          end)
        end
      end) || Ledger.rollback(:insufficient_capacity)

    placement_id = Ash.UUID.generate()
    shape = Map.take(vm, [:architecture, :image_id, :profile, :vcpu, :memory_bytes, :disk_bytes])

    destination =
      Ledger.create!(
        VirtualMachine,
        :allocate,
        Map.merge(shape, %{
          id: request.destination_vm_id,
          name: request.name,
          owner_id: request.requested_by_id,
          git_identity: Marshall.Compute.GitIdentity.snapshot!(request.requested_by_id),
          current_placement_id: placement_id,
          idempotency_key: "clone:" <> request.id
        })
      )

    Ledger.create!(WorkloadPlacement, :allocate, %{
      id: placement_id,
      vm_id: destination.id,
      host_id: host.id,
      pool_id: pool.id
    })

    Ledger.intent!(destination, %{desired_state: :stopped})

    Ledger.create!(
      Reservation,
      :reserve,
      Map.merge(needed, %{
        vm_id: destination.id,
        placement_id: placement_id,
        host_id: host.id,
        pool_id: pool.id,
        compute_held: vm.desired_state == :running
      })
    )

    Ledger.create!(NetworkAddress, :reserve, %{
      vm_id: destination.id,
      profile: vm.profile,
      slot: slot
    })

    for host_id <- Enum.uniq([source_host.id, host.id]),
        do:
          Ledger.create!(TransferSlot, :occupy, %{host_id: host_id, clone_request_id: request.id})

    [source_address] = Ledger.read!(NetworkAddress, vm_id: vm.id)

    specification = %{
      "source" =>
        endpoint(
          vm.id,
          vm.current_placement_id,
          vm.execution_epoch,
          vm.generation,
          source_host.id,
          source_pool.id,
          source_address.slot
        ),
      "destination" => endpoint(destination.id, placement_id, 1, 1, host.id, pool.id, slot),
      "workload" =>
        Map.new(shape, fn {key, value} ->
          {Atom.to_string(key), if(is_atom(value), do: Atom.to_string(value), else: value)}
        end)
    }

    Ledger.update!(request, :prepare, %{
      active: true,
      source_host_id: source_host.id,
      destination_host_id: host.id,
      original_power_state: vm.desired_state,
      specification: specification,
      deferred_reason: nil,
      deferred_at: nil
    })
  end

  defp endpoint(vm, placement, epoch, generation, host, pool, slot),
    do: %{
      "vm_id" => vm,
      "placement_id" => placement,
      "execution_epoch" => epoch,
      "generation" => generation,
      "host_id" => host,
      "pool_id" => pool,
      "slot" => slot
    }

  defp eligible?(host, vm),
    do:
      host.enabled and host.maintenance_mode == :normal and
        host.architecture == vm.architecture and
        host.inventory["execution_ready"] == true and
        Marshall.Compute.HostLiveness.capacity_fresh?(host.reported_at, Ledger.now())

  defp transfer_busy?(host),
    do: Ledger.read!(TransferSlot, host_id: host, released_at: [is_nil: true]) != []
end
