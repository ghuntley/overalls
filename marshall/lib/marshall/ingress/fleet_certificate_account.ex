defmodule Marshall.Ingress.FleetCertificateAccount do
  @moduledoc "Encrypted ACME account key for the configured fleet issuer."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Ingress,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshCloak, AshPaperTrail.Resource]

  postgres do
    table "ingress_fleet_certificate_accounts"
    repo Marshall.Repo

    custom_indexes do
      index [:issuer_url], unique: true
    end
  end

  cedar do
    internal [:read, :register]
  end

  cloak do
    vault(Marshall.Vault)
    attributes([:private_key])
    decrypt_by_default([])
  end

  paper_trail do
    metadata :actor_kind, :atom, allow_nil?: true
    metadata :actor_id, :uuid, allow_nil?: true
    sensitive_attributes :ignore
    change_tracking_mode :changes_only
    store_action_name? true
    ignore_attributes [:private_key, :encrypted_private_key, :inserted_at]
    version_extensions authorizers: [Marshall.Authorization.AshAuthorizer]
    mixin Marshall.Authorization.VersionMapping
  end

  actions do
    defaults [:read]

    create :register do
      accept [:issuer_url, :private_key, :thumbprint]
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :issuer_url, :string, allow_nil?: false, constraints: [max_length: 2048]
    attribute :private_key, :binary, allow_nil?: false, sensitive?: true
    attribute :thumbprint, :string, allow_nil?: false, constraints: [max_length: 43]
    create_timestamp :inserted_at
  end
end
