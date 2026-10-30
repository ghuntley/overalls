defmodule Marshall.Artifacts.VersionFile do
  @moduledoc "A supporting file of an immutable version, by content address."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Artifacts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "artifact_version_files"
    repo Marshall.Repo

    references do
      reference :version, on_delete: :delete
    end

    custom_indexes do
      index [:version_id, :path], unique: true
      index [:sha256]
    end
  end

  cedar do
    internal [:read, :record]
  end

  actions do
    defaults [:read]

    create :record do
      accept [:version_id, :artifact_id, :path, :sha256, :bytes, :content_type]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :artifact_id, :uuid, allow_nil?: false
    attribute :path, :string, allow_nil?: false, constraints: [min_length: 1, max_length: 512]
    attribute :sha256, :string, allow_nil?: false, constraints: [match: ~r/\A[0-9a-f]{64}\z/]
    attribute :bytes, :integer, allow_nil?: false, constraints: [min: 0]
    attribute :content_type, :string, allow_nil?: false, constraints: [max_length: 128]
  end

  relationships do
    belongs_to :version, Marshall.Artifacts.Version, allow_nil?: false, attribute_writable?: true
  end
end
