defmodule Marshall.Agents.SkillInstallation do
  @moduledoc "Thread-owned managed skill configuration; published revisions are immutable."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "agent_skill_installations"
    repo Marshall.Repo

    custom_indexes do
      index [:thread_id, :id]
    end
  end

  cedar do
    internal [:read, :register, :publish, :configure, :fail]
  end

  actions do
    defaults [:read]

    create :register do
      accept [:thread_id, :created_by_id, :source, :subdirectory]
    end

    update :publish do
      accept [:active_revision_id, :status, :enabled, :failure_reason]
    end

    update :configure do
      accept [:enabled, :status]
    end

    update :fail do
      accept [:failure_reason]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :thread_id, :uuid, allow_nil?: false
    attribute :created_by_id, :uuid, allow_nil?: false
    attribute :source, :map, allow_nil?: false, sensitive?: true
    attribute :subdirectory, :string, allow_nil?: false, default: "."
    attribute :active_revision_id, :uuid
    attribute :enabled, :boolean, allow_nil?: false, default: true

    attribute :status, :atom,
      allow_nil?: false,
      default: :pending,
      constraints: [one_of: [:pending, :ready, :removed]]

    attribute :failure_reason, :atom,
      constraints: [one_of: Marshall.Agents.Skills.Failures.values()]

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end
