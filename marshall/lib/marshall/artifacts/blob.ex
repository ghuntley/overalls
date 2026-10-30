defmodule Marshall.Artifacts.Blob do
  @moduledoc """
  Content-addressed bytes. Chunks live in `artifact_blob_chunks` and are only
  written and streamed through `Marshall.Artifacts.Blobs`.
  """
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Artifacts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "artifact_blobs"
    repo Marshall.Repo
  end

  cedar do
    internal [:read]
  end

  actions do
    defaults [:read]
  end

  attributes do
    attribute :sha256, :string,
      primary_key?: true,
      allow_nil?: false,
      constraints: [match: ~r/\A[0-9a-f]{64}\z/]

    attribute :bytes, :integer, allow_nil?: false, constraints: [min: 0]
    attribute :chunk_count, :integer, allow_nil?: false, constraints: [min: 0]
    create_timestamp :inserted_at
  end
end
