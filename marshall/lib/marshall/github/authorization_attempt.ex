defmodule Marshall.GitHub.AuthorizationAttempt do
  @moduledoc "One-use, login-bound PKCE authorization ceremony; no authorization codes are stored."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.GitHub,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshCloak, AshStateMachine]

  postgres do
    table "github_authorization_attempts"
    repo Marshall.Repo

    custom_indexes do
      index [:expires_at]
    end
  end

  cedar do
    internal [
      :read,
      :record,
      :exchange,
      :consume,
      :fail,
      :cancel,
      :stage_result,
      :clear_result,
      :purge
    ]
  end

  cloak do
    vault(Marshall.Vault)
    attributes([:verifier, :issued_credentials])
    decrypt_by_default([])
    encrypt_nil?(false)
  end

  state_machine do
    state_attribute :phase
    initial_states [:pending]
    default_initial_state :pending

    transitions do
      transition :exchange, from: :pending, to: :exchanging
      transition :consume, from: :exchanging, to: :consumed
      transition :fail, from: [:pending, :exchanging], to: :failed
      transition :cancel, from: [:pending, :exchanging], to: :cancelled
    end
  end

  actions do
    defaults [:read]

    create :record do
      accept [:connection_id, :state_digest, :login_digest, :verifier, :generation, :expires_at]
    end

    update :exchange do
      accept []
      change transition_state(:exchanging)
    end

    update :consume do
      accept [:verifier]
      change transition_state(:consumed)
    end

    update :fail do
      accept [:verifier]
      change transition_state(:failed)
    end

    update :cancel do
      accept [:verifier]
      change transition_state(:cancelled)
    end

    update :stage_result do
      accept [:issued_credentials]
    end

    update :clear_result do
      accept [:issued_credentials]
    end

    destroy :purge
  end

  attributes do
    uuid_primary_key :id

    attribute :phase, :atom,
      allow_nil?: false,
      default: :pending,
      constraints: [one_of: [:pending, :exchanging, :consumed, :failed, :cancelled]]

    attribute :state_digest, :string, allow_nil?: false, sensitive?: true
    attribute :login_digest, :string, allow_nil?: false, sensitive?: true
    attribute :verifier, :string, sensitive?: true
    attribute :issued_credentials, :map, sensitive?: true
    attribute :generation, :integer, allow_nil?: false, constraints: [min: 1]
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :connection, Marshall.GitHub.Connection, allow_nil?: false
  end

  identities do
    identity :one_per_state, [:state_digest]
  end
end
