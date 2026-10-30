defmodule Marshall.Compute.CloneEffect do
  @moduledoc "Immutable host-bound clone command with retained physical receipt."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Compute,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshStateMachine]

  postgres do
    table "compute_clone_effects"
    repo Marshall.Repo
  end

  cedar do
    internal [:read, :record, :offer, :complete, :record_unconfirmed]
  end

  state_machine do
    state_attribute :status
    initial_states [:pending]
    default_initial_state :pending

    transitions do
      transition :offer, from: [:pending, :offered], to: :offered
      transition :complete, from: [:pending, :offered], to: :completed
    end
  end

  actions do
    defaults [:read]

    create :record do
      accept [:clone_request_id, :host_id, :kind, :endpoint, :payload]
    end

    update :offer do
      accept [:offered_at]
      change transition_state(:offered)
    end

    update :complete do
      accept [:result, :completed_at]
      change transition_state(:completed)
    end

    update :record_unconfirmed do
      accept [:unconfirmed_reason, :unconfirmed_count, :unconfirmed_at]
    end
  end

  changes do
    change Marshall.Compute.LifecycleAudit, on: [:create, :update, :destroy]
  end

  attributes do
    uuid_primary_key :id

    attribute :kind, :atom,
      allow_nil?: false,
      constraints: [
        one_of: [:prepare, :probe, :connect, :capture, :copy, :adopt, :revoke, :discard, :prune]
      ]

    attribute :endpoint, :atom, allow_nil?: false, constraints: [one_of: [:source, :destination]]
    attribute :payload, :map, allow_nil?: false
    attribute :result, :map
    attribute :offered_at, :utc_datetime_usec
    attribute :completed_at, :utc_datetime_usec
    attribute :unconfirmed_reason, :string, constraints: [max_length: 64]
    attribute :unconfirmed_count, :integer, allow_nil?: false, default: 0
    attribute :unconfirmed_at, :utc_datetime_usec
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :clone_request, Marshall.Compute.CloneRequest, allow_nil?: false
    belongs_to :host, Marshall.Compute.Host, allow_nil?: false
  end

  identities do
    identity :effect_identity, [:clone_request_id, :host_id, :kind, :endpoint]
  end
end
