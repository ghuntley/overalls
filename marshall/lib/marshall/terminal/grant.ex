defmodule Marshall.Terminal.Grant do
  @moduledoc "Owner-issued view-only access to one terminal, subordinate to current VM access."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Terminal,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshArchival.Resource, AshPaperTrail.Resource]

  postgres do
    table "terminal_grants"
    repo Marshall.Repo
    identity_wheres_to_sql current_viewer: "archived_at IS NULL"
  end

  # @cc [owner:ghuntley,label:security] terminal-grants-view-only
  # Grants MUST name exactly one terminal and account. They MUST confer only
  # viewing, never guest input, resize or kill, even when VM access permits write.
  # Revocation MUST retain its prior grant and audit history.
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
    ignore_attributes [:inserted_at]
    version_extensions authorizers: [Marshall.Authorization.AshAuthorizer]
    mixin Marshall.Authorization.VersionMapping
  end

  actions do
    defaults [:read]
    read :history

    create :grant do
      primary? true
      accept [:session_id, :user_id, :granted_by_id]
    end

    destroy :revoke
  end

  changes do
    # Control hints (ADR-0140): emitted in the action's transaction.
    change {Marshall.Control.Hints.Change, kind: :user, from: :user_id},
      on: [:create, :update, :destroy],
      where: [action_is([:revoke])]
  end

  attributes do
    uuid_primary_key :id
    attribute :session_id, :uuid, allow_nil?: false
    attribute :user_id, :uuid, allow_nil?: false
    attribute :granted_by_id, :uuid, allow_nil?: false
    create_timestamp :inserted_at
  end

  identities do
    identity :current_viewer, [:session_id, :user_id], where: expr(is_nil(archived_at))
  end
end
