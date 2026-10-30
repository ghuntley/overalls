defmodule Marshall.Compute.Admission do
  @moduledoc "Atomic capacity admission; no acceptance exists without its durable job."
  use Ash.Resource.Actions.Implementation
  require Ash.Query
  require Marshall.Events
  alias Marshall.Authorization.SystemActor

  alias Marshall.Compute.{
    Budget,
    AddressAllocation,
    Host,
    Image,
    Ledger,
    NetworkAddress,
    Operation,
    Reservation,
    StoragePool,
    VirtualMachine,
    WorkloadPlacement,
    WorkspaceSource
  }

  alias Marshall.Repo

  @request_fields [
    :architecture,
    :image_id,
    :profile,
    :vcpu,
    :memory_bytes,
    :disk_bytes
  ]

  # @cc [owner:ghuntley,label:product] admission-durable-idempotency
  # The same owner/key and request shape MUST return the original VM, including
  # archived history; changing the resolved name, architecture, image, profile, size or
  # workspace source MUST fail with idempotency_conflict without creating another allocation.

  # @cc [owner:ghuntley,label:concurrency] admission-all-or-nothing
  # A successful new admission MUST commit the VM, placement, capacity reservation, profile
  # address, provision operation, audit and dispatch job in one transaction.
  # Any failure, including job insertion, MUST leave none of these new records.
  @impl true
  def run(input, _opts, context) do
    result =
      Ledger.transaction(
        fn ->
          Marshall.Accounts.AccountLifecycle.admit!(context.actor.id)
          # A DB lock spans retries reaching different nodes, including the first
          # request before there is a row to lock. Hash collisions only serialize.
          Ecto.Adapters.SQL.query!(
            Repo,
            "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
            [context.actor.id <> ":" <> input.arguments.idempotency_key],
            log: false
          )

          case Ledger.history!(VirtualMachine,
                 owner_id: context.actor.id,
                 idempotency_key: input.arguments.idempotency_key
               ) do
            [vm] ->
              name =
                Map.get(input.arguments, :name) || OverallsProtocol.MachineName.generated(vm.id)

              if vm.name == name and vm.team_id == Map.get(input.arguments, :team_id) and
                   stored_source(vm.id) == Map.get(input.arguments, :workspace_source) and
                   Map.merge(
                     request_shape(vm),
                     Map.new(vm.provisioning_sizes, fn {key, value} ->
                       {String.to_existing_atom(key), value}
                     end)
                   ) == request_shape(input.arguments) do
                {vm, false}
              else
                Ledger.rollback(:idempotency_conflict)
              end

            [] ->
              {allocate(input.arguments, context.actor),
               Map.get(input.arguments, :workspace_source) != nil}
          end
        end,
        context.actor
      )

    case result do
      {:ok, {vm, source_recorded?}} ->
        # A caller such as SSH admission may still need to commit its receipt.
        # That caller owns the eventual success diagnostic for an outer transaction.
        unless Repo.in_transaction?() do
          Marshall.Events.emit("vm.capacity_reserved", vm_id: vm.id, host_id: vm.host_id)

          if source_recorded?,
            do: Marshall.Events.emit("vm.workspace_source_recorded", vm_id: vm.id)
        end

        {:ok, vm}

      {:error, reason} when is_atom(reason) ->
        unless Repo.in_transaction?() do
          Marshall.Events.emit("vm.admission_refused", reason: reason)
        end

        {:error, Marshall.Compute.Error.exception(reason: reason)}

      {:error, error} ->
        {:error, error}
    end
  end

  defp request_shape(value), do: Map.new(@request_fields, &{&1, Map.get(value, &1)})

  @spec stored_source(Ecto.UUID.t()) :: OverallsProtocol.WorkspaceSource.t() | nil
  defp stored_source(vm_id) do
    case Ledger.read!(WorkspaceSource, vm_id: vm_id) do
      [source] -> WorkspaceSource.protocol(source)
      [] -> nil
    end
  end

  # @cc [owner:ghuntley,label:security] admission-workspace-source-egress-only
  # A workspace source MUST be a closed protocol provider reference and MUST be
  # refused for profiles without egress before any allocation. An accepted source
  # MUST be recorded in the allocation transaction before the provision operation
  # pins its command snapshot.
  @spec source_admissible!(map()) :: :ok
  defp source_admissible!(%{workspace_source: source} = request) when source != nil do
    cond do
      not OverallsProtocol.WorkspaceSource.valid?(source) ->
        Ledger.rollback(:invalid_workspace_source)

      not OverallsProtocol.ProfilePolicy.allows?(request.profile, :egress) ->
        Ledger.rollback(:workspace_source_not_allowed)

      true ->
        :ok
    end
  end

  defp source_admissible!(_), do: :ok

  # @cc [owner:ghuntley,label:capacity] admission-executable-placement
  # Placement MUST require an enabled image meeting architecture and size minima,
  # an enabled normal-mode v4 execution-ready host advertising that image, fresh
  # host and pool reports, and capacity including the protocol's VMM overhead.
  # If no candidate satisfies every condition, admission MUST reject atomically.

  # @cc [owner:ghuntley,label:security] admission-team-provisioning
  # Provisioning into a team MUST require a current owner or admin membership
  # of the actor, evaluated fresh through Cedar; team membership is immutable
  # on the machine after allocation.
  defp allocate(request, actor) do
    vm_id = Ash.UUID.generate()
    name = Map.get(request, :name) || OverallsProtocol.MachineName.generated(vm_id)
    reserve_name!(name)
    request = Map.put(request, :name, name)
    team_authorized!(request[:team_id], actor)

    unless OverallsProtocol.VMShape.valid?(
             request.vcpu,
             request.memory_bytes,
             request.disk_bytes
           ),
           do: Ledger.rollback(:invalid_vm_size)

    case Marshall.Compute.Profiles.validate(request) do
      :ok -> :ok
      {:error, reason} -> Ledger.rollback(reason)
    end

    source_admissible!(request)

    reservation = OverallsProtocol.VMShape.reservation(request)
    # Lock ordering: idempotency, image, profile, hosts in UUID order. Configure
    # takes the image row lock too, so disabling an image is ordered with admission.
    image =
      Image
      |> Ash.Query.filter(id == ^request.image_id)
      |> Ash.Query.lock("FOR SHARE")
      |> Ash.read_one!(actor: SystemActor.compute())

    if image == nil or not image.enabled, do: Ledger.rollback(:image_unavailable)

    source_image_admissible!(request, image)
    Marshall.Compute.GitIdentity.require_image!(image.id)

    unless Image.requirements_met?(image, request),
      do: Ledger.rollback(:image_requirements_not_met)

    slot = AddressAllocation.next_slot!(request.profile)

    hosts =
      Host
      |> Ash.Query.filter(enabled == true and architecture == ^request.architecture)
      |> Ash.Query.sort(:id)
      |> Ash.read!(actor: SystemActor.compute())

    placement =
      Enum.find_value(hosts, fn candidate ->
        host = Ledger.lock!(Host, candidate.id)
        now = Ledger.now()

        if host.enabled and host.maintenance_mode == :normal and
             Map.get(host.inventory, "execution_ready") == true and
             Marshall.Compute.Profiles.host_ready?(request, host.inventory) and
             Marshall.Compute.HostLiveness.capacity_fresh?(host.reported_at, now) and
             request.image_id in Map.get(host.inventory, "images", []) do
          reservations = Ledger.read!(Reservation, host_id: host.id)

          StoragePool
          |> Ledger.read!(host_id: host.id)
          |> Enum.sort_by(& &1.id)
          |> Enum.find_value(fn pool ->
            if Marshall.Compute.HostLiveness.capacity_fresh?(pool.reported_at, now) and
                 Budget.fits?(Budget.available(host, pool, reservations), reservation) do
              {host, pool}
            end
          end)
        end
      end)

    case placement do
      nil ->
        Ledger.rollback(:insufficient_capacity)

      {host, pool} ->
        placement_id = Ash.UUID.generate()

        vm =
          Ledger.create!(
            VirtualMachine,
            :allocate,
            Map.merge(Map.delete(request, :workspace_source), %{
              provisioning_sizes: OverallsProtocol.Resize.sizes(request),
              id: vm_id,
              owner_id: actor.id,
              git_identity: Marshall.Compute.GitIdentity.snapshot!(actor.id),
              current_placement_id: placement_id
            })
          )

        Marshall.Agents.Registration.register!(vm)

        Marshall.Ingress.Endpoints.ensure!(vm)

        Ledger.create!(WorkloadPlacement, :allocate, %{
          id: placement_id,
          vm_id: vm.id,
          host_id: host.id,
          pool_id: pool.id
        })

        vm = Ash.load!(vm, [:host_id, :pool_id], actor: SystemActor.compute())

        Ledger.create!(
          Reservation,
          :reserve,
          Map.merge(reservation, %{
            vm_id: vm.id,
            placement_id: placement_id,
            host_id: host.id,
            pool_id: pool.id
          })
        )

        Ledger.create!(NetworkAddress, :reserve, %{vm_id: vm.id, profile: vm.profile, slot: slot})

        if source = request[:workspace_source],
          do: Ledger.create!(WorkspaceSource, :record, Map.put(source, :vm_id, vm.id))

        Ledger.create!(Operation, :enqueue, %{
          placement_id: vm.current_placement_id,
          execution_epoch: vm.execution_epoch,
          vm_id: vm.id,
          requested_by_id: actor.id,
          generation: vm.generation,
          kind: :provision
        })

        vm
    end
  end

  # @cc [owner:ghuntley,label:security;protocol] admission-workspace-image-capability
  # Every new admission MUST require a current (version 4, 5 or 6) manifest bound to
  # its catalog ID. Native images MUST match the exact reviewed admission identity
  # or refuse with image_requirements_not_met before address/host allocation.
  # A source-bearing admission MUST additionally declare source protocol 2;
  # missing, obsolete, mismatched or absent source capabilities MUST refuse with
  # workspace_source_unavailable. An Inception admission MUST derive its capability
  # from that complete validated identity and refuse with image_requirements_not_met
  # when absent, because Inception depends on guest exchanges.
  @spec source_image_admissible!(map(), Image.t()) :: :ok
  defp source_image_admissible!(request, image) do
    sourced? = Map.get(request, :workspace_source) != nil

    case OverallsProtocol.ImageManifest.validate(image.manifest) do
      {:ok, %{id: id, workspace_source_version: capability} = validated} when id == image.id ->
        unless OverallsProtocol.NativeAdmission.admitted?(validated),
          do: Ledger.rollback(:image_requirements_not_met)

        if sourced? and capability != 2, do: Ledger.rollback(:workspace_source_unavailable)

        if request.profile == :inception and
             not OverallsProtocol.GuestAgents.capabilities(
               OverallsProtocol.ImageManifest.guest_agents(validated),
               validated
             ).inception,
           do: Ledger.rollback(:image_requirements_not_met)

        :ok

      _ ->
        Ledger.rollback(if(sourced?, do: :workspace_source_unavailable, else: :image_unavailable))
    end
  end

  # @cc [owner:ghuntley,label:concurrency] admission-name-lifetime
  # Global name claims MUST serialize before placement locks. Logical deletion
  # MUST retain a claim; only archival after physical cleanup releases it. The
  # database's partial unique index MUST remain the final uniqueness constraint.
  defp reserve_name!(name) do
    Ecto.Adapters.SQL.query!(
      Repo,
      "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
      ["vm-name:" <> name],
      log: false
    )

    Marshall.Compute.Cloning.reserve_name!(name)
  end

  # @cc [owner:ghuntley,label:security] admission-team-membership-fresh
  # Team provisioning authority MUST be re-evaluated through the Cedar engine
  # from persisted memberships at allocation time; a missing team denies.
  defp team_authorized!(nil, _actor), do: :ok

  defp team_authorized!(team_id, actor) do
    team =
      case Ledger.read!(Marshall.Teams.Team, id: team_id) do
        [team] -> team
        _ -> Ledger.rollback(:unknown_team)
      end

    Marshall.Teams.Fence.require_resources_open!(team)

    unless Marshall.Authorization.allowed?(
             actor,
             "team_manage_members",
             Marshall.Teams.Team.Cedar,
             team.id
           ),
           do: Ledger.rollback(:forbidden)

    :ok
  end
end
