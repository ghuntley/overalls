defmodule Marshall.SSH.Key do
  @moduledoc "An audited, revocable registration of one canonical user public key."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.SSH,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshArchival.Resource, AshPaperTrail.Resource]

  postgres do
    table "ssh_keys"
    repo Marshall.Repo
    identity_wheres_to_sql active_fingerprint: "archived_at IS NULL"
  end

  cedar do
    control_plane "admin_accounts", [:revoke_for_admin]
    control_plane "admin_read", [:list_for_admin]

    control_plane "provision", [:list_for_user, :add_for_user, :rename_for_user, :remove_for_user]

    internal [:read, :history, :register, :relabel, :revoke]
  end

  archive do
    exclude_read_actions([:history])
  end

  paper_trail do
    metadata :actor_kind, :atom, allow_nil?: true
    metadata :actor_id, :uuid, allow_nil?: true
    sensitive_attributes :ignore
    change_tracking_mode :changes_only
    store_action_name? true
    ignore_attributes [:inserted_at, :updated_at, :public_key, :label]
    version_extensions authorizers: [Marshall.Authorization.AshAuthorizer]
    mixin Marshall.Authorization.VersionMapping
  end

  actions do
    defaults [:read]
    read :history

    create :register do
      accept [:user_id, :label, :algorithm, :public_key, :fingerprint]
    end

    update :relabel do
      accept [:label]
    end

    destroy :revoke

    action :list_for_user, {:array, :map} do
      run {Marshall.SSH.KeyActions, operation: :list}
    end

    action :add_for_user, :map do
      argument :public_key, :string,
        allow_nil?: false,
        sensitive?: true,
        constraints: [max_length: 4096, trim?: false]

      argument :label, :string,
        allow_nil?: false,
        default: "",
        constraints: [max_length: 128, allow_empty?: true]

      run {Marshall.SSH.KeyActions, operation: :add}
    end

    action :rename_for_user, :map do
      argument :id, :uuid, allow_nil?: false

      argument :label, :string,
        allow_nil?: false,
        default: "",
        constraints: [max_length: 128, allow_empty?: true]

      run {Marshall.SSH.KeyActions, operation: :rename}
    end

    action :remove_for_user, :map do
      argument :id, :uuid, allow_nil?: false
      run {Marshall.SSH.KeyActions, operation: :remove}
    end

    action :list_for_admin, {:array, :map} do
      argument :after, :uuid
      argument :limit, :integer, allow_nil?: false, default: 100, constraints: [min: 1, max: 100]
      run {Marshall.SSH.AdminActions, operation: :list_keys}
    end

    action :revoke_for_admin, :map do
      argument :id, :uuid, allow_nil?: false
      run {Marshall.SSH.AdminActions, operation: :revoke_key}
    end
  end

  changes do
    # Control hints (ADR-0140): emitted in the action's transaction.
    change {Marshall.Control.Hints.Change, kind: :user, from: :user_id},
      on: [:create, :update, :destroy],
      where: [action_is([:revoke])]
  end

  attributes do
    uuid_primary_key :id

    attribute :label, :string,
      allow_nil?: false,
      default: "",
      constraints: [max_length: 128, allow_empty?: true]

    attribute :algorithm, :string, allow_nil?: false
    attribute :public_key, :string, allow_nil?: false, sensitive?: true
    attribute :fingerprint, :string, allow_nil?: false
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :user, Marshall.Accounts.User, allow_nil?: false
  end

  identities do
    identity :active_fingerprint, [:fingerprint], where: expr(is_nil(archived_at))
  end
end
