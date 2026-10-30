defmodule Marshall.Compute.HostDrain do
  @moduledoc "Audited maintenance intent. Physical outcomes, not this request, release capacity."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Compute,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshOban, AshPaperTrail.Resource, AshStateMachine]

  postgres do
    table "compute_host_drains"
    repo Marshall.Repo
    identity_wheres_to_sql one_open_drain: "closed_at IS NULL"
  end

  cedar do
    internal [:read, :request, :advance, :confirm, :resume, :retire]
  end

  oban do
    triggers do
      trigger :advance do
        action :advance
        queue :maintenance
        where expr(status == :draining)
        scheduler_cron "* * * * *"
        lock_for_update? false
        actor_persister :none
        default_actor %Marshall.Authorization.SystemActor{purpose: :compute}
        worker_module_name Marshall.Compute.Workers.AdvanceDrain
        scheduler_module_name Marshall.Compute.Workers.ScheduleDrains
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

  state_machine do
    state_attribute :status
    initial_states [:draining]
    default_initial_state :draining

    transitions do
      transition :confirm, from: :draining, to: :drained
      transition :resume, from: :drained, to: :resumed
      transition :retire, from: :drained, to: :retired
    end
  end

  actions do
    defaults [:read]

    create :request do
      accept [:id, :host_id, :operator_reference]
      change run_oban_trigger(:advance)
    end

    action :advance, :integer do
      argument :primary_key, :map, allow_nil?: false
      argument :continuation, :uuid
      run Marshall.Compute.AdvanceDrain
    end

    update :confirm do
      accept [:quiesced_at]
      change transition_state(:drained)
    end

    update :resume do
      accept [:closed_at]
      change transition_state(:resumed)
    end

    update :retire do
      accept [:closed_at]
      change transition_state(:retired)
    end
  end

  changes do
    change Marshall.Compute.LifecycleAudit, on: [:create, :update, :destroy]
  end

  attributes do
    uuid_primary_key :id, writable?: true

    attribute :operator_reference, :string,
      allow_nil?: false,
      constraints: [min_length: 1, max_length: 128]

    attribute :status, :atom,
      allow_nil?: false,
      default: :draining,
      constraints: [one_of: [:draining, :drained, :resumed, :retired]]

    attribute :quiesced_at, :utc_datetime_usec
    attribute :closed_at, :utc_datetime_usec
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :host, Marshall.Compute.Host, allow_nil?: false
  end

  identities do
    identity :one_open_drain, [:host_id], where: expr(is_nil(closed_at))
  end
end
