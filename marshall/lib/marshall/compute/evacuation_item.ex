defmodule Marshall.Compute.EvacuationItem do
  @moduledoc "Fixed evacuation workload and placement-bound stopped-copy approval."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Compute,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshPaperTrail.Resource, AshStateMachine]

  postgres do
    table "compute_evacuation_items"
    repo Marshall.Repo

    references do
      reference :placement, match_with: [vm_id: :vm_id]
      reference :relocation, match_with: [vm_id: :vm_id, evacuation_id: :evacuation_id]
    end

    check_constraints do
      check_constraint :approved_at, "evacuation_approval_complete",
        check:
          "(approved_at IS NULL AND approved_by_id IS NULL) OR (approved_at IS NOT NULL AND approved_by_id IS NOT NULL AND original_state = 'running')"

      check_constraint :execution_epoch, "evacuation_positive_epoch", check: "execution_epoch > 0"
    end
  end

  cedar do
    internal [:read, :record, :approve, :block, :schedule, :replan, :resolve]
  end

  paper_trail do
    metadata :actor_kind, :atom, allow_nil?: true
    metadata :actor_id, :uuid, allow_nil?: true
    sensitive_attributes :ignore
    change_tracking_mode :changes_only
    store_action_name? true
    ignore_attributes [:inserted_at, :updated_at, :attempted_at]
    version_extensions authorizers: [Marshall.Authorization.AshAuthorizer]
    mixin Marshall.Authorization.VersionMapping
  end

  state_machine do
    state_attribute :status
    initial_states [:pending]
    default_initial_state :pending

    transitions do
      transition :approve, from: [:pending, :approved, :blocked], to: :approved
      transition :block, from: [:pending, :approved, :blocked], to: :blocked
      transition :schedule, from: [:pending, :approved, :blocked], to: :scheduled
      transition :replan, from: [:pending, :approved, :blocked, :scheduled], to: :pending

      transition :resolve,
        from: [:pending, :approved, :blocked, :scheduled, :resolved],
        to: :resolved
    end
  end

  actions do
    defaults [:read]

    create :record do
      accept [:evacuation_id, :vm_id, :placement_id, :execution_epoch, :original_state]
    end

    update :approve do
      accept [:approved_by_id, :approved_at]
      change transition_state(:approved)
    end

    update :block do
      accept [:attempted_at, :blocker]
      change transition_state(:blocked)
    end

    update :schedule do
      accept [:attempted_at, :blocker, :relocation_id]
      change transition_state(:scheduled)
    end

    update :replan do
      accept [
        :placement_id,
        :execution_epoch,
        :original_state,
        :request_key,
        :replanned_by_id,
        :approved_at,
        :approved_by_id,
        :attempted_at,
        :blocker,
        :relocation_id,
        :resolved_at
      ]

      change transition_state(:pending)
    end

    update :resolve do
      accept [
        :placement_id,
        :execution_epoch,
        :original_state,
        :request_key,
        :replanned_by_id,
        :approved_at,
        :approved_by_id,
        :attempted_at,
        :blocker,
        :relocation_id,
        :resolved_at
      ]

      change transition_state(:resolved)
    end
  end

  changes do
    change Marshall.Compute.LifecycleAudit, on: [:create, :update, :destroy]
  end

  attributes do
    uuid_primary_key :id
    attribute :request_key, :uuid, allow_nil?: false, default: &Ash.UUID.generate/0
    attribute :resolved_at, :utc_datetime_usec
    attribute :execution_epoch, :integer, allow_nil?: false, constraints: [min: 1]

    attribute :original_state, :atom,
      allow_nil?: false,
      constraints: [one_of: [:running, :stopped]]

    attribute :approved_at, :utc_datetime_usec
    attribute :attempted_at, :utc_datetime_usec

    attribute :blocker, :atom,
      constraints: [
        one_of: [
          :workload_changed,
          :workload_not_stable,
          :source_unavailable,
          :transfer_busy,
          :insufficient_capacity,
          :downtime_approval_required,
          :resize_in_progress,
          :relocation_in_progress
        ]
      ]

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :evacuation, Marshall.Compute.Evacuation, allow_nil?: false
    belongs_to :vm, Marshall.Compute.VirtualMachine, allow_nil?: false
    belongs_to :placement, Marshall.Compute.WorkloadPlacement, allow_nil?: false
    belongs_to :approved_by, Marshall.Accounts.User
    belongs_to :replanned_by, Marshall.Accounts.User
    belongs_to :relocation, Marshall.Compute.Relocation
  end

  identities do
    identity :one_campaign_workload, [:evacuation_id, :vm_id]
  end
end
