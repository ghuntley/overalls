defmodule Marshall.Compute.CleanupRequest do
  @moduledoc "Irrevocable source retirement intent after destination readiness."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Compute,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshStateMachine]

  postgres do
    table "compute_cleanup_requests"
    repo Marshall.Repo

    references do
      reference :operation, match_with: [id: :relocation_id]
      reference :relocation, match_with: [source_host_id: :source_host_id]
    end

    check_constraints do
      check_constraint :key_retired_at, "key_retirement_was_offered",
        check:
          "(key_offered_at IS NULL OR key_requested_at IS NOT NULL) AND (key_retired_at IS NULL OR key_offered_at IS NOT NULL)"

      check_constraint :completed_at, "cleanup_completion_was_offered",
        check: "completed_at IS NULL OR offered_at IS NOT NULL"
    end
  end

  cedar do
    internal [
      :read,
      :record,
      :offer,
      :record_operation,
      :request_key_retirement,
      :offer_key_retirement,
      :retire_key,
      :complete
    ]
  end

  # @cc [owner:ghuntley,label:recovery;capacity] cleanup-one-source-obligation
  # One relocation MUST retain one immutable source descriptor/generation and
  # its physical deletion receipt. Request/offer/timeout alone release no holds.
  # Completion MUST survive retries and cannot authorize deletion of another copy.
  state_machine do
    state_attribute :phase
    initial_states [:pending]
    default_initial_state :pending

    transitions do
      transition :offer, from: [:pending, :offered], to: :offered
      transition :complete, from: [:offered], to: :complete
    end
  end

  actions do
    defaults [:read]

    create :record do
      accept [:id, :source_host_id, :descriptor, :generation]
    end

    update :offer do
      accept [:offered_at]
      change transition_state(:offered)
    end

    update :record_operation do
      accept [:operation_id]
    end

    update :request_key_retirement do
      accept [:key_requested_at]
    end

    update :offer_key_retirement do
      accept [:key_offered_at]
    end

    update :retire_key do
      accept [:key_retired_at]
    end

    update :complete do
      accept [:completed_at]
      change transition_state(:complete)
    end
  end

  changes do
    change Marshall.Compute.LifecycleAudit, on: [:create, :update, :destroy]
  end

  attributes do
    uuid_primary_key :id, writable?: true
    attribute :descriptor, Marshall.Compute.TransferDescriptor, allow_nil?: false

    attribute :generation, :integer,
      allow_nil?: false,
      constraints: [min: 1, max: 9_223_372_036_854_775_806]

    attribute :offered_at, :utc_datetime_usec
    attribute :completed_at, :utc_datetime_usec
    attribute :key_requested_at, :utc_datetime_usec
    attribute :key_offered_at, :utc_datetime_usec
    attribute :key_retired_at, :utc_datetime_usec
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :operation, Marshall.Compute.Operation

    belongs_to :relocation, Marshall.Compute.Relocation,
      source_attribute: :id,
      define_attribute?: false

    belongs_to :source_host, Marshall.Compute.Host, allow_nil?: false
  end
end
