defmodule Marshall.Agents.ThreadReceiver do
  @moduledoc "Durable agent notification destination and acknowledged cursor."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshStateMachine]

  @type t :: %__MODULE__{}

  postgres do
    table "agent_thread_receivers"
    repo Marshall.Repo
    migration_defaults id: "nil", inserted_at: "nil", updated_at: "nil"

    identity_index_names subscription_destination:
                           "agent_thread_receivers_subscription_destination_index"

    references do
      reference :subscription, on_delete: :delete
    end

    check_constraints do
      check_constraint :state, "thread_receiver_closed_state",
        check:
          "state IN ('active', 'inactive') AND destination_kind IN ('user_thread', 'agent_thread') AND cursor >= 0"
    end
  end

  cedar do
    internal [:read, :register, :activate, :deactivate, :acknowledge, :defer]
  end

  # @cc [owner:ghuntley,label:durability;recovery] thread-receiver-cursor
  # Delivery acknowledgement MUST commit with the admitted notification turn.
  # Deactivation MUST retain identity and cursor; retries MUST NOT duplicate turns.
  state_machine do
    state_attribute :state
    initial_states [:active, :inactive]
    default_initial_state :active

    transitions do
      transition :activate, from: [:active, :inactive], to: :active
      transition :deactivate, from: [:active, :inactive], to: :inactive
    end
  end

  actions do
    defaults [:read]

    create :register do
      accept [:subscription_id, :destination_id, :destination_kind, :state]
    end

    update :activate do
      accept []
      change transition_state(:active)
    end

    update :deactivate do
      accept []
      change transition_state(:inactive)
    end

    update :acknowledge do
      accept [:cursor, :next_attempt_at]
    end

    update :defer do
      accept [:next_attempt_at]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :subscription_id, :uuid, allow_nil?: false
    attribute :destination_id, :uuid, allow_nil?: false

    attribute :destination_kind, :atom,
      allow_nil?: false,
      constraints: [one_of: [:user_thread, :agent_thread]]

    attribute :state, :atom,
      allow_nil?: false,
      default: :active,
      constraints: [one_of: [:active, :inactive]]

    attribute :cursor, :integer, allow_nil?: false, default: 0, constraints: [min: 0]
    attribute :next_attempt_at, :utc_datetime_usec
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  relationships do
    belongs_to :subscription, Marshall.Agents.ThreadSubscription do
      define_attribute? false
      source_attribute :subscription_id
    end
  end

  identities do
    identity :subscription_destination, [:subscription_id, :destination_kind, :destination_id]
  end
end
