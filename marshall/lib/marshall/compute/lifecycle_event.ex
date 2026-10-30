defmodule Marshall.Compute.LifecycleEvent do
  @moduledoc "Append-only, redacted lifecycle history with ninety-day visibility."
  use Ash.Resource,
    otp_app: :marshall,
    primary_read_warning?: false,
    domain: Marshall.Compute,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    notifiers: [Marshall.Compute.LifecycleLog],
    extensions: [AshOban]

  postgres do
    table "compute_lifecycle_events"
    repo Marshall.Repo
    migration_defaults inserted_at: "fragment(\"(clock_timestamp() AT TIME ZONE 'utc')\")"

    custom_indexes do
      index [:expires_at, :id]
      index [:vm_id, :inserted_at, :id]
      index [:workflow_id, :inserted_at, :id]
      index [:host_id, :inserted_at, :id]
      index [:action, :inserted_at, :id]
      index [:inserted_at, :id]
    end
  end

  cedar do
    control_plane "admin_read", [:list_for_admin]
    internal [:read, :record, :expire]
  end

  oban do
    scheduled_actions do
      schedule :expire, "*/10 * * * *" do
        action :expire
        queue :maintenance
        worker_module_name Marshall.Compute.Workers.ExpireLifecycleEvents
        actor_persister :none
        default_actor %Marshall.Authorization.SystemActor{purpose: :compute}
      end
    end
  end

  actions do
    read :read do
      primary? true
      filter expr(expires_at > fragment("clock_timestamp()"))
    end

    create :record do
      accept [
        :event_id,
        :actor_kind,
        :actor_id,
        :resource_type,
        :resource_id,
        :action,
        :previous_state,
        :next_state,
        :vm_id,
        :placement_id,
        :host_id,
        :workflow_id,
        :operation_id,
        :execution_epoch,
        :generation,
        :sequence,
        :measurement_outcome,
        :occurred_at,
        :expires_at
      ]
    end

    action :expire, :integer do
      argument :continuation, :uuid
      run Marshall.Compute.ExpireLifecycleEvents
    end

    action :list_for_admin, :map do
      argument :vm_id, :uuid
      argument :workflow_id, :uuid
      argument :host_id, :uuid
      argument :action, :string, constraints: [max_length: 128]
      argument :since, :utc_datetime_usec
      argument :until, :utc_datetime_usec
      argument :before, :uuid
      argument :limit, :integer, allow_nil?: false, default: 100, constraints: [min: 1, max: 100]
      run Marshall.Compute.LifecycleHistory
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :event_id, :uuid, allow_nil?: false, default: &Ash.UUID.generate/0

    attribute :actor_kind, :atom,
      allow_nil?: false,
      constraints: [one_of: [:user, :system]]

    attribute :actor_id, :uuid
    attribute :resource_type, :string, allow_nil?: false, constraints: [max_length: 64]
    attribute :resource_id, :uuid, allow_nil?: false
    attribute :action, :string, allow_nil?: false, constraints: [max_length: 128]
    attribute :previous_state, :string, constraints: [max_length: 64]
    attribute :next_state, :string, constraints: [max_length: 64]
    attribute :vm_id, :uuid
    attribute :placement_id, :uuid
    attribute :host_id, :uuid
    attribute :workflow_id, :uuid
    attribute :operation_id, :uuid
    attribute :execution_epoch, :integer, constraints: [min: 1]
    attribute :generation, :integer, constraints: [min: 1]
    attribute :sequence, :integer, constraints: [min: 1]

    attribute :measurement_outcome, :atom,
      constraints: [one_of: [:succeeded, :failed, :cancelled, :superseded]]

    attribute :occurred_at, :utc_datetime_usec, allow_nil?: false
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false
    # @cc [owner:ghuntley,label:accounting] lifecycle-event-database-receipt-clock
    # Received audit timestamps MUST use the database clock shared with
    # reliability deadlines. Producer occurred_at remains separate evidence.
    create_timestamp :inserted_at, default: &Marshall.Compute.Ledger.now/0
  end

  identities do
    identity :event_identity, [:event_id]
  end
end
