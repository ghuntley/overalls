defmodule Marshall.Agents.PlanProposal do
  @moduledoc "A completed planning response and its single implementation admission."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "agent_plan_proposals"
    repo Marshall.Repo

    custom_indexes do
      index [:turn_id], unique: true
      index [:thread_id, :event_sequence]
      index [:thread_id, :implemented_by_id, :implementation_request_key], unique: true
    end
  end

  cedar do
    internal [:read, :record, :implement]
  end

  actions do
    defaults [:read]

    create :record do
      accept [:thread_id, :turn_id, :event_sequence, :text, :digest]
    end

    update :implement do
      accept [:implementing_turn_id, :implemented_by_id, :implementation_request_key]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :thread_id, :uuid, allow_nil?: false
    attribute :turn_id, :uuid, allow_nil?: false
    attribute :event_sequence, :integer, allow_nil?: false, constraints: [min: 1]

    attribute :text, :string,
      allow_nil?: false,
      sensitive?: true,
      constraints: [min_length: 1, max_length: 60_000]

    attribute :digest, :string, allow_nil?: false, constraints: [min_length: 64, max_length: 64]
    attribute :implementing_turn_id, :uuid
    attribute :implemented_by_id, :uuid

    attribute :implementation_request_key, :string, constraints: [min_length: 1, max_length: 128]

    create_timestamp :inserted_at
  end
end
