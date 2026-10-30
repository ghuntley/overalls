# @cc [owner:ghuntley,label:concurrency] operation-enqueue-includes-job
# Creating an operation through enqueue MUST create its dispatch job in the same
# transaction; one placement/epoch/generation MUST NOT acquire multiple operation
# records. The target placement and execution epoch MUST remain immutable even
# after the VM moves to another placement.

# @cc [owner:ghuntley,label:product] operation-initiator-provenance
# User and agent-wake operations MUST identify their requester; recovery starts MUST have no
# fabricated user/drain, and maintenance stops MUST identify their drain with no
# fabricated requester. Relocation stop/start operations MUST reference their relocation and no
# fabricated requester/drain. These combinations MUST remain DB-constrained.
defmodule Marshall.Compute.Operation do
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Compute,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshOban, AshStateMachine]

  postgres do
    table "compute_operations"
    repo Marshall.Repo

    references do
      reference :placement, match_with: [vm_id: :vm_id]
      reference :completion_outcome, deferrable: :initially
      reference :relocation, match_with: [vm_id: :vm_id]
    end

    custom_indexes do
      index [:id, :relocation_id], unique: true
      index [:id, :relocation_id, :generation], unique: true

      index [:id, :vm_id, :placement_id, :execution_epoch, :generation],
        unique: true,
        name: "compute_operation_authority_index"
    end

    check_constraints do
      check_constraint :initiator, "valid_operation_initiator",
        check: """
        (initiator = 'clone' AND clone_request_id IS NOT NULL AND requested_by_id IS NULL AND host_drain_id IS NULL AND relocation_id IS NULL AND kind IN ('stop', 'start'))
        OR (initiator = 'user' AND requested_by_id IS NOT NULL AND host_drain_id IS NULL AND relocation_id IS NULL)
        OR (initiator = 'agent' AND requested_by_id IS NOT NULL AND host_drain_id IS NULL AND relocation_id IS NULL AND kind IN ('start', 'resume'))
        OR (initiator = 'recovery' AND requested_by_id IS NULL AND host_drain_id IS NULL AND relocation_id IS NULL AND kind IN ('start', 'resume'))
        OR (initiator = 'maintenance' AND requested_by_id IS NULL AND host_drain_id IS NOT NULL AND relocation_id IS NULL AND kind = 'stop')
        OR (initiator = 'relocation' AND requested_by_id IS NULL AND host_drain_id IS NULL AND relocation_id IS NOT NULL AND kind IN ('stop', 'start', 'delete', 'pause', 'resume'))
        OR (initiator IN ('idle', 'wake') AND requested_by_id IS NULL AND host_drain_id IS NULL AND relocation_id IS NULL AND kind IN ('pause', 'resume', 'start'))
        """
    end
  end

  cedar do
    internal [:read, :enqueue, :dispatch, :acknowledge, :complete, :cancel]
  end

  oban do
    triggers do
      trigger :dispatch do
        action :dispatch
        queue :provisioning
        scheduler_cron "* * * * *"
        where expr(status == :pending)
        worker_module_name Marshall.Compute.Workers.Dispatch
        scheduler_module_name Marshall.Compute.Workers.ScheduleDispatch
        lock_for_update? false
        actor_persister :none
        default_actor %Marshall.Authorization.SystemActor{purpose: :compute}
      end
    end
  end

  # @cc [owner:ghuntley,label:recovery] operation-status-evidence
  # Only named transitions may change delivery status. Completion records physical
  # evidence, including a late result for a cancelled command; cancellation alone
  # MUST NOT establish physical absence or release capacity.
  state_machine do
    state_attribute :status
    initial_states [:pending]
    default_initial_state :pending

    transitions do
      transition :acknowledge, from: :pending, to: :acknowledged
      transition :complete, from: [:pending, :acknowledged, :cancelled], to: :completed
      transition :cancel, from: [:pending, :acknowledged], to: :cancelled
    end
  end

  actions do
    defaults [:read]

    create :enqueue do
      accept [
        :id,
        :vm_id,
        :placement_id,
        :execution_epoch,
        :requested_by_id,
        :generation,
        :kind,
        :request_key,
        :initiator,
        :host_drain_id,
        :relocation_id,
        :resize_request_id,
        :clone_request_id,
        :command_snapshot
      ]

      change Marshall.Compute.CommandSnapshot
      change Marshall.Compute.ServiceLevelAdmission
      change run_oban_trigger(:dispatch)
    end

    update :dispatch do
      accept []
      require_atomic? false
      transaction? false
      change Marshall.Compute.Dispatch
    end

    update :acknowledge do
      accept []
      change transition_state(:acknowledged)
    end

    update :complete do
      accept [:completion_outcome_id]
      change transition_state(:completed)
    end

    update :cancel do
      accept []
      change transition_state(:cancelled)
    end
  end

  changes do
    change Marshall.Compute.LifecycleAudit, on: [:create, :update, :destroy]
  end

  attributes do
    uuid_primary_key :id, writable?: true
    attribute :command_snapshot, :map, allow_nil?: false
    attribute :request_key, :string, constraints: [min_length: 1, max_length: 128]
    attribute :generation, :integer, allow_nil?: false, constraints: [min: 1]

    attribute :execution_epoch, :integer,
      allow_nil?: false,
      constraints: [min: 1, max: 9_223_372_036_854_775_807]

    attribute :initiator, :atom,
      allow_nil?: false,
      default: :user,
      constraints: [
        one_of: [:user, :agent, :recovery, :maintenance, :relocation, :clone, :idle, :wake]
      ]

    attribute :kind, :atom,
      allow_nil?: false,
      constraints: [one_of: [:provision, :start, :stop, :delete, :resize, :pause, :resume]]

    attribute :status, :atom,
      allow_nil?: false,
      default: :pending,
      constraints: [one_of: [:pending, :acknowledged, :completed, :cancelled]]

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :clone_request, Marshall.Compute.CloneRequest
    belongs_to :resize_request, Marshall.Compute.ResizeRequest
    belongs_to :completion_outcome, Marshall.Compute.PhysicalOutcome
    belongs_to :vm, Marshall.Compute.VirtualMachine, allow_nil?: false
    belongs_to :placement, Marshall.Compute.WorkloadPlacement, allow_nil?: false
    belongs_to :requested_by, Marshall.Accounts.User
    belongs_to :host_drain, Marshall.Compute.HostDrain
    belongs_to :relocation, Marshall.Compute.Relocation
  end

  identities do
    identity :one_per_generation, [:placement_id, :execution_epoch, :generation]
    identity :idempotent_lifecycle, [:vm_id, :requested_by_id, :request_key]
    identity :one_stop_per_drain, [:vm_id, :host_drain_id]
  end
end
