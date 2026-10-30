defmodule Marshall.Compute.SourcePermitRequest do
  @moduledoc "Immutable source lease requests and retained native descriptor replies."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Compute,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshOban, AshStateMachine]

  postgres do
    table "compute_source_permit_requests"
    repo Marshall.Repo

    references do
      reference :relocation, match_with: [source_host_id: :source_host_id]
    end

    check_constraints do
      check_constraint :import_requested_at, "final_import_has_receipt",
        check:
          "(import_requested_at IS NULL AND destination_imported_at IS NULL) OR (import_requested_at IS NOT NULL AND destination_dataset_guid IS NOT NULL)"
    end

    custom_indexes do
      index [:id, :relocation_id], unique: true
      index [:source_host_id, :status]
    end
  end

  cedar do
    internal [
      :read,
      :enqueue,
      :dispatch,
      :record_result,
      :prepare_import,
      :record_import,
      :record_receive,
      :dispatch_destination,
      :supersede
    ]
  end

  oban do
    triggers do
      trigger :notify_destination do
        action :dispatch_destination
        queue :provisioning
        scheduler_cron "* * * * *"
        where expr(not is_nil(descriptor) and is_nil(destination_dataset_guid))
        worker_module_name Marshall.Compute.Workers.NotifyDestinationReceive
        scheduler_module_name Marshall.Compute.Workers.ScheduleDestinationReceive
        lock_for_update? false
        actor_persister :none
        default_actor %Marshall.Authorization.SystemActor{purpose: :compute}
      end

      trigger :notify_source do
        action :dispatch
        queue :provisioning
        scheduler_cron "* * * * *"
        where expr(status == :pending)
        worker_module_name Marshall.Compute.Workers.NotifySourcePermit
        scheduler_module_name Marshall.Compute.Workers.ScheduleSourcePermit
        lock_for_update? false
        actor_persister :none
        default_actor %Marshall.Authorization.SystemActor{purpose: :compute}
      end
    end
  end

  # @cc [owner:ghuntley,label:recovery;concurrency] source-permit-request-history
  # Each relocation revision MUST have one immutable source-host-bound request
  # and an atomically queued notification. Superseded requests and their results
  # MUST remain available for delayed-reply correlation. Dispatch or expiry MUST
  # NOT establish source stop, transfer completion or released reservations.
  # Source descriptor publication MUST enqueue a destination notification in the
  # same transaction. A destination GUID records staging receipt only; the
  # authenticated exchange MUST keep it consistent across all relocation revisions.
  state_machine do
    state_attribute :status
    initial_states [:pending]
    default_initial_state :pending

    transitions do
      transition :record_result, from: :pending, to: :applied
      transition :supersede, from: [:pending, :applied], to: :superseded
    end
  end

  actions do
    defaults [:read]

    create :enqueue do
      accept [:id, :relocation_id, :source_host_id, :revision, :request]
      change run_oban_trigger(:notify_source)
    end

    update :dispatch do
      accept []
      require_atomic? false
      transaction? false
      change Marshall.Compute.SourcePermitDispatch
    end

    update :record_result do
      accept [:descriptor]
      change transition_state(:applied)
      change run_oban_trigger(:notify_destination)
    end

    update :prepare_import do
      accept [:import_requested_at]
    end

    update :record_import do
      accept [:destination_imported_at]
    end

    update :record_receive do
      accept [:destination_dataset_guid]
    end

    update :dispatch_destination do
      accept []
      require_atomic? false
      transaction? false
      change Marshall.Compute.DestinationReceiveDispatch
    end

    update :supersede do
      accept []
      change transition_state(:superseded)
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

    attribute :request, Marshall.Compute.SourceRequestPayload, allow_nil?: false
    attribute :descriptor, Marshall.Compute.TransferDescriptor
    attribute :destination_dataset_guid, Marshall.Compute.NativeGuid
    attribute :import_requested_at, :utc_datetime_usec
    attribute :destination_imported_at, :utc_datetime_usec

    attribute :status, :atom,
      allow_nil?: false,
      default: :pending,
      constraints: [one_of: [:pending, :applied, :superseded]]

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :relocation, Marshall.Compute.Relocation, allow_nil?: false
    belongs_to :source_host, Marshall.Compute.Host, allow_nil?: false
  end

  identities do
    identity :one_source_revision, [:relocation_id, :revision]
  end
end
