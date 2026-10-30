defmodule Marshall.Agents.ThreadNotification do
  @moduledoc "Content-free retained thread-tool notification."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  @type t :: %__MODULE__{}

  postgres do
    table "agent_thread_tool_events"
    repo Marshall.Repo
    migration_defaults id: "nil", inserted_at: "nil", updated_at: "nil"

    identity_index_names thread_sequence: "agent_thread_tool_events_thread_id_sequence_index",
                         user_thread_sequence:
                           "agent_thread_tool_events_user_thread_sequence_index"

    references do
      reference :thread, on_delete: :delete
      reference :owner, on_delete: :delete
      reference :user_thread, on_delete: :delete
    end

    custom_indexes do
      index [:owner_id, :thread_id, :sequence]
    end
  end

  cedar do
    internal [:read, :append]
  end

  actions do
    defaults [:read]

    create :append do
      accept [:thread_id, :user_thread_id, :owner_id, :sequence, :kind, :metadata]
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :thread_id, :uuid, allow_nil?: false
    attribute :user_thread_id, :uuid, allow_nil?: false
    attribute :owner_id, :uuid, allow_nil?: false
    attribute :sequence, :integer, allow_nil?: false, constraints: [min: 1]

    attribute :kind, :atom,
      allow_nil?: false,
      constraints: [one_of: [:machine_purged, :turn_finished]]

    attribute :metadata, :map, allow_nil?: false, default: %{}
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
    identity :thread_sequence, [:thread_id, :sequence]
    identity :user_thread_sequence, [:user_thread_id, :sequence]
  end
end
