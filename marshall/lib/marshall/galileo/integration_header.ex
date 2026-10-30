defmodule Marshall.Galileo.IntegrationHeader do
  @moduledoc "One injected header per integration; the value is Cloak-encrypted at rest."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Galileo,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshCloak]

  postgres do
    table "galileo_integration_headers"
    repo Marshall.Repo

    check_constraints do
      check_constraint :kind, "valid_galileo_header_kind",
        check: "kind IN ('static', 'bearer', 'basic')"
    end
  end

  cedar do
    internal [:read, :record, :remove]
  end

  cloak do
    vault(Marshall.Vault)
    attributes([:value])
    decrypt_by_default([])
  end

  actions do
    defaults [:read]

    create :record do
      accept [:integration_id, :kind, :name, :value]
    end

    destroy :remove
  end

  attributes do
    uuid_primary_key :id
    attribute :kind, :atom, allow_nil?: false, constraints: [one_of: [:static, :bearer, :basic]]
    attribute :name, :string, allow_nil?: false, constraints: [min_length: 1, max_length: 64]

    attribute :value, :string,
      allow_nil?: false,
      sensitive?: true,
      constraints: [min_length: 1, max_length: 4096]

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :integration, Marshall.Galileo.Integration, allow_nil?: false
  end

  identities do
    identity :one_per_name, [:integration_id, :name]
  end
end
