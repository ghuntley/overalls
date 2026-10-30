defmodule Marshall.Enrico.Repository do
  @moduledoc "Administrator registered public GitHub repository and its last mirror outcome."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Enrico,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshStateMachine]

  postgres do
    table "enrico_repositories"
    repo Marshall.Repo
  end

  cedar do
    internal [:read, :register, :begin_refresh, :publish, :fail, :request_remove, :remove]
  end

  # @cc [owner:ghuntley,label:recovery] enrico-published-state
  # A failed fetch MUST retain the previous published commit and browseability.
  state_machine do
    state_attribute :phase
    initial_states [:pending]
    default_initial_state :pending

    transitions do
      transition :begin_refresh, from: [:pending, :ready, :failed], to: :refreshing
      transition :publish, from: [:refreshing], to: :ready
      transition :fail, from: [:refreshing], to: :failed
      transition :request_remove, from: [:pending, :ready, :failed, :refreshing], to: :removing
    end
  end

  actions do
    defaults [:read]

    create :register do
      accept [:namespace, :owner, :name, :registered_by_id]
    end

    update :begin_refresh do
      accept [:attempt_id, :last_attempt_at]
      change transition_state(:refreshing)
    end

    update :publish do
      accept [:head, :last_success_at, :next_refresh_at]
      change transition_state(:ready)
    end

    update :fail do
      accept [:next_refresh_at]
      change transition_state(:failed)
    end

    update :request_remove do
      accept []
      change transition_state(:removing)
    end

    destroy :remove
  end

  attributes do
    uuid_primary_key :id
    attribute :namespace, :string, allow_nil?: false
    attribute :owner, :string, allow_nil?: false
    attribute :name, :string, allow_nil?: false
    attribute :registered_by_id, :uuid, allow_nil?: false

    attribute :phase, :atom,
      allow_nil?: false,
      default: :pending,
      constraints: [one_of: [:pending, :refreshing, :ready, :failed, :removing]]

    attribute :head, :string
    attribute :attempt_id, :uuid
    attribute :last_attempt_at, :utc_datetime_usec
    attribute :last_success_at, :utc_datetime_usec
    attribute :next_refresh_at, :utc_datetime_usec
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :source, [:namespace, :owner, :name]
  end
end
