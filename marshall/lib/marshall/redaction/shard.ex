defmodule Marshall.Redaction.Shard do
  @moduledoc "Bounded work shard for a historical redaction run."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Redaction,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshStateMachine]

  postgres do
    table "redaction_shards"
    repo Marshall.Repo
  end

  cedar do
    internal [:read, :open, :transition, :start, :complete, :fail]
  end

  state_machine do
    initial_states [:queued]
    state_attribute :state

    transitions do
      transition :start, from: :queued, to: :running
      transition :complete, from: [:running], to: :completed
      transition :fail, from: [:queued, :running], to: :failed
    end
  end

  actions do
    defaults [:read]

    create :open do
      accept [:run_id, :lower_id, :upper_id]
    end

    update :transition do
      accept [:state, :processed, :changed, :skipped, :error]
    end

    update :start do
      accept []
      change transition_state(:running)
    end

    update :complete do
      accept [:processed, :changed, :skipped]
      change transition_state(:completed)
    end

    update :fail do
      accept [:error]
      change transition_state(:failed)
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :run_id, :uuid, allow_nil?: false
    attribute :lower_id, :uuid
    attribute :upper_id, :uuid

    attribute :state, :atom,
      allow_nil?: false,
      default: :queued,
      constraints: [one_of: [:queued, :running, :completed, :failed]]

    attribute :processed, :integer, allow_nil?: false, default: 0
    attribute :changed, :integer, allow_nil?: false, default: 0
    attribute :skipped, :integer, allow_nil?: false, default: 0
    attribute :error, :atom
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end
