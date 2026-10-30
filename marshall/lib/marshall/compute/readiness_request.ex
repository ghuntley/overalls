defmodule Marshall.Compute.ReadinessRequest do
  @moduledoc "One durable guest-readiness deadline and result per relocation activation."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Compute,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshStateMachine]

  # @cc [owner:ghuntley,label:recovery;security] readiness-deadline-once-per-activation
  # An activation MUST retain one immutable descriptor/deadline and at most one
  # completed readiness result. Expired or failed requests cannot become ready.
  # Boot readiness is distinct from VMM running, placement commit and cleanup.
  postgres do
    table "compute_readiness_requests"
    repo Marshall.Repo

    references do
      reference :operation, match_with: [relocation_id: :relocation_id, generation: :generation]
      reference :relocation, match_with: [vm_id: :vm_id]
    end

    check_constraints do
      check_constraint :status, "readiness_result_complete",
        check: """
        (status = 'pending' AND completed_at IS NULL AND boot_id IS NULL AND failure_reason IS NULL)
        OR (status = 'ready' AND completed_at IS NOT NULL AND failure_reason IS NULL AND ((requires_boot AND boot_id IS NOT NULL) OR (NOT requires_boot AND boot_id IS NULL)))
        OR (status = 'failed' AND completed_at IS NOT NULL AND boot_id IS NULL AND failure_reason IS NOT NULL)
        """
    end
  end

  cedar do
    internal [:read, :record, :offer, :ready, :fail]
  end

  state_machine do
    state_attribute :status
    initial_states [:pending]
    default_initial_state :pending

    transitions do
      transition :ready, from: :pending, to: :ready
      transition :fail, from: :pending, to: :failed
    end
  end

  actions do
    defaults [:read]

    create :record do
      accept [:id, :relocation_id, :vm_id, :generation, :descriptor, :deadline_at, :requires_boot]
    end

    update :offer do
      accept [:offered_at]
    end

    update :ready do
      accept [:boot_id, :completed_at]
      change transition_state(:ready)
    end

    update :fail do
      accept [:failure_reason, :completed_at]
      change transition_state(:failed)
    end
  end

  changes do
    change Marshall.Compute.LifecycleAudit, on: [:create, :update, :destroy]
  end

  attributes do
    uuid_primary_key :id, writable?: true

    attribute :generation, :integer,
      allow_nil?: false,
      constraints: [min: 1, max: 9_223_372_036_854_775_807]

    attribute :descriptor, Marshall.Compute.TransferDescriptor, allow_nil?: false
    attribute :requires_boot, :boolean, allow_nil?: false
    attribute :deadline_at, :utc_datetime_usec, allow_nil?: false
    attribute :offered_at, :utc_datetime_usec
    attribute :completed_at, :utc_datetime_usec
    attribute :boot_id, :uuid

    attribute :status, :atom,
      allow_nil?: false,
      default: :pending,
      constraints: [one_of: [:pending, :ready, :failed]]

    attribute :failure_reason, :atom, constraints: [one_of: [:timeout, :activation_changed]]
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :operation, Marshall.Compute.Operation,
      source_attribute: :id,
      define_attribute?: false

    belongs_to :relocation, Marshall.Compute.Relocation, allow_nil?: false
    belongs_to :vm, Marshall.Compute.VirtualMachine, allow_nil?: false
  end
end
