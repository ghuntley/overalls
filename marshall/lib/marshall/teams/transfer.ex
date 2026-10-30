# @cc [owner:ghuntley,label:security] team-transfer-consent-state-machine
# Ownership transfer MUST be a consent workflow: only the current owner may
# offer, only the designated member may accept or decline, and only the owner
# may cancel a pending offer. Acceptance MUST swap the owner role and demote
# the previous owner to admin in the same transaction; the exactly-one-owner
# constraint MUST hold in every state. Terminal states are immutable.
defmodule Marshall.Teams.Transfer do
  @moduledoc "Consent-based team ownership transfer with closed state transitions."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Teams,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshStateMachine, AshArchival.Resource, AshPaperTrail.Resource]

  postgres do
    table "team_transfers"
    repo Marshall.Repo
    identity_wheres_to_sql one_pending: "archived_at IS NULL AND state = 'pending'"
  end

  cedar do
    internal [:read, :history, :offer, :accept, :decline, :cancel, :archive]
  end

  state_machine do
    initial_states [:pending]
    default_initial_state :pending

    transitions do
      transition :accept, from: [:pending], to: :accepted
      transition :decline, from: [:pending], to: :declined
      transition :cancel, from: [:pending], to: :cancelled
    end
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

    create :offer do
      accept [:team_id, :from_user_id, :to_user_id]
    end

    update :accept do
      accept []
      require_atomic? false
      change transition_state(:accepted)
      change Marshall.Teams.TransferSwap
    end

    update :decline do
      accept []
      change transition_state(:declined)
    end

    update :cancel do
      accept []
      change transition_state(:cancelled)
    end

    # Retained-history archival of a retired team's transfers (ADR-0229).
    destroy :archive
  end

  attributes do
    uuid_primary_key :id
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :team, Marshall.Teams.Team, allow_nil?: false
    belongs_to :from_user, Marshall.Accounts.User, allow_nil?: false
    belongs_to :to_user, Marshall.Accounts.User, allow_nil?: false
  end

  identities do
    identity :one_pending, [:team_id], where: expr(is_nil(archived_at) and state == :pending)
  end
end
