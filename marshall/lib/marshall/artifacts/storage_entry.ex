defmodule Marshall.Artifacts.StorageEntry do
  @moduledoc """
  One key in an artifact's page storage. `personal` entries are scoped to one
  user; `shared` entries are scoped to the artifact.
  """
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Artifacts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "artifact_storage_entries"
    repo Marshall.Repo

    references do
      reference :artifact, on_delete: :delete
    end

    custom_indexes do
      index [:artifact_id, :namespace, :scope_id, :key], unique: true
    end
  end

  cedar do
    internal [:destroy, :read, :put, :replace]
  end

  actions do
    defaults [:read, :destroy]

    create :put do
      accept [:artifact_id, :namespace, :scope_id, :key, :value, :bytes, :updated_by_id]
    end

    update :replace do
      accept [:value, :bytes, :updated_by_id]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :namespace, :atom, allow_nil?: false, constraints: [one_of: [:personal, :shared]]
    attribute :scope_id, :uuid, allow_nil?: false
    attribute :key, :string, allow_nil?: false, constraints: [min_length: 1, max_length: 256]

    attribute :value, :string,
      allow_nil?: false,
      sensitive?: true,
      constraints: [allow_empty?: true, trim?: false, max_length: 5_242_880]

    attribute :bytes, :integer, allow_nil?: false, constraints: [min: 0]
    attribute :updated_by_id, :uuid, allow_nil?: false
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :artifact, Marshall.Artifacts.Artifact,
      allow_nil?: false,
      attribute_writable?: true
  end
end
