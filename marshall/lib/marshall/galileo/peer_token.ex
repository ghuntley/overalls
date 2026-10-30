defmodule Marshall.Galileo.PeerToken do
  @moduledoc "One-use digest-backed Galileo peer attestation."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Galileo,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "galileo_peer_tokens"
    repo Marshall.Repo

    check_constraints do
      check_constraint :digest, "galileo_peer_tokens_digest_size",
        check: "octet_length(digest) = 32"

      check_constraint :integration_name, "galileo_peer_tokens_name_size",
        check: "octet_length(integration_name) BETWEEN 1 AND 40"
    end
  end

  cedar do
    internal [:read, :issue]
  end

  actions do
    defaults [:read]

    create :issue do
      accept [:digest, :source_vm_id, :integration_id, :integration_name, :expires_at]
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :digest, :binary, allow_nil?: false, public?: false, sensitive?: true
    attribute :source_vm_id, :uuid, allow_nil?: false
    attribute :integration_id, :uuid, allow_nil?: false

    attribute :integration_name, :string,
      allow_nil?: false,
      constraints: [min_length: 1, max_length: 40]

    attribute :expires_at, :utc_datetime_usec, allow_nil?: false
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :source_vm, Marshall.Compute.VirtualMachine,
      source_attribute: :source_vm_id,
      define_attribute?: false,
      attribute_type: :uuid

    belongs_to :integration, Marshall.Galileo.Integration,
      source_attribute: :integration_id,
      define_attribute?: false,
      attribute_type: :uuid
  end

  identities do
    identity :digest, [:digest]
  end
end
