defmodule Marshall.Threads.Thread do
  @moduledoc "A durable user-level thread and the machine that executes it."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Threads,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshStateMachine, AshArchival.Resource, AshPaperTrail.Resource]

  postgres do
    table "threads"
    repo Marshall.Repo

    custom_indexes do
      index [:idempotency_key], unique: true
      index [:machine_key], unique: true
      index [:machine_id]
      index [:creator_id, :inserted_at]
      index [:team_id, :inserted_at]
    end
  end

  cedar do
    control_plane "provision", [
      :create_thread,
      :list_for_user,
      :list_page_for_user,
      :get_for_user,
      :submit_prompt,
      :thread_controls,
      :context_info,
      :list_skills,
      :set_collaboration_mode,
      :answer_questions,
      :implement_plan,
      :compact_context,
      :reload_context,
      :install_skill,
      :update_skill,
      :set_skill_enabled,
      :remove_skill,
      :retry_provisioning,
      :archive_thread,
      :delete_thread,
      :reopen_thread
    ]

    internal [
      :read,
      :history,
      :open,
      :record_admitted_machine,
      :begin_provisioning,
      :bind_agent,
      :mark_ready,
      :mark_failed,
      :requeue,
      :replace_generation,
      :reopen,
      :mark_deleting,
      :mark_archived,
      :set_title,
      :set_collaboration_mode_state,
      :touch_activity,
      :archive
    ]
  end

  # @cc [owner:ghuntley,label:durability;recovery] thread-status-state-machine
  # Thread status MUST change only through the named transitions below; no
  # action may accept `:status`. Every committed transition MUST record its
  # lifecycle evidence and synchronize the current generation inside the same
  # transaction (ADR-0255).
  state_machine do
    state_attribute :status
    initial_states [:pending]
    default_initial_state :pending

    transitions do
      transition :begin_provisioning, from: [:pending, :provisioning, :failed], to: :provisioning
      transition :bind_agent, from: [:pending, :provisioning, :failed], to: :provisioning
      transition :mark_ready, from: [:provisioning], to: :ready
      transition :mark_failed, from: [:pending, :provisioning, :failed], to: :failed
      transition :requeue, from: [:pending, :failed], to: :pending
      transition :replace_generation, from: [:pending, :failed], to: :pending
      transition :reopen, from: [:archived], to: :pending
      transition :mark_deleting, from: [:pending, :provisioning, :ready, :failed], to: :deleting

      transition :mark_archived,
        from: [:pending, :provisioning, :ready, :failed, :deleting],
        to: :archived
    end
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
    ignore_attributes [:inserted_at, :updated_at, :objective, :machine_spec]
    version_extensions authorizers: [Marshall.Authorization.AshAuthorizer]
    mixin Marshall.Authorization.VersionMapping
  end

  actions do
    defaults [:read]
    read :history

    action :create_thread, :struct do
      constraints instance_of: __MODULE__

      argument :objective, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 65_536]

      argument :mode, :atom,
        default: :medium,
        constraints: [one_of: Marshall.Threads.Mode.values()]

      argument :collaboration_mode, :atom,
        default: :work,
        constraints: [one_of: [:work, :plan]]

      argument :selected_skill_ids, {:array, :string},
        default: [],
        constraints: [max_length: 32, items: [min_length: 1, max_length: 256]]

      argument :machine_spec, :map, allow_nil?: false

      argument :idempotency_key, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 128]

      run {Marshall.Threads.Coordinator, operation: :create_thread}
    end

    action :list_for_user, {:array, :struct} do
      argument :limit, :integer, default: 100, constraints: [min: 1, max: 100]
      run {Marshall.Threads.Coordinator, operation: :list}
    end

    action :list_page_for_user, :map do
      argument :after, :uuid
      argument :machine_id, :uuid
      argument :query, :string, constraints: [min_length: 1, max_length: 256]

      argument :status, :atom,
        constraints: [one_of: [:pending, :provisioning, :ready, :failed, :deleting, :archived]]

      argument :limit, :integer, default: 50, constraints: [min: 1, max: 100]
      run {Marshall.Threads.Coordinator, operation: :list_page}
    end

    action :get_for_user, :struct do
      argument :thread_id, :uuid, allow_nil?: false
      run {Marshall.Threads.Coordinator, operation: :get}
    end

    action :submit_prompt, :map do
      argument :thread_id, :uuid, allow_nil?: false

      argument :prompt, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 65_536]

      argument :request_key, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 128]

      argument :collaboration_mode, :atom, constraints: [one_of: [:work, :plan]]

      argument :selected_skill_ids, {:array, :string},
        constraints: [max_length: 32, items: [min_length: 1, max_length: 256]]

      run {Marshall.Threads.Coordinator, operation: :prompt}
    end

    for action <- [:thread_controls, :context_info, :list_skills] do
      action action, :map do
        argument :thread_id, :uuid, allow_nil?: false
        argument :limit, :integer, default: 100, constraints: [min: 1, max: 100]
        run {Marshall.Threads.Coordinator, operation: action}
      end
    end

    action :set_collaboration_mode, :map do
      argument :thread_id, :uuid, allow_nil?: false

      argument :collaboration_mode, :atom,
        allow_nil?: false,
        constraints: [one_of: [:work, :plan]]

      run {Marshall.Threads.Coordinator, operation: :set_collaboration_mode}
    end

    action :answer_questions, :map do
      argument :thread_id, :uuid, allow_nil?: false
      argument :question_id, :uuid, allow_nil?: false
      argument :answers, :map, allow_nil?: false

      argument :request_key, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 128]

      run {Marshall.Threads.Coordinator, operation: :answer_questions}
    end

    action :implement_plan, :map do
      argument :thread_id, :uuid, allow_nil?: false
      argument :plan_id, :uuid, allow_nil?: false

      argument :request_key, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 128]

      run {Marshall.Threads.Coordinator, operation: :implement_plan}
    end

    for action <- [:compact_context, :reload_context] do
      action action, :map do
        argument :thread_id, :uuid, allow_nil?: false

        argument :request_key, :string,
          allow_nil?: false,
          constraints: [min_length: 1, max_length: 128]

        run {Marshall.Threads.Coordinator, operation: action}
      end
    end

    action :install_skill, :map do
      argument :thread_id, :uuid, allow_nil?: false
      argument :url, :string, allow_nil?: false, constraints: [max_length: 4096]
      argument :revision, :string, constraints: [max_length: 256]
      argument :subdirectory, :string, default: ".", constraints: [max_length: 1024]

      argument :idempotency_key, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 128]

      run {Marshall.Threads.Coordinator, operation: :install_skill}
    end

    action :update_skill, :map do
      argument :thread_id, :uuid, allow_nil?: false
      argument :installation_id, :uuid, allow_nil?: false
      argument :revision, :string, constraints: [max_length: 256]

      argument :idempotency_key, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 128]

      run {Marshall.Threads.Coordinator, operation: :update_skill}
    end

    action :set_skill_enabled, :map do
      argument :thread_id, :uuid, allow_nil?: false
      argument :installation_id, :uuid, allow_nil?: false
      argument :enabled, :boolean, allow_nil?: false

      argument :idempotency_key, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 128]

      run {Marshall.Threads.Coordinator, operation: :set_skill_enabled}
    end

    action :remove_skill, :map do
      argument :thread_id, :uuid, allow_nil?: false
      argument :installation_id, :uuid, allow_nil?: false

      argument :idempotency_key, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 128]

      run {Marshall.Threads.Coordinator, operation: :remove_skill}
    end

    action :retry_provisioning, :struct do
      argument :thread_id, :uuid, allow_nil?: false
      run {Marshall.Threads.Coordinator, operation: :retry}
    end

    action :archive_thread, :struct do
      argument :thread_id, :uuid, allow_nil?: false
      run {Marshall.Threads.Coordinator, operation: :archive}
    end

    action :delete_thread, :struct do
      argument :thread_id, :uuid, allow_nil?: false
      run {Marshall.Threads.Coordinator, operation: :delete}
    end

    action :reopen_thread, :struct do
      argument :thread_id, :uuid, allow_nil?: false
      run {Marshall.Threads.Coordinator, operation: :reopen}
    end

    create :open do
      accept [
        :creator_id,
        :team_id,
        :objective,
        :mode,
        :collaboration_mode,
        :initial_collaboration_mode,
        :initial_skill_ids,
        :machine_spec,
        :idempotency_key,
        :machine_key
      ]
    end

    # Records the admitted Compute machine before readiness; not a transition.
    update :record_admitted_machine do
      accept [:machine_id]
    end

    update :begin_provisioning do
      accept []
      change transition_state(:provisioning)
    end

    update :bind_agent do
      accept [:agent_root_id, :agent_thread_id]
      change set_attribute(:failure_reason, nil)
      change transition_state(:provisioning)
    end

    update :mark_ready do
      accept []
      change set_attribute(:failure_reason, nil)
      change transition_state(:ready)
    end

    update :mark_failed do
      accept [:failure_reason]
      change transition_state(:failed)
    end

    update :requeue do
      accept []
      change set_attribute(:failure_reason, nil)
      change transition_state(:pending)
    end

    for {name, state} <- [replace_generation: :pending, reopen: :pending] do
      update name do
        atomic_upgrade_with :history

        argument :machine_key, :string,
          allow_nil?: false,
          constraints: [min_length: 1, max_length: 160]

        change set_attribute(:machine_key, arg(:machine_key))

        for attribute <- [
              :archived_at,
              :machine_id,
              :agent_root_id,
              :agent_thread_id,
              :failure_reason
            ] do
          change set_attribute(attribute, nil)
        end

        change transition_state(state)
      end
    end

    update :mark_deleting do
      accept []
      change transition_state(:deleting)
    end

    update :mark_archived do
      accept []
      change set_attribute(:archived_at, &DateTime.utc_now/0)
      change transition_state(:archived)
    end

    update :set_title do
      accept [:title]
    end

    update :set_collaboration_mode_state do
      accept [:collaboration_mode]
    end

    # Activity is projected from durable agent events. This action intentionally
    # accepts no business attributes: the update timestamp is the projection.
    update :touch_activity do
      accept []
      change Marshall.Threads.TouchActivity
    end

    destroy :archive
  end

  @transitions [
    :begin_provisioning,
    :bind_agent,
    :mark_ready,
    :mark_failed,
    :requeue,
    :replace_generation,
    :reopen,
    :mark_deleting,
    :mark_archived
  ]

  @doc "Named status transitions; each records lifecycle evidence and syncs its generation."
  @spec transitions() :: [atom()]
  def transitions, do: @transitions

  # @cc [owner:ghuntley,label:protocol;observability] thread-change-hint
  # Every committed thread change, including the activity projection that
  # follows each durable agent event, MUST emit a `:thread` hint carrying only
  # the thread UUID. The hint is delivered after the outer commit (pg_notify)
  # and is never authority: watchers re-read through authorized commands.
  changes do
    change {Marshall.Control.Hints.Change, kind: :thread, from: :id},
      on: [:create, :update, :destroy]

    change Marshall.Compute.LifecycleAudit, where: [action_is(@transitions)]
    change Marshall.Threads.Changes.SyncGeneration, where: [action_is(@transitions)]
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :creator_id, :uuid, allow_nil?: false
    attribute :team_id, :uuid
    # @cc [owner:ghuntley,label:security] thread-title-audit-exclusion
    # Generated titles MAY contain private conversation content and MUST NOT
    # be copied into PaperTrail audit versions.
    attribute :title, :string,
      allow_nil?: true,
      sensitive?: true,
      constraints: [max_length: 256]

    attribute :objective, :string,
      allow_nil?: false,
      sensitive?: true,
      constraints: [min_length: 1, max_length: 65_536]

    attribute :mode, :atom,
      allow_nil?: false,
      default: :medium,
      constraints: [one_of: Marshall.Threads.Mode.values()]

    attribute :collaboration_mode, :atom,
      allow_nil?: false,
      default: :work,
      constraints: [one_of: [:work, :plan]]

    # @cc [owner:ghuntley,label:durability] thread-initial-context-replay
    # Create retries MUST compare the admitted initial collaboration mode and
    # skill identities, even after the current collaboration mode has changed.
    attribute :initial_collaboration_mode, :atom,
      allow_nil?: false,
      default: :work,
      constraints: [one_of: [:work, :plan]]

    attribute :initial_skill_ids, {:array, :string},
      allow_nil?: false,
      default: [],
      sensitive?: true,
      constraints: [max_length: 32, items: [min_length: 1, max_length: 256]]

    attribute :machine_spec, :map, allow_nil?: false
    attribute :machine_id, :uuid
    attribute :agent_root_id, :uuid
    attribute :agent_thread_id, :uuid

    attribute :idempotency_key, :string,
      allow_nil?: false,
      constraints: [min_length: 1, max_length: 128]

    # Reopening keeps the durable create request key but receives a fresh
    # Compute admission key for its replacement machine.

    # @cc [owner:ghuntley,label:durability;recovery] thread-machine-key-total
    # Every persisted thread MUST carry its machine admission key. Admission and
    # stale-job fencing MUST NOT fall back to the original create request key.
    attribute :machine_key, :string,
      allow_nil?: false,
      constraints: [min_length: 1, max_length: 160]

    attribute :status, :atom,
      allow_nil?: false,
      default: :pending,
      constraints: [one_of: [:pending, :provisioning, :ready, :failed, :deleting, :archived]]

    attribute :failure_reason, :atom,
      constraints: [
        one_of: [
          :invalid_machine_spec,
          :invalid_profile,
          :capacity,
          :machine_unavailable,
          :provision_failed,
          :agent_unavailable,
          :unknown
        ]
      ]

    attribute :archived_at, :utc_datetime_usec
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    has_many :grants, Marshall.Threads.Grant, destination_attribute: :thread_id

    belongs_to :creator, Marshall.Accounts.User do
      define_attribute? false
      source_attribute :creator_id
    end

    belongs_to :team, Marshall.Teams.Team, define_attribute?: false
  end
end
