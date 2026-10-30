defmodule Marshall.Compute.ServiceLevelAttempt do
  @moduledoc "Durable reliability admission and immutable terminal measurement; never execution authority."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Compute,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshStateMachine]

  postgres do
    table "compute_service_level_attempts"
    repo Marshall.Repo

    references do
      reference :operation, on_delete: :delete
    end

    # @cc [owner:ghuntley,label:accounting;performance] pending-service-level-access-paths
    # The pending scan and deadline indexes MUST exclude completed rows and match
    # checked_at/id ordering and deadline filtering, respectively.
    custom_indexes do
      index [:completed_at, :admitted_at, :id]
      index [:checked_at, :id], where: "status = 'pending'", name: "service_level_pending_scan"
      index [:deadline], where: "status = 'pending'", name: "service_level_pending_deadline"
    end

    check_constraints do
      check_constraint :deadline, "service_level_positive_deadline",
        check: "deadline > admitted_at"

      check_constraint :completed_at, "service_level_terminal_shape",
        check: """
        (status = 'pending' AND completed_at IS NULL AND success IS NULL AND duration_us IS NULL)
        OR (status = 'finished' AND completed_at IS NOT NULL AND success IS NOT NULL AND duration_us IS NOT NULL AND duration_us >= 0)
        """
    end
  end

  cedar do
    internal [:read, :admit, :finish, :check_pending]
  end

  # @cc [owner:ghuntley,label:accounting;recovery] service-level-terminal-immutable
  # One operation/service admission MUST have at most one terminal result.
  # Only pending attempts may finish; no action may reopen or delete a result.
  # Deadline failures MUST NOT cancel work or release execution capacity.
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
      accept [:service, :operation_id, :admitted_at, :deadline]
    end

    update :finish do
      accept [:completed_at, :success, :duration_us]
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
      constraints: [one_of: [:marshall_ready, :lilly_physical, :porsche_physical]]

    attribute :admitted_at, :utc_datetime_usec, allow_nil?: false
    create_timestamp :checked_at, writable?: true
    attribute :deadline, :utc_datetime_usec, allow_nil?: false
    attribute :completed_at, :utc_datetime_usec
    attribute :success, :boolean
    attribute :duration_us, :integer, constraints: [min: 0]
  end

  relationships do
    belongs_to :operation, Marshall.Compute.Operation, allow_nil?: false
  end

  identities do
    identity :one_operation_service, [:operation_id, :service]
  end
end
