defmodule Marshall.Compute.WorkflowServiceLevelAttempt do
  @moduledoc "Receipt-bound workflow measurements; retained evidence only, never workflow authority."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Compute,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshStateMachine]

  postgres do
    table "compute_workflow_service_level_attempts"
    repo Marshall.Repo

    custom_indexes do
      index [:checked_at, :id], where: "status = 'pending'", name: "workflow_slo_pending_scan"
      index [:deadline], where: "status = 'pending'", name: "workflow_slo_pending_deadline"
    end

    check_constraints do
      check_constraint :deadline, "workflow_slo_positive_deadline",
        check: "deadline > admitted_at"

      check_constraint :completed_at, "workflow_slo_terminal_shape",
        check: """
        (status = 'pending' AND completed_at IS NULL AND success IS NULL AND duration_us IS NULL AND excluded_outcome IS NULL)
        OR (status = 'finished' AND completed_at IS NOT NULL AND success IS NOT NULL AND duration_us IS NOT NULL AND duration_us >= 0 AND excluded_outcome IS NULL)
        OR (status = 'finished' AND completed_at IS NOT NULL AND success IS NULL AND duration_us IS NOT NULL AND duration_us >= 0 AND excluded_outcome IS NOT NULL AND excluded_outcome IN ('cancelled', 'superseded'))
        """

      check_constraint :sequence, "workflow_slo_binding_shape",
        check: """
        (workflow_type = 'clone' AND sequence IS NOT NULL AND sequence > 0)
        OR (workflow_type IN ('relocation', 'relocation_retry') AND sequence IS NULL)
        """
    end
  end

  cedar do
    internal [:read, :admit, :finish, :check_pending]
  end

  # @cc [owner:ghuntley,label:accounting;recovery] workflow-slo-immutable-receipt
  # One canonical SSH receipt MUST admit at most one immutable measurement.
  # Only pending measurements may finish. Measurement deadlines MUST NOT
  # cancel work, change reservations, refresh receipts or reset workflow state.
  state_machine do
    state_attribute :status
    initial_states [:pending]
    default_initial_state :pending

    transitions do
      transition :finish, from: :pending, to: :finished
    end
  end

  actions do
    defaults [:read]

    create :admit do
      accept [
        :request_id,
        :service,
        :workflow_type,
        :workflow_id,
        :sequence,
        :expected_outcome,
        :admitted_at,
        :deadline
      ]
    end

    update :finish do
      accept [:completed_at, :success, :duration_us, :excluded_outcome]
      require_atomic? false
      change transition_state(:finished)
    end

    update :check_pending do
      accept [:checked_at]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :status, :atom,
      allow_nil?: false,
      default: :pending,
      constraints: [one_of: [:pending, :finished]]

    attribute :service, :atom,
      allow_nil?: false,
      constraints: [one_of: [:porsche_clone, :porsche_relocate, :porsche_retry, :porsche_cancel]]

    attribute :workflow_type, :atom,
      allow_nil?: false,
      constraints: [one_of: [:clone, :relocation, :relocation_retry]]

    attribute :workflow_id, :uuid, allow_nil?: false
    attribute :sequence, :integer, constraints: [min: 1]

    attribute :expected_outcome, :atom,
      allow_nil?: false,
      constraints: [one_of: [:succeeded, :cancelled]]

    attribute :admitted_at, :utc_datetime_usec, allow_nil?: false
    create_timestamp :checked_at, writable?: true
    attribute :deadline, :utc_datetime_usec, allow_nil?: false
    attribute :completed_at, :utc_datetime_usec
    attribute :success, :boolean
    attribute :excluded_outcome, :atom, constraints: [one_of: [:cancelled, :superseded]]
    attribute :duration_us, :integer, constraints: [min: 0]
  end

  relationships do
    belongs_to :request, Marshall.SSH.Request, allow_nil?: false
  end

  identities do
    identity :one_receipt, [:request_id]
  end
end
