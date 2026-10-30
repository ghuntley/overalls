defmodule Marshall.Compute.ProbeRequest do
  @moduledoc "Immutable host-bound probe requests and retained acknowledgements."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Compute,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshStateMachine, AshOban]

  postgres do
    table "compute_probe_requests"
    repo Marshall.Repo

    custom_indexes do
      index [:host_id, :applied_at]
      index [:id, :relocation_id], unique: true
    end
  end

  cedar do
    internal [:read, :enqueue, :dispatch, :record_result]
  end

  # @cc [owner:ghuntley,label:recovery;security] probe-outbox-retains-role-and-lease
  # Each relocation/revision/phase MUST have one immutable host-bound request.
  # Expired requests and receipts MUST remain for delayed-result correlation.
  # Receipt time MUST be recorded once by the authenticated exchange; a source
  # grant acknowledgement MUST NOT establish destination connectivity or stop.
  state_machine do
    state_attribute :status
    initial_states [:pending]
    default_initial_state :pending

    transitions do
      transition :record_result, from: [:pending], to: :applied
    end
  end

  oban do
    triggers do
      trigger :notify do
        action :dispatch
        queue :provisioning
        scheduler_cron "* * * * *"
        where expr(is_nil(applied_at) and expires_at > now())
        worker_module_name Marshall.Compute.Workers.NotifyProbe
        scheduler_module_name Marshall.Compute.Workers.ScheduleProbe
        lock_for_update? false
        actor_persister :none
        default_actor %Marshall.Authorization.SystemActor{purpose: :compute}
      end
    end
  end

  actions do
    defaults [:read]

    create :enqueue do
      accept [
        :id,
        :relocation_id,
        :host_id,
        :revision,
        :phase,
        :request,
        :expires_at,
        :inserted_at
      ]

      change run_oban_trigger(:notify)
    end

    update :dispatch do
      accept []
      require_atomic? false
      transaction? false
      change Marshall.Compute.ProbeDispatch
    end

    update :record_result do
      accept [:applied_at]
      change transition_state(:applied)
    end
  end

  changes do
    change Marshall.Compute.LifecycleAudit, on: [:create, :update, :destroy]
  end

  attributes do
    uuid_primary_key :id, writable?: true

    attribute :revision, :integer,
      allow_nil?: false,
      constraints: [min: 1, max: 9_223_372_036_854_775_807]

    attribute :phase, :atom, allow_nil?: false, constraints: [one_of: [:grant, :probe]]
    attribute :request, Marshall.Compute.ProbeRequestPayload, allow_nil?: false
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false
    attribute :applied_at, :utc_datetime_usec
    create_timestamp :inserted_at, writable?: true
  end

  relationships do
    belongs_to :relocation, Marshall.Compute.Relocation, allow_nil?: false
    belongs_to :host, Marshall.Compute.Host, allow_nil?: false
  end

  identities do
    identity :one_probe_phase_revision, [:relocation_id, :revision, :phase]
  end
end
