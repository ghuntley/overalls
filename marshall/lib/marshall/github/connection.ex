defmodule Marshall.GitHub.Connection do
  @moduledoc "Durable per-user GitHub identity and encrypted rotating credential custody."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.GitHub,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshCloak, AshStateMachine]

  postgres do
    table "github_connections"
    repo Marshall.Repo

    custom_indexes do
      index [:github_id], unique: true, where: "phase <> 'disconnected' AND github_id IS NOT NULL"
      index [:refresh_due_at]
    end

    check_constraints do
      check_constraint :generation, "github_connection_generation_positive",
        check: "generation > 0"
    end
  end

  cedar do
    internal [
      :read,
      :register,
      :authorize,
      :connect,
      :drain,
      :start_refresh,
      :refresh,
      :require_reconnect,
      :disconnect,
      :revoked,
      :invalidate_restored
    ]
  end

  cloak do
    vault(Marshall.Vault)
    attributes([:credentials])
    decrypt_by_default([])
    encrypt_nil?(false)
  end

  # @cc [owner:ghuntley,label:security;recovery] github-credential-generation
  # Credentials MUST remain encrypted and excluded from default reads. Only named
  # transitions may change phase; refresh submission and disconnect fence old
  # generations before replacement credentials can authorize requests.
  state_machine do
    state_attribute :phase
    initial_states [:disconnected]
    default_initial_state :disconnected

    transitions do
      transition :connect, from: [:disconnected, :reconnect_required], to: :connected
      transition :drain, from: :connected, to: :draining
      transition :start_refresh, from: :draining, to: :refreshing
      transition :refresh, from: :refreshing, to: :connected

      transition :require_reconnect,
        from: [:connected, :draining, :refreshing, :reconnect_required],
        to: :reconnect_required

      transition :disconnect,
        from: [:connected, :draining, :refreshing, :reconnect_required, :disconnected, :revoking],
        to: :revoking

      transition :revoked, from: :revoking, to: :disconnected

      transition :invalidate_restored,
        from: [:disconnected, :connected, :draining, :refreshing, :reconnect_required, :revoking],
        to: :reconnect_required
    end
  end

  actions do
    defaults [:read]

    create :register do
      accept [:user_id]
    end

    update :authorize do
      accept [:authorization_attempt_id]
    end

    update :connect do
      accept [
        :github_id,
        :github_login,
        :scopes,
        :credentials,
        :generation,
        :expires_at,
        :refresh_expires_at,
        :refresh_due_at,
        :authorization_attempt_id
      ]

      change transition_state(:connected)
    end

    update :drain do
      accept [:refresh_attempt_id, :drain_deadline]
      change transition_state(:draining)
    end

    update :start_refresh do
      accept [:generation]
      change transition_state(:refreshing)
    end

    update :refresh do
      accept [
        :credentials,
        :scopes,
        :expires_at,
        :refresh_expires_at,
        :refresh_due_at,
        :refresh_attempt_id,
        :drain_deadline
      ]

      change transition_state(:connected)
    end

    update :require_reconnect do
      accept [:credentials, :refresh_attempt_id, :drain_deadline]
      change transition_state(:reconnect_required)
    end

    update :disconnect do
      accept [:generation, :authorization_attempt_id]
      change transition_state(:revoking)
    end

    update :revoked do
      accept [
        :credentials,
        :github_id,
        :github_login,
        :scopes,
        :expires_at,
        :refresh_expires_at,
        :refresh_due_at,
        :refresh_attempt_id,
        :drain_deadline
      ]

      change transition_state(:disconnected)
    end

    update :invalidate_restored do
      accept [
        :generation,
        :credentials,
        :refresh_attempt_id,
        :authorization_attempt_id,
        :drain_deadline
      ]

      change transition_state(:reconnect_required)
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :phase, :atom,
      allow_nil?: false,
      default: :disconnected,
      constraints: [
        one_of: [
          :disconnected,
          :connected,
          :draining,
          :refreshing,
          :reconnect_required,
          :revoking
        ]
      ]

    attribute :generation, :integer, allow_nil?: false, default: 1, constraints: [min: 1]
    attribute :github_id, :integer, constraints: [min: 1]
    attribute :github_login, :string, constraints: [min_length: 1, max_length: 100]
    attribute :scopes, {:array, :string}, allow_nil?: false, default: []
    attribute :credentials, :map, sensitive?: true
    attribute :expires_at, :utc_datetime_usec
    attribute :refresh_expires_at, :utc_datetime_usec
    attribute :refresh_due_at, :utc_datetime_usec
    attribute :drain_deadline, :utc_datetime_usec
    attribute :authorization_attempt_id, :uuid
    attribute :refresh_attempt_id, :uuid
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :user, Marshall.Accounts.User, allow_nil?: false
  end

  identities do
    identity :one_per_user, [:user_id]
  end
end
