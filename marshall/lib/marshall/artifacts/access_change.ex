defmodule Marshall.Artifacts.AccessChange do
  @moduledoc "Immutable artifact-sharing receipt."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Artifacts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "artifact_access_changes"
    repo Marshall.Repo

    references do
      reference :artifact, on_delete: :delete
    end
  end

  cedar do
    internal [:read, :record]
  end

  actions do
    defaults [:read]

    create :record do
      accept [:artifact_id, :requested_by_id, :user_id, :team_id, :role, :request_key, :grant_id]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :requested_by_id, :uuid, allow_nil?: false
    attribute :user_id, :uuid
    attribute :team_id, :uuid
    attribute :grant_id, :uuid

    attribute :role, :atom,
      allow_nil?: false,
      constraints: [one_of: [:owner, :writer, :viewer, :revoked]]

    attribute :request_key, :string, allow_nil?: false, constraints: [max_length: 128]
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :artifact, Marshall.Artifacts.Artifact,
      allow_nil?: false,
      attribute_writable?: true
  end

  identities do
    identity :idempotent_change, [:artifact_id, :requested_by_id, :request_key]
  end
end
