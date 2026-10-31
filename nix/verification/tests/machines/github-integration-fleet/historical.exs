defmodule GitHubHistoricalFleet do
  @moduledoc "Disposable historical allocation setup; real provisioning supplies all physical facts."
  alias Marshall.Compute.{
    AddressAllocation,
    Budget,
    Host,
    HostLiveness,
    Image,
    Ledger,
    NetworkAddress,
    Operation,
    Reservation,
    StoragePool,
    VirtualMachine,
    WorkloadPlacement
  }

  # @cc [owner:ghuntley,label:verification;security;capacity] github-historical-windows-allocation
  # Only the explicit historical Windows composition and synthetic owner may
  # allocate the exact frozen image without a new Git-identity snapshot. Setup
  # MUST retain measured capacity, address/reservation ownership, agent roots and
  # the real provision operation. No disk, observed state, readiness, executor,
  # OAuth grant or maintenance outcome may be fabricated. This is historical
  # allocation simulation, never new-UI admission or retained-user-data evidence.
  @spec run(map()) :: map()
  def run(%{
        "owner_id" => owner,
        "host_id" => host_id,
        "pool_id" => pool_id,
        "image_id" => image_id,
        "key" => key
      }) do
    require!(System.fetch_env!("FLEET_GITHUB_HISTORICAL_WINDOWS") == "1", :historical_disabled)

    require!(
      Enum.all?([owner, host_id, pool_id, key, image_id], &is_binary/1) and
        Enum.all?([owner, host_id, pool_id, key], &OverallsProtocol.uuid?/1),
      :invalid_identifier
    )

    actor = Ash.get!(Marshall.Accounts.User, owner, authorize?: false)

    require!(
      String.ends_with?(to_string(actor.email), "@example.test") and
        actor.administrator == false,
      :owner_not_synthetic
    )

    frozen =
      case System.fetch_env!("FLEET_GUEST")
           |> Path.join("manifest.json")
           |> File.read!()
           |> JSON.decode!()
           |> OverallsProtocol.ImageManifest.validate() do
        {:ok, frozen} -> frozen
        _ -> refuse!(:manifest_invalid)
      end

    require!(frozen.id == image_id, :image_mismatch)
    require!(OverallsProtocol.NativeAdmission.admitted?(frozen), :image_not_admitted)
    require!(not Map.has_key?(frozen, :git_identity_version), :git_identity_present)

    require!(
      OverallsProtocol.ImageManifest.guest_agents(frozen) == :windows_v1,
      :guest_agents_mismatch
    )

    {:ok, result} =
      Ledger.transaction(fn ->
        image =
          case Ledger.read!(Image, id: image_id) do
            [image] -> image
            _ -> refuse!(:image_missing)
          end

        require!(image.manifest["guest_agents"] == "windows-v1", :guest_agents_mismatch)

        shape = %{
          architecture: :x86_64,
          profile: :oss,
          vcpu: 2,
          memory_bytes: image.minimum_memory_bytes,
          disk_bytes: image.minimum_disk_bytes
        }

        needed = OverallsProtocol.VMShape.reservation(shape)
        slot = AddressAllocation.next_slot!(:oss)
        host = Ledger.lock!(Host, host_id)
        pool = Ledger.lock!(StoragePool, pool_id)
        require!(pool.host_id == host_id, :pool_host_mismatch)
        require!(host.enabled and host.maintenance_mode == :normal, :host_unschedulable)
        require!(host.inventory["execution_ready"] == true, :host_not_execution_ready)
        require!(image_id in List.wrap(host.inventory["images"]), :image_not_inventoried)

        require!(
          HostLiveness.capacity_fresh?(host.reported_at, Ledger.now()) and
            HostLiveness.capacity_fresh?(pool.reported_at, Ledger.now()),
          :capacity_stale
        )

        available = Budget.available(host, pool, Ledger.read!(Reservation, host_id: host_id))
        # Name the refused dimension only; byte and core counts stay private.
        case Enum.find([:memory_bytes, :disk_bytes, :vcpu], fn dimension ->
               Map.fetch!(needed, dimension) > Map.fetch!(available, dimension)
             end) do
          :memory_bytes -> refuse!(:insufficient_memory)
          :disk_bytes -> refuse!(:insufficient_disk)
          :vcpu -> refuse!(:insufficient_vcpu)
          nil -> require!(Budget.fits?(available, needed), :insufficient_capacity)
        end

        placement_id = Ash.UUID.generate()

        vm =
          Ledger.create!(
            VirtualMachine,
            :allocate,
            Map.merge(shape, %{
              id: Ash.UUID.generate(),
              name: "github-historical-" <> binary_part(owner, 0, 8),
              owner_id: owner,
              image_id: image_id,
              idempotency_key: key,
              current_placement_id: placement_id,
              git_identity: nil
            })
          )

        Marshall.Agents.Registration.register!(vm)
        Marshall.Ingress.Endpoints.ensure!(vm)

        Ledger.create!(WorkloadPlacement, :allocate, %{
          id: placement_id,
          vm_id: vm.id,
          host_id: host_id,
          pool_id: pool_id
        })

        Ledger.create!(
          Reservation,
          :reserve,
          Map.merge(
            needed,
            %{vm_id: vm.id, placement_id: placement_id, host_id: host_id, pool_id: pool_id}
          )
        )

        Ledger.create!(NetworkAddress, :reserve, %{vm_id: vm.id, profile: :oss, slot: slot})

        Ledger.create!(Operation, :enqueue, %{
          placement_id: placement_id,
          execution_epoch: vm.execution_epoch,
          vm_id: vm.id,
          requested_by_id: actor.id,
          generation: vm.generation,
          kind: :provision
        })

        %{vm_id: vm.id, placement_id: placement_id, historical_setup: true}
      end)

    result
  end

  @spec require!(boolean(), FleetOperatorRefusal.reason()) :: :ok
  defp require!(condition, reason), do: FleetOperatorRefusal.require!(condition, reason)

  @spec refuse!(FleetOperatorRefusal.reason()) :: no_return()
  defp refuse!(reason), do: FleetOperatorRefusal.refuse!(reason)
end
