defmodule Marshall.Artifacts.Version do
  @moduledoc "An immutable published version of an artifact."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Artifacts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  # @cc [owner:ghuntley,label:durability] artifact-version-immutable
  # Versions MUST be dense per artifact (1, 2, ...), never updated, and at most
  # one MUST exist per (artifact, publishing command) so a retried tool call is
  # idempotent.
  postgres do
    table "artifact_versions"
    repo Marshall.Repo

    references do
      reference :artifact, on_delete: :delete
    end

    custom_indexes do
      index [:artifact_id, :number], unique: true
      index [:artifact_id, :command_id], unique: true, where: "command_id IS NOT NULL"
    end
  end

  cedar do
    internal [:read, :record]
  end

  actions do
    defaults [:read]

    create :record do
      accept [
        :artifact_id,
        :number,
        :base_number,
        :command_id,
        :author_id,
        :page_sha256,
        :page_bytes,
        :total_bytes,
        :file_count,
        :title,
        :format
      ]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :number, :integer, allow_nil?: false, constraints: [min: 1]
    attribute :base_number, :integer, allow_nil?: false, constraints: [min: 0]
    attribute :command_id, :uuid
    attribute :author_id, :uuid, allow_nil?: false
    attribute :page_sha256, :string, allow_nil?: false, constraints: [match: ~r/\A[0-9a-f]{64}\z/]
    attribute :page_bytes, :integer, allow_nil?: false, constraints: [min: 0]
    attribute :total_bytes, :integer, allow_nil?: false, constraints: [min: 0]
    attribute :file_count, :integer, allow_nil?: false, constraints: [min: 1]
    attribute :title, :string, allow_nil?: false, constraints: [min_length: 1, max_length: 200]
    attribute :format, :atom, allow_nil?: false, constraints: [one_of: [:html, :markdown]]
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :artifact, Marshall.Artifacts.Artifact,
      allow_nil?: false,
      attribute_writable?: true
  end
end
