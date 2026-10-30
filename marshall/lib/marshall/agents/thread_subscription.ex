defmodule Marshall.Agents.ThreadSubscription do
  @moduledoc "Persisted actor subscription to a durable user thread with origin provenance."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshStateMachine]

  @type t :: %__MODULE__{}

  postgres do
    table "agent_thread_tool_subscriptions"
    repo Marshall.Repo
    migration_defaults id: "nil", inserted_at: "nil", updated_at: "nil"

    identity_index_names owner_thread: "agent_thread_tool_subscriptions_owner_id_thread_id_index",
                         owner_user_thread:
                           "agent_thread_tool_subscriptions_owner_user_thread_index"

    references do
      reference :thread, on_delete: :delete
      reference :owner, on_delete: :delete
      reference :user_thread, on_delete: :delete
    end

    check_constraints do
      check_constraint :state, "thread_subscription_state",
        check: "state IN ('active', 'inactive', 'revoked')"
    end
  end

  cedar do
    internal [:read, :subscribe, :activate, :deactivate, :revoke]
  end

  # @cc [owner:ghuntley,label:durability;security] thread-subscription-transitions
  # Activate and deactivate MUST be idempotent state transitions retaining identity.
  # Revocation records lost read authority; only a fresh, authorized subscribe
  # may leave `revoked`.
  state_machine do
    state_attribute :state
    initial_states [:active, :inactive]
    default_initial_state :active

    transitions do
      transition :activate, from: [:active, :inactive, :revoked], to: :active
      transition :deactivate, from: [:active, :inactive, :revoked], to: :inactive
      transition :revoke, from: [:active, :inactive], to: :revoked
    end
  end

  actions do
    defaults [:read]

    create :subscribe do
      accept [:owner_id, :thread_id, :user_thread_id, :state]
    end

    update :activate do
      accept []
      change transition_state(:active)
    end

    update :deactivate do
      accept []
      change transition_state(:inactive)
    end

    update :revoke do
      accept []
      change transition_state(:revoked)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :owner_id, :uuid, allow_nil?: false
    attribute :thread_id, :uuid, allow_nil?: false
    attribute :user_thread_id, :uuid, allow_nil?: false

    attribute :state, :atom,
      allow_nil?: false,
      default: :active,
      constraints: [one_of: [:active, :inactive, :revoked]]

    attribute :cursor, :integer, allow_nil?: false, default: 0
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :user_thread, Marshall.Threads.Thread do
      define_attribute? false
      source_attribute :user_thread_id
    end

    belongs_to :thread, Marshall.Agents.Thread do
      define_attribute? false
      source_attribute :thread_id
    end

    belongs_to :owner, Marshall.Accounts.User do
      define_attribute? false
      source_attribute :owner_id
    end
  end

  identities do
    identity :owner_thread, [:owner_id, :thread_id]
    identity :owner_user_thread, [:owner_id, :user_thread_id]
  end
end
