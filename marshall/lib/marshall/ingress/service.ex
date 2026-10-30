defmodule Marshall.Ingress.Service do
  @moduledoc "Revocable role-bound Audi service identity, independent of user identity."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Ingress,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshPaperTrail.Resource]

  postgres do
    table "ingress_services"
    repo Marshall.Repo

    check_constraints do
      check_constraint :role, "ingress_service_binding",
        check: "(role = 'dns' AND host_id IS NULL) OR (role = 'gateway' AND host_id IS NOT NULL)"

      check_constraint :generation, "ingress_service_generation", check: "generation > 0"

      check_constraint :ssh_host_key, "ingress_gateway_host_key",
        check: "ssh_host_key IS NULL OR (role = 'gateway' AND enabled)"

      check_constraint :addresses, "ingress_gateway_addresses",
        check: "cardinality(addresses) <= 8 AND (role = 'gateway' OR cardinality(addresses) = 0)"
    end
  end

  cedar do
    internal [
      :read,
      :catalog,
      :record,
      :rotate,
      :record_host_key,
      :publish_host_key,
      :configure,
      :ensure,
      :open_connection,
      :disable,
      :identity
    ]
  end

  paper_trail do
    metadata :actor_kind, :atom, allow_nil?: true
    metadata :actor_id, :uuid, allow_nil?: true
    sensitive_attributes :ignore
    change_tracking_mode :changes_only
    store_action_name? true
    ignore_attributes [:inserted_at, :updated_at, :token_hash]
    version_extensions authorizers: [Marshall.Authorization.AshAuthorizer]
    mixin Marshall.Authorization.VersionMapping
  end

  actions do
    defaults [:read]

    action :catalog, :map do
      argument :token, :string, allow_nil?: false, sensitive?: true, constraints: [max_length: 80]
      run Marshall.Ingress.Catalog
    end

    create :record do
      accept [:name, :role, :host_id, :token_hash, :addresses, :relay_address, :relay_port]
    end

    update :rotate do
      accept [
        :token_hash,
        :generation,
        :enabled,
        :ssh_host_key,
        :addresses,
        :relay_address,
        :relay_port
      ]
    end

    update :record_host_key do
      accept [:ssh_host_key]
    end

    action :publish_host_key, :map do
      argument :token, :string, allow_nil?: false, sensitive?: true, constraints: [max_length: 80]
      argument :public_key, :string, allow_nil?: false, constraints: [max_length: 128]
      run {Marshall.Ingress.Services, operation: :publish_host_key}
    end

    for action <- [:configure, :ensure] do
      action action, :map do
        argument :name, :string, allow_nil?: false, constraints: [min_length: 1, max_length: 128]
        argument :role, :atom, allow_nil?: false, constraints: [one_of: [:dns, :gateway]]
        argument :host_id, :uuid
        argument :relay_address, :string, constraints: [max_length: 13]

        argument :relay_port, :integer,
          default: 9445,
          allow_nil?: false,
          constraints: [min: 1, max: 65_535]

        argument :addresses, {:array, :string},
          allow_nil?: false,
          default: [],
          constraints: [max_length: 8, items: [max_length: 45]]

        argument :token, :string,
          allow_nil?: false,
          sensitive?: true,
          constraints: [max_length: 80]

        run {Marshall.Ingress.Services, operation: action}
      end
    end

    action :open_connection, :map do
      argument :service_token, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [max_length: 80]

      argument :purpose, :atom, allow_nil?: false, constraints: [one_of: [:ssh, :web, :editor]]
      argument :label, :string, allow_nil?: false, constraints: [max_length: 80, trim?: false]

      argument :app_port, :integer,
        default: 0,
        allow_nil?: false,
        constraints: [min: 0, max: 9999]

      argument :public_key, :string,
        sensitive?: true,
        constraints: [max_length: 4096, trim?: false]

      argument :cookie, :string, sensitive?: true, constraints: [max_length: 80, trim?: false]
      run Marshall.Ingress.Open
    end

    action :disable, :map do
      argument :id, :uuid, allow_nil?: false
      run {Marshall.Ingress.Services, operation: :disable}
    end

    action :identity, :map do
      argument :token, :string, allow_nil?: false, sensitive?: true, constraints: [max_length: 80]
      run {Marshall.Ingress.Services, operation: :identity}
    end
  end

  changes do
    # Control hints (ADR-0140): emitted in the action's transaction.
    change {Marshall.Control.Hints.Change, kind: :service, from: :id},
      on: [:create, :update, :destroy],
      where: [action_is([:rotate])]
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false
    attribute :role, :atom, allow_nil?: false, constraints: [one_of: [:dns, :gateway]]
    attribute :token_hash, :binary, allow_nil?: false, sensitive?: true
    attribute :enabled, :boolean, allow_nil?: false, default: true
    attribute :generation, :integer, allow_nil?: false, default: 1, constraints: [min: 1]
    attribute :ssh_host_key, :string, constraints: [max_length: 128]
    attribute :relay_address, :string, constraints: [max_length: 13]

    attribute :relay_port, :integer,
      default: 9445,
      allow_nil?: false,
      constraints: [min: 1, max: 65_535]

    attribute :addresses, {:array, :string},
      allow_nil?: false,
      default: [],
      constraints: [max_length: 8, items: [max_length: 45]]

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :host, Marshall.Compute.Host
  end

  identities do
    identity :name, [:name]
    identity :token_hash, [:token_hash]
  end
end
