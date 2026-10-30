defmodule Marshall.Compute.ResizeRequest do
  @moduledoc "Durable resize payload, phase and immutable lifecycle operation references."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Compute,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshStateMachine]

  postgres do
    table "compute_resize_requests"
    repo Marshall.Repo

    custom_indexes do
      index [:vm_id], unique: true, where: "finished_at IS NULL", name: "one_active_resize"
    end
  end

  cedar do
    internal [
      :read,
      :record,
      :record_progress,
      :stop,
      :resize,
      :restart,
      :fence,
      :complete,
      :cancel,
      :cancelled
    ]
  end

  # @cc [owner:ghuntley,label:recovery] workflow-named-transitions
  # Phase changes MUST use named transitions; progress writes cannot skip a
  # physical evidence boundary. Coordinators retain their receipt and lock guards.
  state_machine do
    state_attribute :phase
    initial_states [:stopping]
    default_initial_state :stopping

    transitions do
      transition :stop, from: [:stopping], to: :stopping
      transition :resize, from: [:stopping, :resizing], to: :resizing
      transition :restart, from: [:resizing, :restarting, :fencing, :cancelling], to: :restarting
      transition :fence, from: [:restarting, :fencing], to: :fencing
      transition :complete, from: [:resizing, :restarting], to: :complete
      # Cancellation is accepted only before any size has been applied: from
      # the stop phase into cancelling, then into cancelled directly or through
      # an ordinary restart (ADR-0166).
      transition :cancel, from: [:stopping, :cancelling], to: :cancelling
      transition :cancelled, from: [:cancelling, :restarting], to: :cancelled
    end
  end

  actions do
    defaults [:read]

    create :record do
      accept [
        :vm_id,
        :host_id,
        :requested_by_id,
        :request_key,
        :expected_generation,
        :original_sizes,
        :target_sizes,
        :original_power_state
      ]
    end

    update :record_progress do
      accept [:operation_id, :failure, :finished_at]
    end

    update :stop do
      accept [:operation_id, :failure, :finished_at]
      change transition_state(:stopping)
    end

    update :resize do
      accept [:operation_id, :failure, :finished_at]
      change transition_state(:resizing)
    end

    update :restart do
      accept [:operation_id, :failure, :finished_at]
      change transition_state(:restarting)
    end

    update :fence do
      accept [:operation_id, :failure, :finished_at]
      change transition_state(:fencing)
    end

    update :complete do
      accept [:operation_id, :failure, :finished_at]
      change transition_state(:complete)
    end

    update :cancel do
      accept [:operation_id, :failure, :finished_at, :cancelled_at]
      change transition_state(:cancelling)
    end

    update :cancelled do
      accept [:operation_id, :failure, :finished_at]
      change transition_state(:cancelled)
    end
  end

  changes do
    change Marshall.Compute.LifecycleAudit, on: [:create, :update, :destroy]
  end

  attributes do
    uuid_primary_key :id
    attribute :request_key, :string, allow_nil?: false
    attribute :expected_generation, :integer, allow_nil?: false
    attribute :original_sizes, :map, allow_nil?: false
    attribute :target_sizes, :map, allow_nil?: false

    attribute :original_power_state, :atom,
      allow_nil?: false,
      constraints: [one_of: [:running, :stopped]]

    attribute :phase, :atom,
      allow_nil?: false,
      default: :stopping,
      constraints: [
        one_of: [:stopping, :resizing, :restarting, :fencing, :complete, :cancelling, :cancelled]
      ]

    attribute :operation_id, :uuid
    attribute :failure, :string
    attribute :finished_at, :utc_datetime_usec
    attribute :cancelled_at, :utc_datetime_usec
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :vm, Marshall.Compute.VirtualMachine, allow_nil?: false
    belongs_to :host, Marshall.Compute.Host, allow_nil?: false
    belongs_to :requested_by, Marshall.Accounts.User, allow_nil?: false
  end

  identities do
    identity :resize_idempotency, [:vm_id, :requested_by_id, :request_key]
  end
end
