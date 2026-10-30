# @cc [owner:ghuntley,label:recovery] relocation-durable-copy-pair
# A relocation MUST retain immutable source/destination placements and execution
# epochs, initiator and original desired state. Endpoints must belong to its VM
# on distinct hosts, and the destination epoch must be exactly the source epoch
# plus one. Only one unfinished relocation may exist per VM; completed history
# and the request key MUST survive retries and later moves.
# The enrolled source endpoint, when present, MUST remain fixed for that move.

# @cc [owner:ghuntley,label:recovery] relocation-key-request-durable
# Recording a relocation MUST enqueue its key-preparation notification in the
# same transaction. Public-key receipt MUST NOT advance execution or free any
# capacity. Missing enrolled endpoint identity MUST remain unavailable for key
# preparation; polling must survive lost jobs and hints.

# @cc [owner:ghuntley,label:recovery;concurrency] relocation-cancellation-commit-exclusive
# Cancellation intent and committed destination authority MUST be mutually
# exclusive in PostgreSQL. Cancellation MUST retain its initiating user and
# timestamp and enqueue reconciliation; it MUST NOT mark cleanup finished.
defmodule Marshall.Compute.Relocation do
  @moduledoc "Durable relocation identity; recording a transfer grants no execution authority."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Compute,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshOban, AshStateMachine]

  postgres do
    table "compute_relocations"
    repo Marshall.Repo
    identity_wheres_to_sql one_unfinished_relocation: "finished_at IS NULL"

    references do
      reference :evacuation, match_with: [source_host_id: :host_id]

      reference :cancellation_stop_operation,
        match_with: [
          vm_id: :vm_id,
          source_placement_id: :placement_id,
          destination_epoch: :execution_epoch,
          cancellation_stop_generation: :generation
        ]

      reference :cancellation_start_operation,
        match_with: [
          vm_id: :vm_id,
          source_placement_id: :placement_id,
          destination_epoch: :execution_epoch,
          cancellation_start_generation: :generation
        ]

      reference :source_placement, match_with: [vm_id: :vm_id, source_host_id: :host_id]

      reference :destination_placement,
        match_with: [vm_id: :vm_id, destination_host_id: :host_id]

      reference :import_request, match_with: [id: :relocation_id]
      reference :source_preflight_request, match_with: [id: :relocation_id]

      reference :activation_operation,
        match_with: [
          vm_id: :vm_id,
          destination_placement_id: :placement_id,
          destination_epoch: :execution_epoch,
          activation_generation: :generation
        ]

      reference :source_stop_operation,
        match_with: [
          vm_id: :vm_id,
          source_placement_id: :placement_id,
          source_epoch: :execution_epoch,
          source_stop_generation: :generation
        ]
    end

    custom_indexes do
      index [:id, :vm_id, :evacuation_id], unique: true
      index [:id, :source_host_id], unique: true
      index [:id, :vm_id], unique: true
      index [:id, :destination_host_id], unique: true
      index [:source_host_id], where: "finished_at IS NULL"
      index [:destination_host_id], where: "finished_at IS NULL"
    end

    check_constraints do
      check_constraint :wake_request_id, "relocation_initiator_provenance",
        check:
          "(requested_by_id IS NOT NULL) <> (wake_request_id IS NOT NULL) AND (wake_request_id IS NULL OR preserves_memory)"

      check_constraint :deletion_requested_at, "relocation_deletion_reference_complete",
        check:
          "(deletion_requested_at IS NULL AND deletion_operation_id IS NULL) OR (deletion_requested_at IS NOT NULL AND deletion_operation_id IS NOT NULL)"

      check_constraint :cancellation_stop_generation, "relocation_cancellation_stop_complete",
        check:
          "(cancellation_stop_operation_id IS NULL AND cancellation_stop_generation IS NULL) OR (cancellation_stop_operation_id IS NOT NULL AND cancellation_stop_generation IS NOT NULL AND cancellation_stop_generation > 0 AND source_revoked_at IS NOT NULL)"

      check_constraint :cancellation_start_generation, "relocation_cancellation_start_complete",
        check:
          "(cancellation_start_operation_id IS NULL AND cancellation_start_generation IS NULL) OR (cancellation_start_operation_id IS NOT NULL AND cancellation_start_generation IS NOT NULL AND cancellation_stop_generation IS NOT NULL AND cancellation_start_generation > cancellation_stop_generation AND cancellation_stop_operation_id IS NOT NULL AND original_state = 'running')"

      check_constraint :source_restored_at, "relocation_source_restored_after_operation",
        check:
          "source_restored_at IS NULL OR (cancellation_stop_operation_id IS NOT NULL AND (original_state IN ('stopped', 'paused') OR wake_request_id IS NOT NULL OR cancellation_start_operation_id IS NOT NULL))"

      check_constraint :source_snapshots_cleaned_at, "relocation_source_snapshot_cleanup_offered",
        check:
          "(source_snapshot_cleanup_offered_at IS NULL OR source_restored_at IS NOT NULL OR deletion_requested_at IS NOT NULL) AND (source_snapshots_cleaned_at IS NULL OR source_snapshot_cleanup_offered_at IS NOT NULL)"

      check_constraint :source_revoked_at, "relocation_source_revocation_offered",
        check:
          "(source_revocation_offered_at IS NULL OR cancellation_requested_at IS NOT NULL OR committed_at IS NOT NULL) AND (source_revoked_at IS NULL OR source_revocation_offered_at IS NOT NULL)"

      check_constraint :destination_revoked_at, "relocation_destination_revocation_offered",
        check:
          "(destination_revocation_offered_at IS NULL OR cancellation_requested_at IS NOT NULL OR committed_at IS NOT NULL) AND (destination_revoked_at IS NULL OR destination_revocation_offered_at IS NOT NULL)"

      check_constraint :destination_cleaned_at, "relocation_destination_cleanup_offered",
        check:
          "(destination_cleanup_offered_at IS NULL OR cancellation_requested_at IS NOT NULL) AND (destination_cleaned_at IS NULL OR destination_cleanup_offered_at IS NOT NULL)"

      check_constraint :cancellation_requested_at, "relocation_cancellation_before_commit",
        check:
          "(cancellation_requested_at IS NULL AND cancellation_requested_by_id IS NULL) OR (cancellation_requested_at IS NOT NULL AND cancellation_requested_by_id IS NOT NULL AND committed_at IS NULL)"

      check_constraint :committed_at, "relocation_commit_reference_complete",
        check:
          "(committed_at IS NULL AND import_request_id IS NULL AND activation_operation_id IS NULL AND activation_generation IS NULL) OR (committed_at IS NOT NULL AND import_request_id IS NOT NULL AND activation_operation_id IS NOT NULL AND activation_generation IS NOT NULL AND activation_generation > 0)"

      # Every relocation must prove destination connectivity before a running
      # source is paused (ADR-0199). Validated for all rows once the exported
      # pre-copy history was purged (ADR-0159, migration 20261011200000).
      check_constraint :source_preflight_request_id, "relocation_stop_requires_probe",
        check:
          "(source_preflight_request_id IS NULL OR source_stop_operation_id IS NOT NULL) AND (original_state <> 'running' OR source_stop_operation_id IS NULL OR source_preflight_request_id IS NOT NULL)"

      check_constraint :source_stop_generation, "relocation_stop_reference_complete",
        check:
          "(source_stop_operation_id IS NULL AND source_stop_generation IS NULL) OR (source_stop_operation_id IS NOT NULL AND source_stop_generation IS NOT NULL AND source_stop_generation > 0)"

      check_constraint :source_host_id, "relocation_distinct_hosts",
        check: "source_host_id <> destination_host_id"

      check_constraint :destination_epoch, "relocation_successor_epoch",
        check:
          "source_epoch > 0 AND destination_epoch > source_epoch AND destination_epoch - source_epoch = 1"

      check_constraint :original_state, "relocation_original_state",
        check: "original_state IN ('running', 'stopped', 'paused')"
    end
  end

  cedar do
    internal [
      :read,
      :begin_copy,
      :begin_import,
      :confirm_import,
      :confirm_readiness,
      :fail_readiness,
      :observe_activation,
      :fail_activation,
      :record,
      :dispatch_key,
      :record_key,
      :schedule,
      :advance,
      :record_cancellation_stop,
      :record_cancellation_start,
      :record_source_restored,
      :offer_source_snapshot_cleanup,
      :record_source_snapshot_cleanup,
      :offer_source_revocation,
      :offer_destination_cleanup,
      :record_destination_cleanup,
      :offer_destination_revocation,
      :record_destination_revocation,
      :record_source_revocation,
      :request_cancellation,
      :request_deletion,
      :complete,
      :finish_cancellation,
      :finish_deletion,
      :record_commit,
      :record_stop
    ]
  end

  oban do
    triggers do
      trigger :coordinate do
        action :advance
        queue :provisioning
        scheduler_cron "* * * * *"

        where expr(is_nil(finished_at))

        worker_module_name Marshall.Compute.Workers.CoordinateRelocation
        scheduler_module_name Marshall.Compute.Workers.ScheduleRelocation
        lock_for_update? false
        actor_persister :none
        default_actor %Marshall.Authorization.SystemActor{purpose: :compute}
      end

      trigger :prepare_key do
        action :dispatch_key
        queue :provisioning
        scheduler_cron "* * * * *"

        where expr(
                is_nil(destination_public_key) and is_nil(finished_at) and
                  is_nil(cancellation_requested_at)
              )

        worker_module_name Marshall.Compute.Workers.PrepareRelocationKey
        scheduler_module_name Marshall.Compute.Workers.ScheduleRelocationKey
        lock_for_update? false
        actor_persister :none
        default_actor %Marshall.Authorization.SystemActor{purpose: :compute}
      end
    end
  end

  # @cc [owner:ghuntley,label:recovery;concurrency] relocation-stopped-copy-flow
  # Relocation MUST use one quiescent full copy (ADR-0199): key preparation, then a
  # running source is paused only after fresh destination connectivity proof
  # (checking_transfer -> stopping_source); one coherent full stream of disk/RAM
  # (copying), destination adoption (importing), the fenced handoff commit, and
  # destination readiness before any source cleanup. Cancellation MUST be
  # possible only before the handoff commit and restores the source; terminal
  # phases have no outgoing transitions. No phase copies a running source.
  state_machine do
    state_attribute :phase
    initial_states [:preparing]
    default_initial_state :preparing

    transitions do
      transition :observe_activation, from: :activation_failed, to: :checking_destination
      transition :record_key, from: :restoring_source, to: :restoring_source
      transition :record_key, from: :cancelled_cleanup, to: :cancelled_cleanup
      transition :record_key, from: :deleting_copies, to: :deleting_copies
      transition :record_key, from: [:preparing], to: [:checking_transfer]
      transition :record_stop, from: [:checking_transfer], to: [:stopping_source]

      transition :begin_copy,
        from: [:checking_transfer, :stopping_source, :copying],
        to: [:copying]

      transition :begin_import, from: [:copying], to: [:importing]
      transition :confirm_import, from: [:importing], to: [:handoff]
      transition :record_commit, from: [:handoff], to: [:checking_destination]
      transition :confirm_readiness, from: [:checking_destination], to: [:source_cleanup]
      transition :fail_readiness, from: [:checking_destination], to: [:readiness_failed]
      transition :fail_activation, from: [:checking_destination], to: [:activation_failed]

      transition :request_cancellation,
        from: [
          :preparing,
          :checking_transfer,
          :stopping_source,
          :copying,
          :importing,
          :handoff
        ],
        to: [:restoring_source]

      transition :record_source_restored, from: [:restoring_source], to: [:cancelled_cleanup]

      transition :request_deletion,
        from: [
          :preparing,
          :checking_transfer,
          :stopping_source,
          :copying,
          :importing,
          :handoff,
          :checking_destination,
          :readiness_failed,
          :activation_failed,
          :source_cleanup,
          :restoring_source,
          :cancelled_cleanup
        ],
        to: [:deleting_copies]

      transition :complete, from: [:source_cleanup], to: [:complete]
      transition :finish_cancellation, from: [:cancelled_cleanup], to: [:cancelled]
      transition :finish_deletion, from: [:deleting_copies], to: [:deleted]
    end
  end

  actions do
    update :begin_copy do
      accept []
      change transition_state(:copying)
    end

    update :begin_import do
      accept []
      change transition_state(:importing)
    end

    update :confirm_import do
      accept []
      change transition_state(:handoff)
    end

    update :confirm_readiness do
      accept []
      change transition_state(:source_cleanup)
    end

    update :fail_readiness do
      accept []
      change transition_state(:readiness_failed)
    end

    update :observe_activation do
      accept []
      change transition_state(:checking_destination)
    end

    update :fail_activation do
      accept []
      change transition_state(:activation_failed)
    end

    defaults [:read]

    create :record do
      accept [
        :id,
        :vm_id,
        :source_placement_id,
        :destination_placement_id,
        :source_host_id,
        :destination_host_id,
        :source_epoch,
        :destination_epoch,
        :original_state,
        :preserves_memory,
        :wake_request_id,
        :source_endpoint,
        :requested_by_id,
        :request_key,
        :evacuation_id
      ]

      change run_oban_trigger(:prepare_key)
      change run_oban_trigger(:coordinate)
    end

    update :dispatch_key do
      accept []
      require_atomic? false
      transaction? false
      change Marshall.Compute.RelocationKeyDispatch
    end

    update :record_key do
      accept [:destination_public_key]
      require_atomic? false

      # Key receipt leaves cancellation/deletion phases unchanged; before them it
      # only admits connectivity checking. It never stops or copies anything.
      change fn changeset, _ ->
        target =
          if changeset.data.phase == :preparing,
            do: :checking_transfer,
            else: changeset.data.phase

        AshStateMachine.transition_state(changeset, target)
      end
    end

    update :schedule do
      accept []
      change run_oban_trigger(:coordinate)
    end

    update :advance do
      accept []
      transaction? false
      require_atomic? false
      change Marshall.Compute.RelocationAdvance
    end

    update :record_cancellation_stop do
      accept [
        :cancellation_stop_operation_id,
        :cancellation_stop_generation,
        :cancellation_start_operation_id,
        :cancellation_start_generation
      ]
    end

    update :record_cancellation_start do
      accept [:cancellation_start_operation_id, :cancellation_start_generation]
    end

    update :record_source_restored do
      accept [:source_restored_at]
      change transition_state(:cancelled_cleanup)
    end

    update :offer_source_snapshot_cleanup do
      accept [:source_snapshot_cleanup_offered_at]
    end

    update :record_source_snapshot_cleanup do
      accept [:source_snapshots_cleaned_at]
      change run_oban_trigger(:coordinate)
    end

    update :offer_source_revocation do
      accept [:source_revocation_offered_at]
    end

    update :offer_destination_cleanup do
      accept [:destination_cleanup_offered_at]
    end

    update :record_destination_cleanup do
      accept [:destination_cleaned_at]
      change run_oban_trigger(:coordinate)
    end

    update :offer_destination_revocation do
      accept [:destination_revocation_offered_at]
    end

    update :record_destination_revocation do
      accept [:destination_revoked_at]
      change run_oban_trigger(:coordinate)
    end

    update :record_source_revocation do
      accept [:source_revoked_at]
      change run_oban_trigger(:coordinate)
    end

    update :request_cancellation do
      accept [:cancellation_requested_at, :cancellation_requested_by_id]
      change run_oban_trigger(:coordinate)
      change transition_state(:restoring_source)
    end

    update :request_deletion do
      accept [:deletion_requested_at, :deletion_operation_id]
      change run_oban_trigger(:coordinate)
      change transition_state(:deleting_copies)
    end

    update :complete do
      accept [:finished_at]
      change transition_state(:complete)
    end

    update :finish_cancellation do
      accept [:finished_at]
      change transition_state(:cancelled)
    end

    update :finish_deletion do
      accept [:finished_at]
      change transition_state(:deleted)
    end

    update :record_commit do
      accept [
        :committed_at,
        :import_request_id,
        :activation_operation_id,
        :activation_generation
      ]

      change transition_state(:checking_destination)
    end

    update :record_stop do
      accept [:source_stop_operation_id, :source_stop_generation, :source_preflight_request_id]
      change transition_state(:stopping_source)
    end
  end

  changes do
    change Marshall.Compute.LifecycleAudit, on: [:create, :update, :destroy]
  end

  attributes do
    attribute :deletion_requested_at, :utc_datetime_usec
    attribute :committed_at, :utc_datetime_usec
    attribute :cancellation_requested_at, :utc_datetime_usec
    attribute :source_revocation_offered_at, :utc_datetime_usec
    attribute :source_revoked_at, :utc_datetime_usec
    attribute :destination_cleanup_offered_at, :utc_datetime_usec
    attribute :destination_cleaned_at, :utc_datetime_usec

    attribute :destination_revocation_offered_at, :utc_datetime_usec
    attribute :destination_revoked_at, :utc_datetime_usec
    attribute :source_restored_at, :utc_datetime_usec
    attribute :source_snapshot_cleanup_offered_at, :utc_datetime_usec
    attribute :source_snapshots_cleaned_at, :utc_datetime_usec

    attribute :cancellation_stop_generation, :integer,
      constraints: [min: 1, max: 9_223_372_036_854_775_807]

    attribute :cancellation_start_generation, :integer,
      constraints: [min: 1, max: 9_223_372_036_854_775_807]

    attribute :activation_generation, :integer,
      constraints: [min: 1, max: 9_223_372_036_854_775_807]

    uuid_primary_key :id, writable?: true

    attribute :source_epoch, :integer,
      allow_nil?: false,
      constraints: [min: 1, max: 9_223_372_036_854_775_806]

    attribute :destination_epoch, :integer,
      allow_nil?: false,
      constraints: [min: 2, max: 9_223_372_036_854_775_807]

    attribute :preserves_memory, :boolean, allow_nil?: false, default: false

    attribute :original_state, :atom,
      allow_nil?: false,
      constraints: [one_of: [:running, :stopped, :paused]]

    attribute :request_key, :string,
      allow_nil?: false,
      constraints: [min_length: 1, max_length: 128]

    attribute :finished_at, :utc_datetime_usec
    attribute :source_endpoint, Marshall.Compute.TransferEndpoint
    attribute :destination_public_key, Marshall.Compute.TransferPublicKey

    attribute :source_stop_generation, :integer,
      constraints: [min: 1, max: 9_223_372_036_854_775_807]

    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :wake_request, Marshall.Compute.WakeRequest
    belongs_to :evacuation, Marshall.Compute.Evacuation
    belongs_to :deletion_operation, Marshall.Compute.Operation
    belongs_to :cancellation_stop_operation, Marshall.Compute.Operation
    belongs_to :cancellation_start_operation, Marshall.Compute.Operation
    belongs_to :import_request, Marshall.Compute.SourcePermitRequest
    belongs_to :activation_operation, Marshall.Compute.Operation
    belongs_to :vm, Marshall.Compute.VirtualMachine, allow_nil?: false
    belongs_to :source_placement, Marshall.Compute.WorkloadPlacement, allow_nil?: false
    belongs_to :destination_placement, Marshall.Compute.WorkloadPlacement, allow_nil?: false
    belongs_to :source_host, Marshall.Compute.Host, allow_nil?: false
    belongs_to :destination_host, Marshall.Compute.Host, allow_nil?: false
    belongs_to :requested_by, Marshall.Accounts.User
    belongs_to :cancellation_requested_by, Marshall.Accounts.User
    belongs_to :source_preflight_request, Marshall.Compute.ProbeRequest
    belongs_to :source_stop_operation, Marshall.Compute.Operation
  end

  identities do
    identity :one_unfinished_relocation, [:vm_id], where: expr(is_nil(finished_at))
    identity :relocation_request, [:vm_id, :requested_by_id, :request_key]
  end
end
