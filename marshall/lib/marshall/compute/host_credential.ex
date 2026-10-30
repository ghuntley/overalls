# @cc [owner:ghuntley,label:security] host-credential-secret-free-audit
# Credential secrets MUST be encrypted, excluded from default decryption and
# omitted in both plaintext and ciphertext form from audit versions. Revocation
# MUST archive authority while retaining secret-free transition history.
defmodule Marshall.Compute.HostCredential do
  @moduledoc "Encrypted host credentials. Revocation archives the row and preserves its audit history."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Compute,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshCloak, AshArchival.Resource, AshPaperTrail.Resource]

  postgres do
    table "compute_host_credentials"
    repo Marshall.Repo
    identity_wheres_to_sql one_active_per_host: "archived_at IS NULL"
  end

  cedar do
    internal [:read, :history, :issue, :revoke]
  end

  cloak do
    vault(Marshall.Vault)
    attributes([:secret])
    decrypt_by_default([])
  end

  archive do
    exclude_read_actions([:history])
  end

  paper_trail do
    metadata :actor_kind, :atom, allow_nil?: true
    metadata :actor_id, :uuid, allow_nil?: true
    change_tracking_mode :changes_only
    store_action_name? true
    ignore_attributes [:secret, :encrypted_secret, :inserted_at, :updated_at]
    sensitive_attributes :ignore
    version_extensions authorizers: [Marshall.Authorization.AshAuthorizer]
    mixin Marshall.Authorization.VersionMapping
  end

  actions do
    defaults [:read]
    read :history

    create :issue do
      accept [:host_id, :secret, :expires_at]
    end

    destroy :revoke
  end

  attributes do
    uuid_primary_key :id

    attribute :secret, :string,
      allow_nil?: false,
      sensitive?: true,
      constraints: [min_length: 43, max_length: 43]

    attribute :expires_at, :utc_datetime_usec, allow_nil?: false
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :host, Marshall.Compute.Host, allow_nil?: false
  end

  identities do
    identity :one_active_per_host, [:host_id], where: expr(is_nil(archived_at))
  end
end
