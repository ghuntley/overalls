defmodule Marshall.Artifacts.Grant do
  @moduledoc "A current artifact role held by a user or a team."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Artifacts,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshArchival.Resource, AshPaperTrail.Resource]

  # @cc [owner:ghuntley,label:security;durability] artifact-one-current-grant
  # Each artifact/user and artifact/team pair MUST have at most one unarchived
  # role. Teams may hold writer or viewer only. Revocation archives the grant
  # and keeps its history.
  postgres do
    table "artifact_grants"
    repo Marshall.Repo

    identity_wheres_to_sql current_user_grant: "archived_at IS NULL AND user_id IS NOT NULL",
                           current_team_grant: "archived_at IS NULL AND team_id IS NOT NULL"

    references do
      reference :artifact, on_delete: :delete
    end

    check_constraints do
      check_constraint :role, "artifact_grant_subject",
        check:
          "(user_id IS NOT NULL AND team_id IS NULL) OR " <>
            "(user_id IS NULL AND team_id IS NOT NULL AND role IN ('writer', 'viewer'))"
    end
  end

  cedar do
    internal [:read, :history, :grant, :revoke]
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
      accept [:artifact_id, :user_id, :team_id, :role, :granted_by_id]
    end

    destroy :revoke
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :user_id, :uuid
    attribute :team_id, :uuid
    attribute :role, :atom, allow_nil?: false, constraints: [one_of: [:owner, :writer, :viewer]]
    attribute :granted_by_id, :uuid, allow_nil?: false
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :artifact, Marshall.Artifacts.Artifact,
      allow_nil?: false,
      attribute_writable?: true

    belongs_to :team, Marshall.Teams.Team, define_attribute?: false
  end

  identities do
    identity :current_user_grant, [:artifact_id, :user_id],
      where: expr(is_nil(archived_at) and not is_nil(user_id))

    identity :current_team_grant, [:artifact_id, :team_id],
      where: expr(is_nil(archived_at) and not is_nil(team_id))
  end
end
