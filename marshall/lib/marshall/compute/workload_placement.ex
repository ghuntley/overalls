# @cc [owner:ghuntley,label:recovery] placement-permanent-copy-identity
# Each physical workload copy MUST have a distinct immutable placement ID bound
# to its VM, host and pool. Returning to a former host MUST create another ID;
# deletion MUST retain the old record. A placement record alone grants no launch
# authority: the VM's current placement and execution epoch authorize execution.
defmodule Marshall.Compute.WorkloadPlacement do
  @moduledoc "Permanent identity of a host-local workload copy, independent of VM identity."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Compute,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "compute_workload_placements"
    repo Marshall.Repo

    references do
      reference :pool, match_with: [host_id: :host_id]
    end

    custom_indexes do
      index [:id, :vm_id], unique: true
      index [:id, :vm_id, :host_id], unique: true
      index [:id, :vm_id, :host_id, :pool_id], unique: true
      index [:vm_id]
      index [:host_id, :pool_id]
    end
  end

  cedar do
    internal [:read, :allocate]
  end

  actions do
    defaults [:read]

    create :allocate do
      accept [:id, :vm_id, :host_id, :pool_id]
    end
  end

  attributes do
    uuid_primary_key :id, writable?: true
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :vm, Marshall.Compute.VirtualMachine, allow_nil?: false
    belongs_to :host, Marshall.Compute.Host, allow_nil?: false
    belongs_to :pool, Marshall.Compute.StoragePool, allow_nil?: false
  end
end
