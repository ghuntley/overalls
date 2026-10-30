defmodule Marshall.Ingress.Environment do
  @moduledoc "Immutable parent-owned Inception identity; publication never grants stream authority."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Ingress,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshPaperTrail.Resource]

  postgres do
    table "ingress_environments"
    repo Marshall.Repo

    check_constraints do
      check_constraint :generation, "ingress_environment_generation", check: "generation > 0"
    end
  end

  cedar do
    internal [:read, :current_ssh, :record, :change_policy]
  end

  paper_trail do
    metadata :actor_kind, :atom, allow_nil?: true
    metadata :actor_id, :uuid, allow_nil?: true
    sensitive_attributes :ignore
    change_tracking_mode :changes_only
    store_action_name? true
    ignore_attributes [:inserted_at, :updated_at]
    version_extensions authorizers: [Marshall.Authorization.AshAuthorizer]
    mixin Marshall.Authorization.VersionMapping
  end

  actions do
    defaults [:read]

    action :current_ssh, :map do
      argument :label, :string, allow_nil?: false, constraints: [max_length: 63, trim?: false]

      argument :nested_service, :atom,
        allow_nil?: false,
        constraints: [one_of: [:porsche_ssh, :audi_ssh]]

      run Marshall.Ingress.EnvironmentDiscovery
    end

    create :record do
      accept [:vm_id, :label]
    end

    update :change_policy do
      accept [:enabled, :generation]
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :label, :string, allow_nil?: false, constraints: [min_length: 34, max_length: 63]
    attribute :enabled, :boolean, allow_nil?: false, default: true
    attribute :generation, :integer, allow_nil?: false, default: 1, constraints: [min: 1]
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :vm, Marshall.Compute.VirtualMachine, allow_nil?: false
  end

  identities do
    identity :vm, [:vm_id]
    identity :label, [:label]
  end
end
