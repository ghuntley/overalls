defmodule Marshall.Editor.Lease do
  @moduledoc "Thirty-second editor authority pinned to one account and VM execution."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Editor,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshPaperTrail.Resource, AshOban]

  postgres do
    table "editor_leases"
    repo Marshall.Repo

    references do
      reference :placement, match_with: [vm_id: :vm_id, host_id: :host_id]
    end

    check_constraints do
      check_constraint :editor_protocol, "editor_lease_protocol", check: "editor_protocol = 1"
      check_constraint :uid, "editor_lease_uid", check: "uid BETWEEN 200000 AND 999999"
      check_constraint :token_hash, "editor_lease_hash", check: "octet_length(token_hash) = 32"

      check_constraint :generation, "editor_lease_generations",
        check: "generation > 0 AND execution_epoch > 0 AND service_generation > 0"

      check_constraint :editor_commit, "editor_lease_release",
        check: "editor_commit ~ '^[a-f0-9]{40}$' AND editor_release ~ '^[a-f0-9]{64}$'"
    end

    custom_indexes do
      index [:service_id, :expires_at]
      index [:expires_at, :id]
    end
  end

  cedar do
    control_plane "admin_read", [:audit]

    internal [
      :read,
      :record,
      :renew,
      :close,
      :purge,
      :prune,
      :open_editor,
      :renew_editor,
      :close_editor
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
    ignore_attributes [:inserted_at, :updated_at, :username, :editor_origin]
    version_extensions authorizers: [Marshall.Authorization.AshAuthorizer]
    mixin Marshall.Authorization.VersionMapping
  end

  oban do
    scheduled_actions do
      schedule :prune, "*/10 * * * *" do
        action :prune
        queue :maintenance
        max_attempts 5
        worker_module_name Marshall.Editor.Workers.Prune
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
        :connection_session_id,
        :label,
        :credential_id,
        :user_id,
        :guest_account_id,
        :uid,
        :username,
        :editor_protocol,
        :editor_commit,
        :editor_release,
        :editor_origin,
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
      run Marshall.Editor.Retention
    end

    action :audit, :map do
      run Marshall.Editor.Audit
    end

    action :open_editor, :map do
      argument :service_token, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [max_length: 80, trim?: false]

      argument :label, :string, allow_nil?: false, constraints: [max_length: 63, trim?: false]

      argument :cookie, :string,
        sensitive?: true,
        constraints: [max_length: 80, trim?: false]

      run {Marshall.Editor.Authority, operation: :open_editor}
    end

    for name <- [:renew_editor, :close_editor] do
      action name, :map do
        argument :service_token, :string,
          allow_nil?: false,
          sensitive?: true,
          constraints: [max_length: 80, trim?: false]

        argument :stream_token, :string,
          allow_nil?: false,
          sensitive?: true,
          constraints: [max_length: 80, trim?: false]

        run {Marshall.Editor.Authority, operation: name}
      end
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :token_hash, :binary, allow_nil?: false, sensitive?: true
    attribute :connection_session_id, :uuid, allow_nil?: false

    for name <- [:service_generation, :execution_epoch, :generation] do
      attribute name, :integer, allow_nil?: false, constraints: [min: 1]
    end

    attribute :label, :string, allow_nil?: false, constraints: [max_length: 63]
    attribute :uid, :integer, allow_nil?: false, constraints: [min: 200_000, max: 999_999]

    attribute :username, :string,
      allow_nil?: false,
      sensitive?: true,
      constraints: [max_length: 32]

    attribute :editor_protocol, :integer, allow_nil?: false, constraints: [min: 1, max: 1]
    attribute :editor_commit, :string, allow_nil?: false, constraints: [max_length: 40]
    attribute :editor_release, :string, allow_nil?: false, constraints: [max_length: 64]
    attribute :editor_origin, :string, allow_nil?: false, constraints: [max_length: 261]
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
    belongs_to :credential, Marshall.Editor.Credential, allow_nil?: false
    belongs_to :user, Marshall.Accounts.User, allow_nil?: false
    belongs_to :guest_account, Marshall.Accounts.GuestAccount, allow_nil?: false
  end

  identities do
    identity :token_hash, [:token_hash]
  end
end
