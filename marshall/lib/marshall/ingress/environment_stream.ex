defmodule Marshall.Ingress.EnvironmentStream do
  @moduledoc "Expiring parent listener permission, independent of inner user authentication."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Ingress,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshPaperTrail.Resource, AshOban]

  @services [:control_https, :porsche_ssh, :audi_https, :audi_ssh]
  @binding [
    :service_id,
    :service_generation,
    :vm_id,
    :host_id,
    :placement_id,
    :execution_epoch,
    :generation,
    :environment_generation,
    :host_session_id,
    :host_epoch,
    :label,
    :nested_service,
    :host_key,
    :peer_fingerprint
  ]

  postgres do
    table "ingress_environment_streams"
    repo Marshall.Repo

    references do
      reference :placement, match_with: [vm_id: :vm_id, host_id: :host_id]
    end

    check_constraints do
      check_constraint :generation, "ingress_environment_stream_revisions",
        check:
          "generation > 0 AND execution_epoch > 0 AND service_generation > 0 AND environment_generation > 0 AND host_epoch > 0"

      check_constraint :token_hash, "ingress_environment_stream_hash",
        check: "octet_length(token_hash) = 32"

      check_constraint :nested_service, "ingress_environment_stream_service",
        check: "nested_service IN ('control_https', 'porsche_ssh', 'audi_https', 'audi_ssh')"
    end

    custom_indexes do
      index [:service_id, :expires_at]
      index [:expires_at, :id]
    end
  end

  # @cc [owner:ghuntley,label:security] inception-stream-immutable-binding
  # Renewal MUST change only expiry, retaining gateway, execution, host session,
  # namespace generation, fixed service and SSH identities. Closed or expired
  # rows MUST NOT revive. Raw resource mutations MUST remain internal only.
  cedar do
    internal [
      :read,
      :record,
      :renew,
      :close,
      :purge,
      :prune,
      :open_nested,
      :renew_nested,
      :close_nested
    ]
  end

  paper_trail do
    metadata :actor_kind, :atom, allow_nil?: true
    metadata :actor_id, :uuid, allow_nil?: true
    reference_source? false
    change_tracking_mode :changes_only
    store_action_name? true
    ignore_actions [:renew, :purge]
    sensitive_attributes :ignore
    ignore_attributes [:inserted_at, :updated_at]
    version_extensions authorizers: [Marshall.Authorization.AshAuthorizer]
    mixin Marshall.Authorization.VersionMapping
  end

  oban do
    scheduled_actions do
      schedule :prune, "*/10 * * * *" do
        action :prune
        queue :maintenance
        max_attempts 5
        worker_module_name Marshall.Ingress.Workers.PruneEnvironmentStreams
        actor_persister :none
        default_actor %Marshall.Authorization.SystemActor{purpose: :compute}
      end
    end
  end

  actions do
    defaults [:read]

    create :record do
      accept [:token_hash, :expires_at] ++ @binding
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
      run Marshall.Ingress.EnvironmentStreamRetention
    end

    action :open_nested, :map do
      argument :service_token, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [max_length: 80]

      argument :label, :string, allow_nil?: false, constraints: [max_length: 63, trim?: false]
      argument :nested_service, :atom, allow_nil?: false, constraints: [one_of: @services]
      argument :public_key, :string, constraints: [max_length: 16384, trim?: false]
      run {Marshall.Ingress.EnvironmentStreams, operation: :open}
    end

    for name <- [:renew_nested, :close_nested] do
      action name, :map do
        argument :service_token, :string,
          allow_nil?: false,
          sensitive?: true,
          constraints: [max_length: 80]

        argument :stream_token, :string,
          allow_nil?: false,
          sensitive?: true,
          constraints: [max_length: 80, trim?: false]

        run {Marshall.Ingress.EnvironmentStreams, operation: name}
      end
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :token_hash, :binary, allow_nil?: false, sensitive?: true

    for name <- [
          :service_generation,
          :execution_epoch,
          :generation,
          :environment_generation,
          :host_epoch
        ] do
      attribute name, :integer, allow_nil?: false, constraints: [min: 1]
    end

    attribute :host_session_id, :uuid, allow_nil?: false
    attribute :label, :string, allow_nil?: false, constraints: [max_length: 63]
    attribute :nested_service, :atom, allow_nil?: false, constraints: [one_of: @services]
    attribute :host_key, :string
    attribute :peer_fingerprint, :string
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false
    attribute :closed_at, :utc_datetime_usec
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :service, Marshall.Ingress.Service, allow_nil?: false
    belongs_to :vm, Marshall.Compute.VirtualMachine, allow_nil?: false
    belongs_to :host, Marshall.Compute.Host, allow_nil?: false
    belongs_to :placement, Marshall.Compute.WorkloadPlacement, allow_nil?: false
  end

  identities do
    identity :token_hash, [:token_hash]
  end
end
