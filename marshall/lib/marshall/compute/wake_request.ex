defmodule Marshall.Compute.WakeRequest do
  @moduledoc "Durable demand for one running execution; capacity waiting never grants execution."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Compute,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshStateMachine]

  postgres do
    table "compute_wake_requests"
    repo Marshall.Repo

    custom_indexes do
      index [:id, :vm_id], unique: true
    end

    identity_wheres_to_sql one_pending_wake: "finished_at IS NULL"

    check_constraints do
      check_constraint :status, "wake_terminal_receipt",
        check:
          "(finished_at IS NULL) = (status IN ('pending', 'waiting_capacity', 'relocating', 'resuming'))"
    end
  end

  cedar do
    internal [:read, :request, :advance]
  end

  # @cc [owner:ghuntley,label:recovery;concurrency] wake-single-demand
  # One unfinished demand MUST exist per VM. Pending capacity survives process
  # loss; only fresh running evidence or an explicit terminal refusal finishes it.
  # A client disconnect MUST NOT cancel the machine's durable wake.
  state_machine do
    state_attribute :status
    initial_states [:pending]
    default_initial_state :pending

    transitions do
      transition :advance,
        from: [:pending, :waiting_capacity, :relocating, :resuming],
        to: [:waiting_capacity, :relocating, :resuming, :ready, :failed, :cancelled]
    end
  end

  actions do
    defaults [:read]

    create :request do
      accept [
        :vm_id,
        :requested_by_id,
        :request_key,
        :source,
        :checkpoint_id,
        :requested_generation
      ]
    end

    update :advance do
      accept [:operation_id, :relocation_id, :checkpoint_id, :failure_reason, :finished_at]
      argument :status, :atom, allow_nil?: false
      change transition_state(arg(:status))
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :kind, :atom, allow_nil?: false, default: :resume, constraints: [one_of: [:resume]]
    attribute :request_key, :string, constraints: [min_length: 1, max_length: 128]

    attribute :source, :atom,
      allow_nil?: false,
      constraints: [one_of: [:user, :prompt, :network, :pin]]

    attribute :checkpoint_id, :uuid
    attribute :requested_generation, :integer, allow_nil?: false, constraints: [min: 1]

    attribute :failure_reason, :atom,
      constraints: [
        one_of: [:vm_deleted, :superseded, :execution_failed, :checkpoint_unavailable]
      ]

    attribute :status, :atom,
      allow_nil?: false,
      default: :pending,
      constraints: [
        one_of: [:pending, :waiting_capacity, :relocating, :resuming, :ready, :failed, :cancelled]
      ]

    attribute :finished_at, :utc_datetime_usec
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :vm, Marshall.Compute.VirtualMachine, allow_nil?: false
    belongs_to :requested_by, Marshall.Accounts.User
    belongs_to :operation, Marshall.Compute.Operation
    belongs_to :relocation, Marshall.Compute.Relocation
  end

  identities do
    identity :one_pending_wake, [:vm_id], where: expr(is_nil(finished_at))
    identity :request_identity, [:vm_id, :requested_by_id, :request_key]
  end
end
