# @cc [owner:ghuntley,label:recovery] vm-archived-idempotency-history
# Physical deletion MUST archive the VM instead of erasing its identity and
# owner/idempotency-key history. Retries after deletion MUST NOT allocate another
# VM under the original key.
defmodule Marshall.Compute.VirtualMachine do
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Compute,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshArchival.Resource, AshPaperTrail.Resource, AshStateMachine]

  postgres do
    table "compute_virtual_machines"
    repo Marshall.Repo
    identity_wheres_to_sql active_name: "archived_at IS NULL"
    migration_types crash_restart_times: {:array, :utc_datetime_usec}

    references do
      reference :current_placement, match_with: [id: :vm_id], deferrable: :initially
    end

    custom_indexes do
      index [:current_placement_id, :desired_state, :id]
      # Keyset machine lists by owner and team (ADR-0256).
      index [:owner_id, :id],
        where: "archived_at IS NULL",
        name: "compute_virtual_machines_owner_index"

      index [:team_id, :id],
        where: "archived_at IS NULL",
        name: "compute_virtual_machines_team_index"
    end
  end

  cedar do
    control_plane "admin_read", [:list_for_admin]

    control_plane "provision", [
      :set_reflection_metadata,
      :get_for_user,
      :resolve_for_user,
      :list_for_user,
      :pinned_for_user,
      :catalog,
      :repository_launch_request,
      :clone,
      :list_clones,
      :get_clone,
      :retry_clone,
      :cancel_clone,
      :resize,
      :retry_resize,
      :cancel_resize,
      :relocate,
      :cancel_relocation,
      :retry_relocation,
      :lifecycle,
      :provision
    ]

    internal [
      :read,
      :history,
      :allocate,
      :handoff,
      :restore_source,
      :request_start,
      :request_pause,
      :idle_policy,
      :reflection_metadata,
      :checkpoint,
      :request_stop,
      :request_delete,
      :apply_resize,
      :observe,
      :archive
    ]
  end

  archive do
    exclude_read_actions([:history])
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
      :idempotency_key,
      :provisioning_sizes,
      :guest_ssh_key_id
    ]

    version_extensions authorizers: [Marshall.Authorization.AshAuthorizer]
    mixin Marshall.Authorization.VersionMapping
  end

  # @cc [owner:ghuntley,label:recovery] vm-deletion-terminal-intent
  # Deleted intent MUST NOT return to running, paused or stopped. Observations remain
  # separate authenticated facts; a state transition alone cannot release holds.
  state_machine do
    # Board retention follows durable lifecycle states; terminal transitions purge posts.
    state_attribute :desired_state
    initial_states [:running]
    default_initial_state :running

    transitions do
      transition :request_start, from: [:running, :stopped, :paused], to: :running
      transition :request_stop, from: [:running, :stopped, :paused], to: :stopped
      transition :request_delete, from: [:running, :stopped, :paused, :deleted], to: :deleted
      transition :request_pause, from: [:running, :stopped, :paused], to: :paused
      transition :handoff, from: [:stopped, :paused], to: [:running, :stopped, :paused]
      transition :restore_source, from: [:running, :stopped, :paused], to: [:stopped, :paused]
    end
  end

  actions do
    defaults [:read]
    read :history

    action :set_reflection_metadata, :map do
      argument :vm_id, :uuid, allow_nil?: false
      argument :labels, {:array, :string}, allow_nil?: false, default: []
      argument :comment, :string, allow_nil?: false, default: ""
      run Marshall.Compute.ReflectionMetadata
    end

    action :get_for_user, :map do
      argument :vm_id, :uuid, allow_nil?: false
      run {Marshall.Compute.Views, operation: :get}
    end

    action :resolve_for_user, :map do
      argument :reference, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 63]

      run {Marshall.Compute.Views, operation: :resolve}
    end

    action :list_for_user, :map do
      argument :after, :uuid
      argument :limit, :integer, allow_nil?: false, default: 50, constraints: [min: 1, max: 100]

      # The caller's pinned ids (ADR-0193), so a pinned machine shown in the
      # pinned section never appears again in the keyset pages.
      argument :exclude, {:array, :uuid},
        allow_nil?: false,
        default: [],
        constraints: [max_length: 20]

      run {Marshall.Compute.Views, operation: :list}
    end

    action :pinned_for_user, :map do
      # Views are built only for the first `limit` readable pins; `ids` still
      # lists every readable pin so callers can exclude them from keyset pages.
      argument :limit, :integer, allow_nil?: false, default: 20, constraints: [min: 1, max: 20]
      run {Marshall.Compute.Views, operation: :pinned}
    end

    action :list_for_admin, :map do
      argument :after, :uuid
      argument :limit, :integer, allow_nil?: false, default: 100, constraints: [min: 1, max: 100]
      run Marshall.Compute.AdminViews
    end

    action :catalog, :map do
      run {Marshall.Compute.Views, operation: :catalog}
    end

    action :repository_launch_request, :map do
      argument :idempotency_key, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 128]

      run {Marshall.Compute.Views, operation: :repository_launch_request}
    end

    action :clone, :map do
      argument :vm_id, :uuid, allow_nil?: false

      argument :name, :string,
        constraints: [
          min_length: 1,
          max_length: 63,
          match: OverallsProtocol.MachineName.pattern()
        ]

      argument :idempotency_key, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 128]

      run {Marshall.Compute.Cloning, operation: :submit}
    end

    action :list_clones, :map do
      argument :vm_id, :uuid, allow_nil?: false
      argument :before, :integer, constraints: [min: 1]
      argument :limit, :integer, default: 50, allow_nil?: false, constraints: [min: 1, max: 100]
      run {Marshall.Compute.Cloning, operation: :list}
    end

    action :get_clone, :map do
      argument :request_id, :uuid, allow_nil?: false
      run {Marshall.Compute.Cloning, operation: :get}
    end

    action :retry_clone, :map do
      argument :request_id, :uuid, allow_nil?: false
      run {Marshall.Compute.Cloning, operation: :retry}
    end

    action :cancel_clone, :map do
      argument :request_id, :uuid, allow_nil?: false
      run {Marshall.Compute.Cloning, operation: :cancel}
    end

    action :resize, :struct do
      constraints instance_of: Marshall.Compute.ResizeRequest
      argument :vm_id, :uuid, allow_nil?: false
      argument :expected_generation, :integer, allow_nil?: false, constraints: [min: 1]

      argument :idempotency_key, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 128]

      argument :vcpu, :integer, allow_nil?: false
      argument :memory_bytes, :integer, allow_nil?: false

      argument :disk_bytes, :integer,
        allow_nil?: false,
        constraints: [min: 2_147_483_648, max: OverallsProtocol.VMShape.maximum_disk_bytes()]

      run Marshall.Compute.Resize
    end

    action :retry_resize, :struct do
      constraints instance_of: Marshall.Compute.ResizeRequest
      argument :vm_id, :uuid, allow_nil?: false
      argument :request_id, :uuid, allow_nil?: false
      argument :expected_generation, :integer, allow_nil?: false, constraints: [min: 1]
      run {Marshall.Compute.Resize, retry: true}
    end

    action :cancel_resize, :struct do
      constraints instance_of: Marshall.Compute.ResizeRequest
      argument :vm_id, :uuid, allow_nil?: false
      argument :request_id, :uuid, allow_nil?: false
      run {Marshall.Compute.Resize, cancel: true}
    end

    action :relocate, :struct do
      constraints instance_of: Marshall.Compute.Relocation
      argument :vm_id, :uuid, allow_nil?: false

      argument :idempotency_key, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 128]

      run Marshall.Compute.RelocationAdmission
    end

    action :cancel_relocation, :struct do
      constraints instance_of: Marshall.Compute.Relocation
      argument :relocation_id, :uuid, allow_nil?: false
      run Marshall.Compute.RelocationCancellation
    end

    action :retry_relocation, :struct do
      constraints instance_of: Marshall.Compute.RelocationRetry
      argument :relocation_id, :uuid, allow_nil?: false

      argument :idempotency_key, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 128]

      run Marshall.Compute.RelocationRetryAdmission
    end

    action :lifecycle, :struct do
      argument :vm_id, :uuid, allow_nil?: false

      argument :kind, :atom,
        allow_nil?: false,
        constraints: [one_of: [:start, :stop, :delete, :pause, :resume]]

      argument :idempotency_key, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 128]

      run Marshall.Compute.Lifecycle
    end

    action :provision, :struct do
      constraints instance_of: __MODULE__

      argument :name, :string,
        constraints: [
          min_length: 1,
          max_length: 63,
          match: OverallsProtocol.MachineName.pattern()
        ]

      argument :idempotency_key, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 128]

      argument :architecture, :atom, allow_nil?: false, constraints: [one_of: [:x86_64]]

      argument :image_id, :string,
        allow_nil?: false,
        constraints: [match: ~r/\Asha256:[0-9a-f]{64}\z/]

      argument :profile, :atom,
        allow_nil?: false,
        constraints: [one_of: [:customer, :standard, :oss, :inception]]

      argument :vcpu, :integer, allow_nil?: false, constraints: [min: 1, max: 32]

      argument :memory_bytes, :integer,
        allow_nil?: false,
        constraints: [min: 536_870_912, max: 274_877_906_944]

      argument :disk_bytes, :integer,
        allow_nil?: false,
        constraints: [min: 2_147_483_648, max: OverallsProtocol.VMShape.maximum_disk_bytes()]

      argument :team_id, :uuid

      argument :comment, :string, default: "", constraints: [max_length: 2048, allow_empty?: true]

      # The validated OverallsProtocol.WorkspaceSource map; admission re-validates it
      # and refuses it for profiles without egress (ADR-0128).
      argument :workspace_source, :map

      run Marshall.Compute.Admission
    end

    create :allocate do
      accept [
        :id,
        :name,
        :owner_id,
        :team_id,
        :current_placement_id,
        :image_id,
        :idempotency_key,
        :architecture,
        :profile,
        :vcpu,
        :memory_bytes,
        :disk_bytes,
        :provisioning_sizes,
        :git_identity,
        :comment
      ]

      change fn changeset, _ ->
        sizes =
          Map.new([:vcpu, :memory_bytes, :disk_bytes], fn key ->
            {Atom.to_string(key), Ash.Changeset.get_attribute(changeset, key)}
          end)

        Ash.Changeset.force_change_attribute(changeset, :provisioning_sizes, sizes)
      end
    end

    # @cc [owner:ghuntley,label:security;recovery] relocation-only-placement-handoff
    # Only the serialized relocation coordinator may use handoff after verified
    # quiescent-copy/import. Placement, successor epoch and reset observation sequence MUST
    # commit with activation outbox; owner/image/shape/address remain unchanged.
    update :handoff do
      accept [
        :current_placement_id,
        :execution_epoch,
        :generation,
        :observed_state,
        :outcome_sequence,
        :observed_at,
        :failure_reason
      ]

      argument :desired_state, :atom,
        allow_nil?: false,
        constraints: [one_of: [:running, :stopped, :paused]]

      change transition_state(arg(:desired_state))
    end

    # @cc [owner:ghuntley,label:security;recovery] cancellation-source-epoch-only
    # Only the cancellation coordinator may advance source epoch here, preserving
    # placement and identity. The fresh pause/stop and outbox MUST commit atomically
    # after confirmed export revocation; this action alone grants no restart.
    update :restore_source do
      accept [
        :execution_epoch,
        :generation,
        :observed_state,
        :observed_at,
        :failure_reason
      ]

      argument :desired_state, :atom,
        allow_nil?: false,
        constraints: [one_of: [:running, :stopped, :paused]]

      change transition_state(arg(:desired_state))
    end

    update :request_start do
      accept [:generation, :crash_restart_times]
      change transition_state(:running)
    end

    update :request_pause do
      accept [:generation, :crash_restart_times]
      change transition_state(:paused)
      change Marshall.Compute.MessageBoardCleanup
    end

    update :idle_policy do
      accept [:idle_suspend_enabled, :idle_activity_at, :idle_revision]
    end

    update :reflection_metadata do
      accept [:labels, :comment]
    end

    update :checkpoint do
      accept [:current_checkpoint]
    end

    update :request_stop do
      accept [:generation, :crash_restart_times]
      change transition_state(:stopped)
      change Marshall.Compute.MessageBoardCleanup
    end

    update :request_delete do
      accept [:generation, :crash_restart_times]
      change transition_state(:deleted)
      change Marshall.Compute.MessageBoardCleanup
    end

    update :apply_resize do
      accept [:vcpu, :memory_bytes, :disk_bytes]
    end

    update :observe do
      accept [:observed_state, :outcome_sequence, :observed_at, :failure_reason]
    end

    destroy :archive
  end

  preparations do
    prepare build(load: [:host_id, :pool_id])
  end

  changes do
    change Marshall.Compute.LifecycleAudit, on: [:create, :update, :destroy]
    # Control hints (ADR-0140): emitted in the action's transaction.
    change {Marshall.Control.Hints.Change, kind: :vm, from: :id},
      on: [:create, :update, :destroy],
      where: [
        action_is([
          :handoff,
          :restore_source,
          :request_start,
          :request_pause,
          :request_stop,
          :request_delete,
          :apply_resize
        ])
      ]

    # The host gateway's route catalog lists running VMs placed on it.
    change {Marshall.Control.Hints.Change,
            kind: :gateway_catalog, from: {Marshall.Control.Hints.Hosts, :of_vm}},
           on: [:create, :update, :destroy],
           where: [
             action_is([
               :handoff,
               :restore_source,
               :request_start,
               :request_pause,
               :request_stop,
               :request_delete,
               :observe,
               :archive
             ])
           ]

    # The published zone lists routable VMs too (ADR-0142).
    change {Marshall.Control.Hints.Change, kind: :dns_snapshot, from: :id},
      on: [:create, :update, :destroy],
      where: [
        action_is([
          :handoff,
          :restore_source,
          :request_start,
          :request_pause,
          :request_stop,
          :request_delete,
          :observe,
          :archive
        ])
      ]
  end

  attributes do
    uuid_primary_key :id, writable?: true

    attribute :name, :string,
      allow_nil?: false,
      constraints: [min_length: 1, max_length: 63, match: OverallsProtocol.MachineName.pattern()]

    attribute :execution_epoch, :integer,
      allow_nil?: false,
      default: 1,
      constraints: [min: 1, max: 9_223_372_036_854_775_807]

    attribute :idempotency_key, :string, allow_nil?: false
    # Inert during the mixed-release updater window. No new action accepts it;
    # physical column removal requires a later coordinated schema cleanup.
    attribute :guest_ssh_key_id, :uuid
    attribute :architecture, :atom, allow_nil?: false, constraints: [one_of: [:x86_64]]

    attribute :profile, :atom,
      allow_nil?: false,
      constraints: [one_of: [:customer, :standard, :oss, :inception]]

    # @cc [owner:ghuntley,label:product] vm-git-identity-immutable
    # Git identity MUST be captured only at allocation and retained across restarts,
    # relocation and account preference changes.
    attribute :git_identity, :map, sensitive?: true
    attribute :provisioning_sizes, :map, allow_nil?: false
    attribute :vcpu, :integer, allow_nil?: false, constraints: [min: 1, max: 32]
    attribute :memory_bytes, :integer, allow_nil?: false, constraints: [min: 536_870_912]
    attribute :disk_bytes, :integer, allow_nil?: false, constraints: [min: 2_147_483_648]

    attribute :labels, {:array, :string},
      allow_nil?: false,
      default: [],
      constraints: [max_length: 32]

    # @cc [owner:ghuntley,label:product] vm-empty-reflection-comment
    # A machine without an operator comment MUST retain the empty-string default
    # so metadata-free provisioning remains valid.
    attribute :comment, :string,
      allow_nil?: false,
      default: "",
      constraints: [max_length: 2048, allow_empty?: true]

    attribute :generation, :integer, allow_nil?: false, default: 1, constraints: [min: 1]
    attribute :outcome_sequence, :integer, allow_nil?: false, default: 0, constraints: [min: 0]
    attribute :current_checkpoint, :map
    attribute :idle_suspend_enabled, :boolean, allow_nil?: false, default: false
    attribute :idle_activity_at, :utc_datetime_usec
    attribute :idle_revision, :integer, allow_nil?: false, default: 0, constraints: [min: 0]
    attribute :observed_at, :utc_datetime_usec

    attribute :failure_reason, :atom,
      constraints: [
        one_of: [:execution_failed, :crashed, :cleanup_failed, :identity_mismatch, :unknown]
      ]

    attribute :crash_restart_times, {:array, :utc_datetime_usec}, allow_nil?: false, default: []

    attribute :desired_state, :atom,
      allow_nil?: false,
      default: :running,
      constraints: [one_of: [:running, :stopped, :paused, :deleted]]

    attribute :observed_state, :atom,
      allow_nil?: false,
      default: :pending,
      constraints: [one_of: [:pending, :running, :stopped, :paused, :unknown, :failed, :deleted]]

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    has_many :access_grants, Marshall.Access.Grant, destination_attribute: :vm_id

    # @cc [owner:ghuntley,label:security] vm-current-thread-access-candidates
    # Thread-derived access candidates MUST follow the current machine binding
    # and exclude archived threads. This relationship is only a query prefilter;
    # fresh Cedar authorization MUST validate the thread owner and current grants.
    has_many :current_threads, Marshall.Threads.Thread do
      destination_attribute :machine_id

      filter expr(
               is_nil(archived_at) and
                 status in [:pending, :provisioning, :ready, :failed, :deleting]
             )
    end

    belongs_to :owner, Marshall.Accounts.User, allow_nil?: false
    belongs_to :team, Marshall.Teams.Team
    belongs_to :current_placement, Marshall.Compute.WorkloadPlacement, allow_nil?: false
    belongs_to :image, Marshall.Compute.Image, attribute_type: :string, allow_nil?: false
    has_one :network_address, Marshall.Compute.NetworkAddress, destination_attribute: :vm_id
  end

  calculations do
    calculate :host_id, :uuid, expr(current_placement.host_id)
    calculate :pool_id, :uuid, expr(current_placement.pool_id)
  end

  identities do
    identity :idempotent_request, [:owner_id, :idempotency_key]
    identity :active_name, [:name], where: expr(is_nil(archived_at))
  end
end
