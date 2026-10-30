defmodule Marshall.Ingress.WebCredential do
  @moduledoc "Browser cookie identity; every stream still requires fresh short-lived authority."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Ingress,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshPaperTrail.Resource]

  postgres do
    table "ingress_web_credentials"
    repo Marshall.Repo

    check_constraints do
      check_constraint :app_port, "ingress_web_credential_port",
        check: "app_port = 0 OR app_port BETWEEN 3000 AND 9999"

      check_constraint :service_generation, "ingress_web_credential_generation",
        check: "service_generation > 0"

      check_constraint :token_hash, "ingress_web_credential_hash",
        check: "octet_length(token_hash) = 32"
    end

    custom_indexes do
      index [:expires_at, :id]
      index [:service_id, :expires_at]
    end
  end

  # @cc [owner:ghuntley,label:security] ingress-web-cookie-not-stream-authority
  # A cookie MUST bind the authenticated user, original stored login, VM/app and
  # gateway generation. The raw token MUST never persist. Cookie presence alone
  # MUST NOT authorize a request: stream admission/renewal must recheck stored
  # login, current membership, policy and execution. Revoked cookies cannot revive.
  cedar do
    internal [:read, :record, :revoke, :purge]
  end

  paper_trail do
    metadata :actor_kind, :atom, allow_nil?: true
    metadata :actor_id, :uuid, allow_nil?: true
    reference_source? false
    change_tracking_mode :changes_only
    store_action_name? true
    ignore_actions [:purge]
    sensitive_attributes :ignore
    ignore_attributes [:inserted_at, :updated_at]
    version_extensions authorizers: [Marshall.Authorization.AshAuthorizer]
    mixin Marshall.Authorization.VersionMapping
  end

  actions do
    defaults [:read]

    create :record do
      accept [
        :token_hash,
        :user_id,
        :login_jti,
        :vm_id,
        :service_id,
        :service_generation,
        :label,
        :app_port,
        :expires_at
      ]
    end

    update :revoke do
      accept [:revoked_at]
    end

    destroy :purge
  end

  attributes do
    uuid_primary_key :id
    attribute :token_hash, :binary, allow_nil?: false, sensitive?: true

    attribute :login_jti, :string,
      allow_nil?: false,
      sensitive?: true,
      constraints: [max_length: 256]

    attribute :service_generation, :integer, allow_nil?: false, constraints: [min: 1]
    attribute :label, :string, allow_nil?: false, constraints: [max_length: 63]
    attribute :app_port, :integer, allow_nil?: false, constraints: [min: 0, max: 9999]
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false
    attribute :revoked_at, :utc_datetime_usec
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    has_many :streams, Marshall.Ingress.WebStream, destination_attribute: :credential_id
    belongs_to :user, Marshall.Accounts.User, allow_nil?: false
    belongs_to :vm, Marshall.Compute.VirtualMachine, allow_nil?: false
    belongs_to :service, Marshall.Ingress.Service, allow_nil?: false
  end

  identities do
    identity :token_hash, [:token_hash]
  end
end
