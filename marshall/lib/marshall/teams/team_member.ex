# @cc [owner:ghuntley,label:security] team-one-current-membership
# Each team/member pair MUST have at most one unarchived membership and a
# team MUST have exactly one unarchived owner. Role replacement MUST retain
# audited history rather than overwrite membership evidence.
defmodule Marshall.Teams.TeamMember do
  @moduledoc "One current role per team/member; replacement retains audited history."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Teams,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshArchival.Resource, AshPaperTrail.Resource]

  postgres do
    table "team_members"
    repo Marshall.Repo

    identity_wheres_to_sql current_member: "archived_at IS NULL",
                           one_owner: "archived_at IS NULL AND role = 'owner'"

    # scim_match only names the current_member fields for SCIM relationship
    # matching; the partial current_member index enforces uniqueness.
    skip_unique_indexes [:scim_match]

    custom_indexes do
      # Machine lists start from the caller's current memberships (ADR-0256).
      index [:user_id, :team_id], where: "archived_at IS NULL", name: "team_members_user_index"
    end
  end

  cedar do
    internal [:read, :history, :record, :replace_role, :remove]
    service :scim, [:read, :scim_record, :scim_remove]
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

    create :record do
      accept [:team_id, :user_id, :role, :recorded_by_id]
    end

    # SCIM group membership: always a plain member recorded by the hidden
    # service owner. Primary so ash_scim relationship management creates it.
    create :scim_record do
      accept [:team_id, :user_id]
      primary? true
      change Marshall.Teams.ScimMembership
    end

    update :replace_role do
      accept [:role, :recorded_by_id]
    end

    destroy :remove

    # SCIM group member removal (PATCH remove, PUT replacement). Primary so
    # ash_scim's relationship management and bulk removal select it.
    destroy :scim_remove do
      primary? true
      require_atomic? false
      change {Marshall.Teams.ScimMembership, operation: :removed}
    end
  end

  changes do
    # Control hints (ADR-0140): emitted in the action's transaction.
    change {Marshall.Control.Hints.Change, kind: :user, from: :user_id},
      on: [:create, :update, :destroy],
      where: [action_is([:replace_role, :remove, :scim_record, :scim_remove])]
  end

  attributes do
    uuid_primary_key :id

    attribute :role, :atom,
      allow_nil?: false,
      constraints: [one_of: [:owner, :admin, :member]]

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :team, Marshall.Teams.Team, allow_nil?: false
    # Public so SCIM member filters (`members[value eq "…"]`) can address it.
    belongs_to :user, Marshall.Accounts.User, allow_nil?: false, attribute_public?: true
    belongs_to :recorded_by, Marshall.Accounts.User, allow_nil?: false
  end

  identities do
    identity :current_member, [:team_id, :user_id], where: expr(is_nil(archived_at))
    identity :one_owner, [:team_id], where: expr(is_nil(archived_at) and role == :owner)

    # Ash cannot match managed relationships on an identity with `where`. Reads
    # exclude archived rows, so among the rows SCIM matches these fields are the
    # current_member key; scim_match has no index of its own.
    identity :scim_match, [:team_id, :user_id]
  end
end
