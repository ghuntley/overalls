defmodule Marshall.GitHub.RefreshAttempt do
  @moduledoc "Single-flight rotation receipt, with encrypted staging before identity revalidation."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.GitHub,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshCloak, AshStateMachine]

  postgres do
    table "github_refresh_attempts"
    repo Marshall.Repo
  end

  cedar do
    internal [
      :read,
      :record,
      :submit,
      :stage,
      :finish,
      :fail,
      :retain_result,
      :clear_result,
      :purge
    ]
  end

  cloak do
    vault(Marshall.Vault)
    attributes([:result])
    decrypt_by_default([])
    encrypt_nil?(false)
  end

  # @cc [owner:ghuntley,label:security;recovery] github-refresh-uncertainty
  # A submitted attempt without a durable staged response MUST NOT resend its
  # refresh token. It MUST require browser reconnection because GitHub may have
  # invalidated the previous pair even when no response reached Marshall.
  # A known rejected pair MUST remain encrypted for single-token cleanup and
  # MUST NOT be published to a disconnected or replacement generation.
  state_machine do
    state_attribute :phase
    initial_states [:pending]
    default_initial_state :pending

    transitions do
      transition :submit, from: :pending, to: :submitted
      transition :stage, from: :submitted, to: :staged
      transition :finish, from: :staged, to: :finished
      transition :fail, from: [:pending, :submitted, :staged], to: :failed
    end
  end

  actions do
    defaults [:read]

    create :record do
      accept [:connection_id, :generation]
    end

    update :submit do
      accept [:submission_expires_at]
      change transition_state(:submitted)
    end

    update :stage do
      accept [:result]
      change transition_state(:staged)
    end

    update :finish do
      accept [:result]
      change transition_state(:finished)
    end

    update :fail do
      accept [:result]
      change transition_state(:failed)
    end

    update :retain_result do
      accept [:result]
    end

    update :clear_result do
      accept [:result]
    end

    destroy :purge
  end

  attributes do
    uuid_primary_key :id
    attribute :generation, :integer, allow_nil?: false, constraints: [min: 1]

    attribute :phase, :atom,
      allow_nil?: false,
      default: :pending,
      constraints: [one_of: [:pending, :submitted, :staged, :finished, :failed]]

    attribute :result, :map, sensitive?: true
    attribute :submission_expires_at, :utc_datetime_usec
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :connection, Marshall.GitHub.Connection, allow_nil?: false
  end
end
