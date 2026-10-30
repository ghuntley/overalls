# @cc [owner:ghuntley,label:recovery] physical-outcome-immutable-ledger
# Recorded observations MUST be immutable and preserve their outcome ID and unique
# placement sequence so repeated delivery can be distinguished from conflicting
# evidence. Operation, placement, VM, epoch, generation and host MUST agree.
defmodule Marshall.Compute.PhysicalOutcome do
  @moduledoc "Immutable physical observations; replay identity and sequence are checked under the host/VM locks."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Compute,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "compute_physical_outcomes"
    repo Marshall.Repo
    migration_defaults inserted_at: "fragment(\"(clock_timestamp() AT TIME ZONE 'utc')\")"

    references do
      reference :placement, match_with: [vm_id: :vm_id, host_id: :host_id]

      reference :operation,
        match_with: [
          vm_id: :vm_id,
          placement_id: :placement_id,
          execution_epoch: :execution_epoch,
          generation: :generation
        ]
    end
  end

  cedar do
    internal [:read, :record]
  end

  actions do
    defaults [:read]

    create :record do
      accept [
        :id,
        :host_id,
        :vm_id,
        :placement_id,
        :execution_epoch,
        :operation_id,
        :generation,
        :sequence,
        :observation
      ]
    end
  end

  attributes do
    attribute :id, :uuid, primary_key?: true, allow_nil?: false
    attribute :generation, :integer, allow_nil?: false, constraints: [min: 1]

    attribute :execution_epoch, :integer,
      allow_nil?: false,
      constraints: [min: 1, max: 9_223_372_036_854_775_807]

    attribute :sequence, :integer, allow_nil?: false, constraints: [min: 1]
    attribute :observation, :map, allow_nil?: false
    # @cc [owner:ghuntley,label:accounting] physical-outcome-database-receipt-clock
    # Received outcome timestamps MUST use the database clock shared with
    # measurement admissions and deadlines, not the reporting replica's clock.
    create_timestamp :inserted_at, default: &Marshall.Compute.Ledger.now/0
  end

  relationships do
    belongs_to :host, Marshall.Compute.Host, allow_nil?: false
    belongs_to :vm, Marshall.Compute.VirtualMachine, allow_nil?: false
    belongs_to :placement, Marshall.Compute.WorkloadPlacement, allow_nil?: false
    belongs_to :operation, Marshall.Compute.Operation, allow_nil?: false
  end

  identities do
    identity :one_per_sequence, [:placement_id, :sequence]
  end
end
