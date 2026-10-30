defmodule Marshall.Compute.CloneRequest do
  @moduledoc "Durable per-source clone queue and independently reconciled physical obligations."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Compute,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshOban, AshPaperTrail.Resource, AshStateMachine]

  postgres do
    table "compute_clone_requests"
    repo Marshall.Repo

    identity_wheres_to_sql active_source: "active = true",
                           reserved_name: "name_released_at IS NULL"

    check_constraints do
      check_constraint :active, "clone_active_not_finished",
        check: "NOT active OR finished_at IS NULL"
    end
  end

  cedar do
    internal [
      :read,
      :enqueue,
      :record_progress,
      :defer,
      :prepare,
      :stop_source,
      :capture,
      :confirm_capture,
      :confirm_copy,
      :publish,
      :complete,
      :complete_cleanup,
      :request_cancel,
      :cancel,
      :fail,
      :retry,
      :schedule,
      :reconcile
    ]
  end

  oban do
    triggers do
      trigger :reconcile do
        action :reconcile
        queue :provisioning
        scheduler_cron "* * * * *"
        where expr(is_nil(finished_at) or is_nil(cleanup_completed_at))
        worker_module_name Marshall.Compute.Workers.Clone
        scheduler_module_name Marshall.Compute.Workers.ScheduleClone
        lock_for_update? false
        actor_persister :none
        default_actor %Marshall.Authorization.SystemActor{purpose: :compute}
      end
    end
  end

  paper_trail do
    metadata :actor_kind, :atom, allow_nil?: true
    metadata :actor_id, :uuid, allow_nil?: true
    sensitive_attributes :ignore
    change_tracking_mode :changes_only
    store_action_name? true

    ignore_attributes [
      :inserted_at,
      :updated_at,
      :specification,
      :snapshot,
      :request_key,
      :failure,
      :deferred_reason,
      :deferred_at
    ]

    version_extensions authorizers: [Marshall.Authorization.AshAuthorizer]
    mixin Marshall.Authorization.VersionMapping
  end

  # @cc [owner:ghuntley,label:recovery] workflow-named-transitions
  # Phase changes MUST use named transitions; progress writes cannot skip a
  # physical evidence boundary. Coordinators retain their receipt and lock guards.
  state_machine do
    state_attribute :phase
    initial_states [:queued]
    default_initial_state :queued

    transitions do
      transition :prepare, from: [:queued], to: :preparing
      transition :stop_source, from: [:preparing], to: :stopping
      transition :capture, from: [:preparing, :stopping], to: :capturing
      transition :confirm_capture, from: [:capturing], to: :copying
      transition :confirm_copy, from: [:copying], to: :publishing
      transition :publish, from: [:publishing], to: :cleaning
      transition :complete, from: [:cleaning], to: :complete

      transition :request_cancel,
        from: [:preparing, :stopping, :capturing, :copying, :publishing],
        to: :cancelling

      transition :cancel, from: [:queued, :failed, :cancelling], to: :cancelled
      transition :fail, from: [:queued, :cleaning], to: :failed
      transition :retry, from: [:failed], to: :queued
    end
  end

  actions do
    defaults [:read]

    create :enqueue do
      accept [
        :source_vm_id,
        :requested_by_id,
        :request_key,
        :destination_vm_id,
        :name,
        :requested_name,
        :sequence
      ]

      change run_oban_trigger(:reconcile)
    end

    update :record_progress do
      accept [:failure, :source_operation_id, :source_restored_at]
    end

    # A queued head refused by a transient host condition waits in the queue
    # instead of failing; activation clears the deferral.
    update :defer do
      accept [:deferred_reason, :deferred_at]
    end

    update :prepare do
      accept [
        :active,
        :source_host_id,
        :destination_host_id,
        :original_power_state,
        :specification,
        :deferred_reason,
        :deferred_at
      ]

      change transition_state(:preparing)
    end

    update :stop_source do
      accept [:source_operation_id]
      change transition_state(:stopping)
    end

    update :capture do
      accept []
      change transition_state(:capturing)
    end

    update :confirm_capture do
      accept [:snapshot]
      change transition_state(:copying)
    end

    update :confirm_copy do
      accept []
      change transition_state(:publishing)
    end

    update :publish do
      accept [:published_at, :destination_operation_id, :cleanup_deadline_at]
      change transition_state(:cleaning)
    end

    update :complete do
      accept [:active, :finished_at, :failure, :name_released_at, :cleanup_completed_at]
      change transition_state(:complete)
    end

    # The source snapshot prune may confirm after the request completed at its
    # cleanup deadline; this closes the retained obligation.
    update :complete_cleanup do
      accept [:cleanup_completed_at]
    end

    update :request_cancel do
      accept [:cancel_requested_at]
      change transition_state(:cancelling)
    end

    update :cancel do
      accept [:active, :finished_at, :failure, :name_released_at, :cleanup_completed_at]
      change transition_state(:cancelled)
    end

    update :fail do
      accept [:active, :finished_at, :failure, :name_released_at, :cleanup_completed_at]
      change transition_state(:failed)
    end

    update :retry do
      accept [:finished_at, :failure, :sequence]
      change transition_state(:queued)
    end

    update :schedule do
      accept []
      change run_oban_trigger(:reconcile)
    end

    update :reconcile do
      accept []
      require_atomic? false
      transaction? false
      change Marshall.Compute.CloneDispatch
    end
  end

  changes do
    change Marshall.Compute.LifecycleAudit, on: [:create, :update, :destroy]
  end

  attributes do
    uuid_primary_key :id
    attribute :destination_vm_id, :uuid, allow_nil?: false

    attribute :request_key, :string,
      allow_nil?: false,
      constraints: [min_length: 1, max_length: 128]

    attribute :name, :string, allow_nil?: false
    attribute :requested_name, :string
    attribute :sequence, :integer, allow_nil?: false, constraints: [min: 1]
    attribute :active, :boolean, allow_nil?: false, default: false

    attribute :phase, :atom,
      allow_nil?: false,
      default: :queued,
      constraints: [
        one_of: [
          :queued,
          :preparing,
          :stopping,
          :capturing,
          :copying,
          :publishing,
          :cleaning,
          :complete,
          :cancelling,
          :cancelled,
          :failed
        ]
      ]

    attribute :source_host_id, :uuid
    attribute :destination_host_id, :uuid
    attribute :original_power_state, :atom, constraints: [one_of: [:running, :stopped]]
    attribute :specification, :map, allow_nil?: false, default: %{}
    attribute :snapshot, :map
    attribute :source_operation_id, :uuid
    attribute :destination_operation_id, :uuid
    attribute :source_restored_at, :utc_datetime_usec
    attribute :published_at, :utc_datetime_usec
    attribute :cancel_requested_at, :utc_datetime_usec
    attribute :failure, :string
    attribute :finished_at, :utc_datetime_usec
    attribute :name_released_at, :utc_datetime_usec
    attribute :cleanup_deadline_at, :utc_datetime_usec
    attribute :cleanup_completed_at, :utc_datetime_usec
    attribute :deferred_reason, :string, constraints: [max_length: 64]
    attribute :deferred_at, :utc_datetime_usec
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :source_vm, Marshall.Compute.VirtualMachine, allow_nil?: false
    belongs_to :requested_by, Marshall.Accounts.User, allow_nil?: false
  end

  identities do
    identity :request_identity, [:requested_by_id, :request_key]
    identity :destination_identity, [:destination_vm_id]
    identity :queue_sequence, [:source_vm_id, :sequence]
    identity :active_source, [:source_vm_id], where: expr(active == true)
    identity :reserved_name, [:name], where: expr(is_nil(name_released_at))
  end
end
