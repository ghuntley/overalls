defmodule Marshall.Artifacts.StorageUsage do
  @moduledoc "Locked byte and entry counters per storage scope, reconciled daily."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Artifacts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "artifact_storage_usage"
    repo Marshall.Repo

    references do
      reference :artifact, on_delete: :delete
    end

    custom_indexes do
      index [:artifact_id, :namespace, :scope_id], unique: true
    end
  end

  cedar do
    internal [:read, :open, :adjust]
  end

  actions do
    defaults [:read]

    create :open do
      accept [:artifact_id, :namespace, :scope_id]
    end

    update :adjust do
      accept [:bytes, :entries]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :namespace, :atom, allow_nil?: false, constraints: [one_of: [:personal, :shared]]
    attribute :scope_id, :uuid, allow_nil?: false
    attribute :bytes, :integer, allow_nil?: false, default: 0, constraints: [min: 0]
    attribute :entries, :integer, allow_nil?: false, default: 0, constraints: [min: 0]
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :artifact, Marshall.Artifacts.Artifact,
      allow_nil?: false,
      attribute_writable?: true
  end
end
