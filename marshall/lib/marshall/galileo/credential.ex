defmodule Marshall.Galileo.Credential do
  @moduledoc "Dedicated Galileo credential: only a high-entropy secret digest is retained."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Galileo,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshPaperTrail.Resource]

  postgres do
    table "galileo_credentials"
    repo Marshall.Repo
    identity_wheres_to_sql one_active_per_host: "revoked_at IS NULL"
  end

  cedar do
    internal [:read, :issue, :revoke]
  end

  paper_trail do
    metadata :actor_kind, :atom, allow_nil?: true
    metadata :actor_id, :uuid, allow_nil?: true
    change_tracking_mode :changes_only
    store_action_name? true
    ignore_attributes [:secret_hash, :inserted_at, :updated_at]
    sensitive_attributes :ignore
    version_extensions authorizers: [Marshall.Authorization.AshAuthorizer]
    mixin Marshall.Authorization.VersionMapping
  end

  actions do
    defaults [:read]

    create :issue do
      accept [:host_id, :secret_hash, :expires_at]
    end

    update :revoke do
      accept [:revoked_at]
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :secret_hash, :binary, sensitive?: true, allow_nil?: false
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false
    attribute :revoked_at, :utc_datetime_usec
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :host, Marshall.Compute.Host, allow_nil?: false
  end

  identities do
    identity :one_active_per_host, [:host_id], where: expr(is_nil(revoked_at))
  end
end
