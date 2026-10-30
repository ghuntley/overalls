# @cc [owner:ghuntley,label:security;durability] thread-one-current-grant
# Each thread/user pair MUST have at most one unarchived role. Replacement and
# revocation MUST retain the prior grant and its initiating actor history.
defmodule Marshall.Threads.Grant do
  @moduledoc "Durable thread membership, retained across machine generations."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Threads,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshArchival.Resource, AshPaperTrail.Resource]

  postgres do
    table "thread_grants"
    repo Marshall.Repo
    identity_wheres_to_sql current_member: "archived_at IS NULL"

    custom_indexes do
      # Machine lists start from the caller's current thread grants (ADR-0256).
      index [:user_id, :thread_id], where: "archived_at IS NULL", name: "thread_grants_user_index"
    end

    check_constraints do
      check_constraint :role, "valid_thread_access_role",
        check: "role IN ('viewer', 'operator', 'manager')"
    end
  end

  cedar do
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
      accept [:thread_id, :user_id, :role, :granted_by_id]
    end

    update :mark_revoked do
      accept [:revoked_by_id]
    end

    destroy :revoke

    action :set_access, :struct do
      constraints instance_of: Marshall.Threads.AccessChange
      argument :thread_id, :uuid, allow_nil?: false
      argument :email, :ci_string, allow_nil?: false, constraints: [max_length: 320]

      argument :role, :atom,
        allow_nil?: false,
        constraints: [one_of: [:viewer, :operator, :manager, :revoked]]

      argument :idempotency_key, :string,
        allow_nil?: false,
        constraints: [min_length: 1, max_length: 128]

      run Marshall.Threads.Sharing
    end

    action :list_grants, :map do
      argument :thread_id, :uuid, allow_nil?: false
      argument :after, :uuid
      argument :limit, :integer, allow_nil?: false, default: 50, constraints: [min: 1, max: 100]
      run {Marshall.Threads.Sharing, operation: :list}
    end
  end

  changes do
    change {Marshall.Control.Hints.Change, kind: :user, from: :user_id},
      on: [:create, :update, :destroy],
      where: [action_is([:grant, :mark_revoked, :revoke])]

    change {Marshall.Control.Hints.Change,
            kind: :vm, from: {Marshall.Threads.Sharing, :machine_id}},
           on: [:create, :update, :destroy],
           where: [action_is([:grant, :mark_revoked, :revoke])]
  end

  attributes do
    uuid_primary_key :id

    attribute :role, :atom,
      allow_nil?: false,
      constraints: [one_of: [:viewer, :operator, :manager]]

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :thread, Marshall.Threads.Thread, allow_nil?: false
    belongs_to :user, Marshall.Accounts.User, allow_nil?: false
    belongs_to :granted_by, Marshall.Accounts.User, allow_nil?: false
    belongs_to :revoked_by, Marshall.Accounts.User
  end

  identities do
    identity :current_member, [:thread_id, :user_id], where: expr(is_nil(archived_at))
  end
end
