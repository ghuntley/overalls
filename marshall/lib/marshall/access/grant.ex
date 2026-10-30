# @cc [owner:ghuntley,label:security] grant-one-current-role
# Each VM/member pair MUST have at most one unarchived role. Replacement/revocation
# MUST preserve prior grant and actor/action history rather than overwrite or
# physically delete the previous membership evidence.
defmodule Marshall.Access.Grant do
  @moduledoc "One current role per VM/member; replacement and revocation retain audited history."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Access,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshArchival.Resource, AshPaperTrail.Resource]

  postgres do
    table "access_grants"
    repo Marshall.Repo
    identity_wheres_to_sql current_member: "archived_at IS NULL"

    custom_indexes do
      # Machine lists start from the caller's current grants (ADR-0256).
      index [:user_id, :vm_id], where: "archived_at IS NULL", name: "access_grants_user_index"
    end

    check_constraints do
      check_constraint :role, "valid_access_role",
        check: "role IN ('web', 'viewer', 'operator', 'manager')"
    end
  end

  cedar do
    control_plane "admin_accounts", [:revoke_for_admin]
    control_plane "admin_read", [:list_for_admin]
    control_plane "provision", [:set_access, :list_grants]
    internal [:read, :history, :grant, :mark_revoked, :revoke]
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
    ignore_attributes [:inserted_at, :updated_at]
    version_extensions authorizers: [Marshall.Authorization.AshAuthorizer]
    mixin Marshall.Authorization.VersionMapping
  end

  actions do
    defaults [:read]
    read :history

    create :grant do
      accept [:vm_id, :user_id, :role, :granted_by_id]
    end

    update :mark_revoked do
      accept [:revoked_by_id]
    end

    destroy :revoke

    action :set_access, :struct do
      constraints instance_of: Marshall.Access.Change
      argument :vm_id, :uuid, allow_nil?: false
      argument :email, :ci_string, allow_nil?: false, constraints: [max_length: 320]

      argument :role, :atom,
        allow_nil?: false,
        constraints: [one_of: [:web, :viewer, :operator, :manager, :revoked]]

      argument :idempotency_key, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 128]

      run Marshall.Access.Sharing
    end

    action :list_grants, :map do
      argument :vm_id, :uuid, allow_nil?: false
      argument :after, :uuid
      argument :limit, :integer, allow_nil?: false, default: 50, constraints: [min: 1, max: 100]
      run {Marshall.Access.Sharing, operation: :list}
    end

    action :list_for_admin, {:array, :map} do
      argument :after, :uuid
      argument :limit, :integer, allow_nil?: false, default: 100, constraints: [min: 1, max: 100]
      run Marshall.Access.AdminActions
    end

    action :revoke_for_admin, :map do
      argument :id, :uuid, allow_nil?: false
      run {Marshall.Access.AdminActions, operation: :revoke}
    end
  end

  changes do
    # Control hints (ADR-0140): emitted in the action's transaction.
    change {Marshall.Control.Hints.Change, kind: :user, from: :user_id},
      on: [:create, :update, :destroy],
      where: [action_is([:mark_revoked, :revoke])]

    change {Marshall.Control.Hints.Change, kind: :vm, from: :vm_id},
      on: [:create, :update, :destroy],
      where: [action_is([:mark_revoked, :revoke])]
  end

  attributes do
    uuid_primary_key :id

    attribute :role, :atom,
      allow_nil?: false,
      constraints: [one_of: [:web, :viewer, :operator, :manager]]

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :vm, Marshall.Compute.VirtualMachine, allow_nil?: false
    belongs_to :user, Marshall.Accounts.User, allow_nil?: false
    belongs_to :granted_by, Marshall.Accounts.User, allow_nil?: false
    belongs_to :revoked_by, Marshall.Accounts.User
  end

  identities do
    identity :current_member, [:vm_id, :user_id], where: expr(is_nil(archived_at))
  end
end
