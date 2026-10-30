defmodule Marshall.Agents.ContextSnapshot do
  @moduledoc "Immutable applied guest instructions and skill selection for an admitted turn."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "agent_context_snapshots"
    repo Marshall.Repo

    custom_indexes do
      index [:turn_id, :generation], unique: true
      index [:thread_id, :inserted_at]
    end
  end

  cedar do
    internal [:read, :capture]
  end

  actions do
    defaults [:read]

    create :capture do
      accept [
        :thread_id,
        :turn_id,
        :generation,
        :configuration_owner_id,
        :guest_account_id,
        :working_directory,
        :creator_home,
        :project_root,
        :collaboration_mode,
        :reasoning,
        :selected_skills,
        :sources,
        :instructions,
        :skill_catalog,
        :warnings,
        :inventory_digest,
        :host_id,
        :placement_id,
        :execution_epoch,
        :executor_id,
        :fence_epoch
      ]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :thread_id, :uuid, allow_nil?: false
    attribute :turn_id, :uuid, allow_nil?: false
    attribute :generation, :integer, allow_nil?: false, constraints: [min: 1]
    attribute :configuration_owner_id, :uuid, allow_nil?: false
    attribute :guest_account_id, :uuid, allow_nil?: false

    attribute :working_directory, :string,
      allow_nil?: false,
      sensitive?: true,
      constraints: [max_length: 4096]

    attribute :creator_home, :string,
      allow_nil?: false,
      sensitive?: true,
      constraints: [max_length: 4096]

    attribute :project_root, :string, sensitive?: true, constraints: [max_length: 4096]

    attribute :collaboration_mode, :atom,
      allow_nil?: false,
      constraints: [one_of: [:work, :plan]]

    attribute :reasoning, :atom,
      allow_nil?: false,
      constraints: [one_of: Marshall.Threads.Mode.values()]

    attribute :selected_skills, {:array, :string},
      allow_nil?: false,
      default: [],
      sensitive?: true

    attribute :sources, {:array, :map}, allow_nil?: false, default: [], sensitive?: true
    attribute :instructions, {:array, :string}, allow_nil?: false, default: [], sensitive?: true
    attribute :skill_catalog, {:array, :map}, allow_nil?: false, default: [], sensitive?: true
    attribute :warnings, {:array, :string}, allow_nil?: false, default: []

    attribute :inventory_digest, :string,
      allow_nil?: false,
      constraints: [match: ~r/\A[0-9a-f]{64}\z/]

    attribute :host_id, :uuid, allow_nil?: false
    attribute :placement_id, :uuid, allow_nil?: false
    attribute :execution_epoch, :integer, allow_nil?: false, constraints: [min: 1]
    attribute :executor_id, :uuid, allow_nil?: false
    attribute :fence_epoch, :integer, allow_nil?: false, constraints: [min: 1]
    create_timestamp :inserted_at
  end
end
