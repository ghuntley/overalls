defmodule Marshall.Agents.AttachmentChunk do
  @moduledoc "Encrypted durable chunks for bounded attachment transfers."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshCloak]

  @type t :: %__MODULE__{}
  postgres do
    table "agent_attachment_chunks"
    repo Marshall.Repo
    migration_defaults id: "nil", inserted_at: "nil"
    identity_index_names attachment_offset: "agent_attachment_chunks_attachment_id_offset_index"

    references do
      reference :attachment, on_delete: :delete
    end

    check_constraints do
      check_constraint :offset, "attachment_chunk_bounds",
        check: "\"offset\" >= 0 AND size_bytes BETWEEN 1 AND 262144"
    end
  end

  cedar do
    internal [:destroy, :read, :store]
  end

  cloak do
    vault(Marshall.Vault)
    attributes([:bytes])
    decrypt_by_default([])
    encrypt_nil?(false)
  end

  actions do
    defaults [:read, :destroy]

    create :store do
      accept [:attachment_id, :offset, :size_bytes, :sha256, :bytes]
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :attachment_id, :uuid, allow_nil?: false
    attribute :offset, :integer, allow_nil?: false, constraints: [min: 0]
    attribute :size_bytes, :integer, allow_nil?: false, constraints: [min: 1, max: 262_144]
    attribute :sha256, :string, allow_nil?: false
    attribute :bytes, :binary, allow_nil?: false, sensitive?: true
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :attachment, Marshall.Agents.Attachment do
      define_attribute? false
      source_attribute :attachment_id
    end
  end

  identities do
    identity :attachment_offset, [:attachment_id, :offset]
  end
end
