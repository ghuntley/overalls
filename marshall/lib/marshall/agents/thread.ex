defmodule Marshall.Agents.Thread do
  @moduledoc "A root or single-parent child conversation within one VM agent."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshPaperTrail.Resource]

  postgres do
    table "agent_threads"
    repo Marshall.Repo

    custom_indexes do
      index [:root_id, :parent_thread_id]
      index [:root_id], unique: true, where: "parent_thread_id IS NULL"
    end
  end

  paper_trail do
    metadata :actor_kind, :atom, allow_nil?: true
    metadata :actor_id, :uuid, allow_nil?: true
    sensitive_attributes :ignore
    change_tracking_mode :changes_only
    store_action_name? true
    ignore_attributes [:inserted_at, :next_event_sequence]
    version_extensions authorizers: [Marshall.Authorization.AshAuthorizer]
  end

  actions do
    defaults [:read]

    action :submit_prompt, :map do
      argument :thread_id, :uuid, allow_nil?: false

      argument :prompt, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 65_536]

      argument :request_key, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 128]

      argument :collaboration_mode, :atom, constraints: [one_of: [:work, :plan]]
      argument :selected_skill_ids, {:array, :string}, constraints: [max_length: 32]
      argument :working_directory, :string, constraints: [max_length: 4096]

      run Marshall.Agents.Prompt
    end

    create :open do
      accept [
        :root_id,
        :parent_thread_id,
        :title,
        :created_by_id,
        :mode,
        :collaboration_mode,
        :working_directory,
        :selected_skills
      ]
    end

    update :advance do
      accept [:next_event_sequence, :active_turn_id]
    end

    update :set_mode do
      accept [:mode]
    end

    update :set_context do
      accept [:collaboration_mode, :working_directory, :selected_skills]
    end

    destroy :delete
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :root_id, :uuid, allow_nil?: false
    attribute :parent_thread_id, :uuid
    # @cc [owner:ghuntley,label:security] agent-thread-private-audit-exclusion
    # Titles, working paths and selected skill names MUST remain in authorized
    # thread state and MUST NOT be copied into PaperTrail audit versions.
    attribute :title, :string,
      allow_nil?: false,
      sensitive?: true,
      constraints: [min_length: 1, max_length: 256]

    attribute :mode, :atom,
      allow_nil?: false,
      default: :medium,
      constraints: [one_of: Marshall.Threads.Mode.values()]

    attribute :created_by_id, :uuid, allow_nil?: false

    attribute :collaboration_mode, :atom,
      allow_nil?: false,
      default: :work,
      constraints: [one_of: [:work, :plan]]

    attribute :working_directory, :string, sensitive?: true, constraints: [max_length: 4096]

    attribute :selected_skills, {:array, :string},
      allow_nil?: false,
      sensitive?: true,
      default: [],
      constraints: [max_length: 32]

    attribute :next_event_sequence, :integer,
      allow_nil?: false,
      default: 1,
      constraints: [min: 1]

    attribute :active_turn_id, :uuid
    create_timestamp :inserted_at
  end
end
