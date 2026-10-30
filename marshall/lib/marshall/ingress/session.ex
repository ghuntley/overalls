defmodule Marshall.Ingress.Session do
  @moduledoc "Short-lived Audi SSH authority pinned to an immutable key and execution binding."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Ingress,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshPaperTrail.Resource, AshOban]

  postgres do
    table "ingress_sessions"
    repo Marshall.Repo

    references do
      reference :placement, match_with: [vm_id: :vm_id, host_id: :host_id]
    end

    check_constraints do
      check_constraint :execution_epoch, "ingress_session_epoch", check: "execution_epoch > 0"
      check_constraint :generation, "ingress_session_generation", check: "generation > 0"

      check_constraint :service_generation, "ingress_session_service_generation",
        check: "service_generation > 0"
    end

    custom_indexes do
      index [:service_id, :expires_at]
      index [:expires_at, :id]
    end
  end

  cedar do
    internal [
      :read,
      :record,
      :renew,
      :close,
      :purge,
      :prune,
      :ssh_key_status,
      :open_ssh,
      :renew_ssh,
      :close_ssh
    ]
  end

  paper_trail do
    metadata :actor_kind, :atom, allow_nil?: true
    metadata :actor_id, :uuid, allow_nil?: true
    reference_source? false
    change_tracking_mode :changes_only
    store_action_name? true
    ignore_actions [:renew, :purge]
    ignore_attributes [:token_hash, :inserted_at, :updated_at]
    sensitive_attributes :ignore
    version_extensions authorizers: [Marshall.Authorization.AshAuthorizer]
    mixin Marshall.Authorization.VersionMapping
  end

  oban do
    scheduled_actions do
      schedule :prune, "*/10 * * * *" do
        action :prune
        queue :maintenance
        max_attempts 5
        worker_module_name Marshall.Ingress.Workers.PruneSessions
        actor_persister :none
        default_actor %Marshall.Authorization.SystemActor{purpose: :compute}
      end
    end
  end

  actions do
    defaults [:read]

    create :record do
      accept [
        :token_hash,
        :service_id,
        :service_generation,
        :key_id,
        :vm_id,
        :host_id,
        :placement_id,
        :execution_epoch,
        :generation,
        :label,
        :expires_at
      ]
    end

    update :renew do
      accept [:expires_at]
    end

    update :close do
      accept [:closed_at]
    end

    destroy :purge

    action :prune, :integer do
      argument :continuation, :uuid
      run Marshall.Ingress.Retention
    end

    action :ssh_key_status, :map do
      argument :service_token, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [max_length: 80]

      argument :public_key, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [max_length: 4096, trim?: false]

      run {Marshall.Ingress.Sessions, operation: :key_status}
    end

    action :open_ssh, :map do
      argument :service_token, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [max_length: 80]

      argument :public_key, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [max_length: 4096, trim?: false]

      argument :label, :string, allow_nil?: false, constraints: [max_length: 63, trim?: false]
      run {Marshall.Ingress.Sessions, operation: :open}
    end

    for name <- [:renew_ssh, :close_ssh] do
      action name, :map do
        argument :service_token, :string,
          allow_nil?: false,
          sensitive?: true,
          constraints: [max_length: 80]

        argument :session_token, :string,
          allow_nil?: false,
          sensitive?: true,
          constraints: [max_length: 80]

        run {Marshall.Ingress.Sessions, operation: name}
      end
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :token_hash, :binary, allow_nil?: false, sensitive?: true
    attribute :service_generation, :integer, allow_nil?: false, constraints: [min: 1]
    attribute :execution_epoch, :integer, allow_nil?: false, constraints: [min: 1]
    attribute :generation, :integer, allow_nil?: false, constraints: [min: 1]
    attribute :label, :string, allow_nil?: false
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false
    attribute :closed_at, :utc_datetime_usec
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :service, Marshall.Ingress.Service, allow_nil?: false
    belongs_to :key, Marshall.SSH.Key, allow_nil?: false
    belongs_to :vm, Marshall.Compute.VirtualMachine, allow_nil?: false
    belongs_to :host, Marshall.Compute.Host, allow_nil?: false
    belongs_to :placement, Marshall.Compute.WorkloadPlacement, allow_nil?: false
  end

  identities do
    identity :token_hash, [:token_hash]
  end
end
