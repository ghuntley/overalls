defmodule Marshall.Ingress.WebLogin do
  @moduledoc "Single-use browser authorization exchange bound to gateway execution and state proof."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Ingress,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshPaperTrail.Resource]

  postgres do
    table "ingress_web_logins"
    repo Marshall.Repo

    references do
      reference :placement, match_with: [vm_id: :vm_id, host_id: :host_id]
    end

    check_constraints do
      check_constraint :status, "ingress_web_login_status",
        check: "status IN ('pending', 'approved', 'consumed')"

      check_constraint :app_port, "ingress_web_login_port",
        check: "app_port = 0 OR app_port BETWEEN 3000 AND 9999"

      check_constraint :generation, "ingress_web_login_binding",
        check: "generation > 0 AND execution_epoch > 0 AND service_generation > 0"

      check_constraint :state_hash, "ingress_web_login_hashes",
        check:
          "octet_length(state_hash) = 32 AND octet_length(token_hash) = 32 AND (code_hash IS NULL OR octet_length(code_hash) = 32)"

      check_constraint :status, "ingress_web_login_approval",
        check:
          "(status = 'pending' AND code_hash IS NULL AND user_id IS NULL AND login_jti IS NULL) OR (status IN ('approved', 'consumed') AND code_hash IS NOT NULL AND user_id IS NOT NULL AND login_jti IS NOT NULL)"
    end

    custom_indexes do
      index [:service_id, :expires_at]
      index [:expires_at, :id]
    end
  end

  # @cc [owner:ghuntley,label:security] ingress-browser-exchange-internal-state
  # Raw mutations MUST remain internal. Coordinators MUST serialize pending ->
  # approved -> consumed with fresh service/execution and stored-login checks.
  # Only hashes of ticket, code and browser state may persist. A pending or
  # approved record MUST NOT independently authorize guest traffic.
  cedar do
    control_plane "provision", [:authorize_login]
    internal [:read, :begin_login, :exchange_login, :record, :approve, :consume, :purge]
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

    action :begin_login, :map do
      argument :service_token, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [max_length: 80]

      argument :label, :string, allow_nil?: false, constraints: [max_length: 63, trim?: false]

      argument :state_digest, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [max_length: 64, trim?: false]

      argument :app_port, :integer, allow_nil?: false, constraints: [min: 0, max: 9999]
      run {Marshall.Ingress.WebLogins, operation: :begin}
    end

    action :authorize_login, :map do
      argument :ticket, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [max_length: 80]

      argument :login_token, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [max_length: 8192]

      run {Marshall.Ingress.WebLogins, operation: :authorize}
    end

    action :exchange_login, :map do
      for name <- [:service_token, :ticket, :code, :state] do
        argument name, :string,
          allow_nil?: false,
          sensitive?: true,
          constraints: [max_length: 80, trim?: false]
      end

      run {Marshall.Ingress.WebLogins, operation: :exchange}
    end

    create :record do
      accept [
        :token_hash,
        :state_hash,
        :service_id,
        :service_generation,
        :vm_id,
        :host_id,
        :placement_id,
        :execution_epoch,
        :generation,
        :label,
        :app_port,
        :expires_at
      ]
    end

    update :approve do
      accept [:code_hash, :user_id, :login_jti, :expires_at]
      change set_attribute(:status, :approved)
    end

    update :consume do
      accept []
      change set_attribute(:status, :consumed)
    end

    destroy :purge
  end

  attributes do
    uuid_primary_key :id

    for name <- [:token_hash, :state_hash] do
      attribute name, :binary, allow_nil?: false, sensitive?: true
    end

    attribute :code_hash, :binary, sensitive?: true
    attribute :login_jti, :string, sensitive?: true, constraints: [max_length: 256]

    attribute :status, :atom,
      allow_nil?: false,
      default: :pending,
      constraints: [one_of: [:pending, :approved, :consumed]]

    for name <- [:service_generation, :execution_epoch, :generation] do
      attribute name, :integer, allow_nil?: false, constraints: [min: 1]
    end

    attribute :label, :string, allow_nil?: false, constraints: [max_length: 63]
    attribute :app_port, :integer, allow_nil?: false, constraints: [min: 0, max: 9999]
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :service, Marshall.Ingress.Service, allow_nil?: false
    belongs_to :vm, Marshall.Compute.VirtualMachine, allow_nil?: false
    belongs_to :host, Marshall.Compute.Host, allow_nil?: false
    belongs_to :placement, Marshall.Compute.WorkloadPlacement, allow_nil?: false
    belongs_to :user, Marshall.Accounts.User
  end

  identities do
    identity :token_hash, [:token_hash]
    identity :code_hash, [:code_hash]
  end
end
