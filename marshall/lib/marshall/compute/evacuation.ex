defmodule Marshall.Compute.Evacuation do
  @moduledoc "Durable administrator-authorized evacuation, distinct from stop-in-place drain."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Compute,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshStateMachine, AshOban, AshPaperTrail.Resource]

  postgres do
    table "compute_evacuations"
    repo Marshall.Repo
    identity_wheres_to_sql one_open_evacuation: "closed_at IS NULL"

    custom_indexes do
      index [:id, :host_id], unique: true
    end
  end

  cedar do
    control_plane "admin_operate", [
      :request_for_admin,
      :control_for_admin,
      :approve_for_admin,
      :replan_for_admin
    ]

    control_plane "admin_read", [
      :nodes_for_admin,
      :capacity_for_admin,
      :inspect_for_admin,
      :timeline_for_admin
    ]

    internal [:read, :record, :pause, :continue, :confirm_ready, :resume, :retire, :advance]
  end

  state_machine do
    state_attribute :status
    initial_states [:active]
    default_initial_state :active

    transitions do
      transition :pause, from: [:active, :paused], to: :paused
      transition :continue, from: [:active, :paused], to: :active
      transition :confirm_ready, from: [:active], to: :ready
      transition :resume, from: [:ready], to: :resumed
      transition :retire, from: [:ready], to: :retired
    end
  end

  oban do
    triggers do
      trigger :advance do
        action :advance
        queue :maintenance
        where expr(status == :active and is_nil(closed_at))
        scheduler_cron "* * * * *"
        lock_for_update? false
        actor_persister :none
        default_actor %Marshall.Authorization.SystemActor{purpose: :compute}
        worker_module_name Marshall.Compute.Workers.AdvanceEvacuation
        scheduler_module_name Marshall.Compute.Workers.ScheduleEvacuations
      end
    end
  end

  paper_trail do
    metadata :actor_kind, :atom, allow_nil?: true
    metadata :actor_id, :uuid, allow_nil?: true
    sensitive_attributes :ignore
    change_tracking_mode :changes_only
    store_action_name? true
    ignore_attributes [:inserted_at, :updated_at]
    version_extensions authorizers: [Marshall.Authorization.AshAuthorizer]
    mixin Marshall.Authorization.VersionMapping
  end

  actions do
    defaults [:read]

    action :nodes_for_admin, :map do
      argument :after, :uuid
      run Marshall.Compute.EvacuationViews
    end

    action :capacity_for_admin, :map do
      argument :host_id, :uuid, allow_nil?: false
      argument :after, :uuid
      run Marshall.Compute.EvacuationViews
    end

    action :inspect_for_admin, :map do
      argument :host_id, :uuid, allow_nil?: false
      argument :after, :uuid
      argument :preview, :boolean, allow_nil?: false, default: false
      run Marshall.Compute.EvacuationViews
    end

    action :timeline_for_admin, :map do
      argument :host_id, :uuid, allow_nil?: false
      run Marshall.Compute.EvacuationViews
    end

    create :record do
      accept [:id, :host_id, :requested_by_id]
      change run_oban_trigger(:advance)
    end

    update :pause do
      accept [:closed_at, :ready_at, :controlled_by_id]
      change transition_state(:paused)
    end

    update :continue do
      accept [:closed_at, :ready_at, :controlled_by_id]
      change transition_state(:active)
    end

    update :confirm_ready do
      accept [:closed_at, :ready_at, :controlled_by_id]
      change transition_state(:ready)
    end

    update :resume do
      accept [:closed_at, :ready_at, :controlled_by_id]
      change transition_state(:resumed)
    end

    update :retire do
      accept [:closed_at, :ready_at, :controlled_by_id]
      change transition_state(:retired)
    end

    action :advance, :atom do
      argument :primary_key, :map, allow_nil?: false
      run Marshall.Compute.AdvanceEvacuation
    end

    action :request_for_admin, :map do
      argument :host_id, :uuid, allow_nil?: false
      argument :request_id, :uuid, allow_nil?: false
      run Marshall.Compute.EvacuationActions
    end

    action :control_for_admin, :map do
      argument :id, :uuid, allow_nil?: false

      argument :command, :atom,
        allow_nil?: false,
        constraints: [one_of: [:pause, :continue, :resume, :retire]]

      run Marshall.Compute.EvacuationActions
    end

    action :approve_for_admin, :map do
      argument :id, :uuid, allow_nil?: false
      argument :item_id, :uuid, allow_nil?: false
      argument :expected_key, :uuid, allow_nil?: false
      run Marshall.Compute.EvacuationActions
    end

    action :replan_for_admin, :map do
      argument :id, :uuid, allow_nil?: false
      argument :item_id, :uuid, allow_nil?: false
      argument :expected_key, :uuid, allow_nil?: false
      run Marshall.Compute.EvacuationActions
    end
  end

  changes do
    change Marshall.Compute.LifecycleAudit, on: [:create, :update, :destroy]
  end

  attributes do
    uuid_primary_key :id, writable?: true

    attribute :status, :atom,
      allow_nil?: false,
      default: :active,
      constraints: [one_of: [:active, :paused, :ready, :resumed, :retired]]

    attribute :ready_at, :utc_datetime_usec
    attribute :closed_at, :utc_datetime_usec
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :host, Marshall.Compute.Host, allow_nil?: false
    belongs_to :requested_by, Marshall.Accounts.User, allow_nil?: false
    belongs_to :controlled_by, Marshall.Accounts.User
  end

  identities do
    identity :one_open_evacuation, [:host_id], where: expr(is_nil(closed_at))
  end
end
