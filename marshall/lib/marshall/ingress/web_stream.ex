defmodule Marshall.Ingress.WebStream do
  @moduledoc "Revocable five-second web authority bound to execution and policy."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Ingress,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshPaperTrail.Resource, AshOban]

  postgres do
    table "ingress_web_streams"
    repo Marshall.Repo

    references do
      reference :placement, match_with: [vm_id: :vm_id, host_id: :host_id]
    end

    check_constraints do
      check_constraint :port, "ingress_web_stream_port", check: "port BETWEEN 1 AND 65535"

      check_constraint :app_port, "ingress_web_stream_app_port",
        check: "app_port = 0 OR app_port BETWEEN 3000 AND 9999"

      check_constraint :policy_revision, "ingress_web_stream_versions",
        check:
          "policy_revision > 0 AND service_generation > 0 AND execution_epoch > 0 AND generation > 0"

      check_constraint :token_hash, "ingress_web_stream_hash",
        check: "octet_length(token_hash) = 32"

      check_constraint :peer_integration_id, "ingress_web_stream_peer_binding",
        check:
          "(peer_integration_id IS NULL AND peer_source_vm_id IS NULL) OR (peer_integration_id IS NOT NULL AND peer_source_vm_id IS NOT NULL)"
    end

    custom_indexes do
      index [:service_id, :expires_at]
      index [:expires_at, :id]
    end
  end

  # @cc [owner:ghuntley,label:security] ingress-web-stream-binding
  # Stream authority MUST bind immutable execution, policy revision and app port.
  # Private browser streams retain credential identity; peer streams instead
  # retain both source VM and integration identity for fresh policy checks.
  # Renewal MUST NOT revive expired/closed streams or migrate their binding.
  cedar do
    internal [
      :read,
      :record,
      :renew,
      :close,
      :purge,
      :prune,
      :open_web,
      :open_peer_web,
      :renew_web,
      :close_web
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
        worker_module_name Marshall.Ingress.Workers.PruneWeb
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
        :vm_id,
        :host_id,
        :placement_id,
        :execution_epoch,
        :generation,
        :label,
        :app_port,
        :port,
        :policy_revision,
        :credential_id,
        :peer_integration_id,
        :peer_source_vm_id,
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
      run Marshall.Ingress.WebRetention
    end

    action :open_web, :map do
      argument :service_token, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [max_length: 80]

      argument :label, :string, allow_nil?: false, constraints: [max_length: 63, trim?: false]
      argument :app_port, :integer, allow_nil?: false, constraints: [min: 0, max: 9999]
      argument :cookie, :string, sensitive?: true, constraints: [max_length: 80, trim?: false]
      run {Marshall.Ingress.WebStreams, operation: :open}
    end

    action :open_peer_web, :map do
      argument :service_token, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [max_length: 80]

      argument :peer_token, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [max_length: 80, trim?: false]

      argument :label, :string, allow_nil?: false, constraints: [max_length: 63, trim?: false]
      argument :app_port, :integer, allow_nil?: false, constraints: [min: 0, max: 0]
      run {Marshall.Ingress.WebStreams, operation: :open_peer}
    end

    for name <- [:renew_web, :close_web] do
      action name, :map do
        argument :service_token, :string,
          allow_nil?: false,
          sensitive?: true,
          constraints: [max_length: 80]

        argument :stream_token, :string,
          allow_nil?: false,
          sensitive?: true,
          constraints: [max_length: 80]

        run {Marshall.Ingress.WebStreams, operation: name}
      end
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :token_hash, :binary, allow_nil?: false, sensitive?: true

    for field <- [:service_generation, :execution_epoch, :generation, :policy_revision] do
      attribute field, :integer, allow_nil?: false, constraints: [min: 1]
    end

    attribute :label, :string, allow_nil?: false, constraints: [max_length: 63]
    attribute :app_port, :integer, allow_nil?: false, constraints: [min: 0, max: 9999]
    attribute :port, :integer, allow_nil?: false, constraints: [min: 1, max: 65535]
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
    belongs_to :credential, Marshall.Ingress.WebCredential

    belongs_to :peer_integration, Marshall.Galileo.Integration,
      source_attribute: :peer_integration_id

    belongs_to :peer_source_vm, Marshall.Compute.VirtualMachine,
      source_attribute: :peer_source_vm_id
  end

  identities do
    identity :token_hash, [:token_hash]
  end
end
