# @cc [owner:ghuntley,label:concurrency;recovery] transfer-slot-retained-ownership
# A host MUST have at most one occupied transfer slot, shared by sending and
# receiving. Each slot must reference the corresponding relocation endpoint or clone request. A local clone occupies one slot.
# Expiry, job exhaustion, and lost contact MUST NOT release it: release requires
# confirmed stream termination. Slots retain history after release.
defmodule Marshall.Compute.TransferSlot do
  @moduledoc "Durable per-host transfer occupancy, separate from capacity and execution authority."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Compute,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "compute_transfer_slots"
    repo Marshall.Repo
    identity_wheres_to_sql one_occupied_transfer: "released_at IS NULL"

    references do
      reference :source_relocation, match_with: [host_id: :source_host_id]
      reference :destination_relocation, match_with: [host_id: :destination_host_id]
    end

    check_constraints do
      check_constraint :source_relocation_id, "transfer_slot_one_endpoint",
        check:
          "num_nonnulls(source_relocation_id, destination_relocation_id, clone_request_id) = 1"
    end
  end

  cedar do
    internal [:read, :release, :occupy]
  end

  actions do
    defaults [:read]

    update :release do
      accept [:released_at]
    end

    create :occupy do
      accept [:host_id, :source_relocation_id, :destination_relocation_id, :clone_request_id]
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :released_at, :utc_datetime_usec
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :clone_request, Marshall.Compute.CloneRequest
    belongs_to :host, Marshall.Compute.Host, allow_nil?: false
    belongs_to :source_relocation, Marshall.Compute.Relocation
    belongs_to :destination_relocation, Marshall.Compute.Relocation
  end

  identities do
    identity :one_occupied_transfer, [:host_id], where: expr(is_nil(released_at))
    identity :one_source_slot, [:source_relocation_id]
    identity :one_destination_slot, [:destination_relocation_id]
  end
end
