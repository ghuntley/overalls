defmodule Marshall.Agents.SkillRevision do
  @moduledoc "An immutable pinned skill revision verified on one thread machine generation."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "agent_skill_revisions"
    repo Marshall.Repo

    custom_indexes do
      index [:installation_id, :id]
      index [:operation_id], unique: true
    end
  end

  cedar do
    internal [:read, :record]
  end

  actions do
    defaults [:read]

    create :record do
      accept [
        :installation_id,
        :operation_id,
        :machine_id,
        :machine_key,
        :source,
        :commit,
        :digest,
        :path,
        :skill_path,
        :skill_digest,
        :skill_bytes,
        :name,
        :description
      ]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :installation_id, :uuid, allow_nil?: false
    attribute :operation_id, :uuid, allow_nil?: false
    attribute :machine_id, :uuid, allow_nil?: false
    attribute :machine_key, :string, allow_nil?: false
    attribute :source, :map, allow_nil?: false, sensitive?: true
    attribute :commit, :string, allow_nil?: false
    attribute :digest, :string, allow_nil?: false
    attribute :path, :string, allow_nil?: false, sensitive?: true
    attribute :skill_path, :string, allow_nil?: false, sensitive?: true
    attribute :skill_digest, :string, allow_nil?: false
    attribute :skill_bytes, :integer, allow_nil?: false, constraints: [min: 1, max: 1_048_576]
    attribute :name, :string, allow_nil?: false, constraints: [min_length: 1, max_length: 128]

    attribute :description, :string,
      allow_nil?: false,
      constraints: [min_length: 1, max_length: 2048]

    create_timestamp :inserted_at
  end
end
