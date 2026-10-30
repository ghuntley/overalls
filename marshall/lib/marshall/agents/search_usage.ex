defmodule Marshall.Agents.SearchUsage do
  @moduledoc "Content-free credit receipt for one search command."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "agent_search_usage"
    repo Marshall.Repo

    custom_indexes do
      index [:command_id], unique: true
      index [:vm_id, :inserted_at]
    end
  end

  cedar do
    internal [:read, :record]
  end

  actions do
    defaults [:read]

    create :record do
      accept [:command_id, :vm_id, :thread_id, :actor_id, :credits, :cache_hit, :outcome]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :command_id, :uuid, allow_nil?: false
    attribute :vm_id, :uuid, allow_nil?: false
    attribute :thread_id, :uuid, allow_nil?: false
    attribute :actor_id, :uuid, allow_nil?: false
    attribute :credits, :integer, constraints: [min: 0]
    attribute :cache_hit, :boolean, allow_nil?: false

    attribute :outcome, :atom,
      allow_nil?: false,
      constraints: [one_of: [:completed, :failed, :uncertain]]

    create_timestamp :inserted_at
  end
end
