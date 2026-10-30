# @cc [owner:ghuntley,label:capacity] reservation-independent-held-resources
# Each placement MUST retain one reservation whose compute_held and disk_held are
# independent. Releasing compute MUST leave disk accounting intact; only confirmed
# deletion may release both, and reacquiring compute MUST preserve reserved disk.

# @cc [owner:ghuntley,label:capacity;recovery] reservation-temporary-physical-hold
# Temporary snapshot commitments MUST use this placement's reservation, not a
# second ledger. Coordinators MUST hold host locks through capacity admission
# and increases, and MUST NOT release temporary bytes until the owned temporary
# storage is confirmed absent. Worker failure or timeout is not reclamation.
defmodule Marshall.Compute.Reservation do
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Compute,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "compute_reservations"
    repo Marshall.Repo

    custom_indexes do
      # Catalog headroom reads every reservation for the eligible hosts at once.
      index [:host_id], name: "compute_reservations_host_index"
    end

    references do
      reference :placement, match_with: [vm_id: :vm_id, host_id: :host_id, pool_id: :pool_id]
    end

    check_constraints do
      check_constraint :temporary_disk_bytes, "reservation_temporary_disk_nonnegative",
        check: "temporary_disk_bytes >= 0"
    end
  end

  cedar do
    internal [
      :read,
      :reserve,
      :hold_checkpoint,
      :release_checkpoint,
      :hold_temporary_disk,
      :release_temporary_disk,
      :resize_hold,
      :hold_compute,
      :settle_usage,
      :release_compute,
      :release_all
    ]
  end

  actions do
    defaults [:read]

    create :reserve do
      accept [
        :host_id,
        :pool_id,
        :vm_id,
        :placement_id,
        :vcpu,
        :memory_bytes,
        :disk_bytes,
        :compute_held,
        :temporary_disk_bytes,
        :checkpoint_bytes
      ]
    end

    update :hold_checkpoint do
      accept [:checkpoint_bytes]
    end

    update :release_checkpoint do
      accept []
      change set_attribute(:checkpoint_bytes, 0)
    end

    update :hold_temporary_disk do
      accept [:temporary_disk_bytes]
    end

    update :release_temporary_disk do
      accept []
      change set_attribute(:temporary_disk_bytes, 0)
    end

    update :resize_hold do
      accept [
        :vcpu,
        :memory_bytes,
        :disk_bytes,
        :pending_disk_bytes,
        :compute_held,
        :startup_compute_held
      ]
    end

    update :hold_compute do
      accept [:memory_bytes]
      change set_attribute(:compute_held, true)
      change set_attribute(:startup_compute_held, true)
    end

    update :settle_usage do
      accept [:startup_compute_held, :startup_disk_held]
    end

    update :release_compute do
      accept []
      change set_attribute(:compute_held, false)
      change set_attribute(:startup_compute_held, false)
    end

    update :release_all do
      accept []
      change set_attribute(:compute_held, false)
      change set_attribute(:disk_held, false)
      change set_attribute(:checkpoint_bytes, 0)
      change set_attribute(:startup_compute_held, false)
      change set_attribute(:startup_disk_held, false)
      change set_attribute(:temporary_disk_bytes, 0)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :pending_disk_bytes, :integer, allow_nil?: false, default: 0, constraints: [min: 0]
    attribute :vcpu, :integer, allow_nil?: false, constraints: [min: 1]
    attribute :memory_bytes, :integer, allow_nil?: false, constraints: [min: 1]
    attribute :disk_bytes, :integer, allow_nil?: false, constraints: [min: 1]

    attribute :temporary_disk_bytes, :integer,
      allow_nil?: false,
      default: 0,
      constraints: [min: 0, max: 9_223_372_036_854_775_807]

    attribute :checkpoint_bytes, :integer, allow_nil?: false, default: 0, constraints: [min: 0]
    attribute :compute_held, :boolean, allow_nil?: false, default: true
    attribute :disk_held, :boolean, allow_nil?: false, default: true
    # @cc [owner:ghuntley,label:capacity] startup-holds-are-not-ownership
    # Fresh matching physical coverage MAY clear startup holds without releasing
    # compute/disk ownership. Every new compute acquisition MUST restore its hold.
    attribute :startup_compute_held, :boolean, allow_nil?: false, default: true
    attribute :startup_disk_held, :boolean, allow_nil?: false, default: true
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :placement, Marshall.Compute.WorkloadPlacement, allow_nil?: false
    belongs_to :host, Marshall.Compute.Host, allow_nil?: false
    belongs_to :pool, Marshall.Compute.StoragePool, allow_nil?: false
    belongs_to :vm, Marshall.Compute.VirtualMachine, allow_nil?: false
  end

  identities do
    identity :one_per_placement, [:placement_id]
  end
end
