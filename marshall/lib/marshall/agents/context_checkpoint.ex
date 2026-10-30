defmodule Marshall.Agents.ContextCheckpoint do
  @moduledoc "An immutable compacted prefix with explicit eligible-turn coverage."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "agent_context_checkpoints"
    repo Marshall.Repo

    custom_indexes do
      index [:thread_id, :generation], unique: true
    end
  end

  cedar do
    internal [:read, :install]
  end

  actions do
    defaults [:read]

    create :install do
      accept [
        :thread_id,
        :turn_id,
        :snapshot_id,
        :generation,
        :covered_turn_ordinal,
        :active_sequence,
        :state,
        :retained_input,
        :source_digest
      ]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :thread_id, :uuid, allow_nil?: false
    attribute :turn_id, :uuid, allow_nil?: false
    attribute :snapshot_id, :uuid, allow_nil?: false
    attribute :generation, :integer, allow_nil?: false, constraints: [min: 1]
    attribute :covered_turn_ordinal, :integer, allow_nil?: false, constraints: [min: 1]
    attribute :active_sequence, :integer, allow_nil?: false, constraints: [min: 0]
    attribute :state, :map, allow_nil?: false, sensitive?: true
    attribute :retained_input, {:array, :map}, allow_nil?: false, default: [], sensitive?: true

    attribute :source_digest, :string,
      allow_nil?: false,
      constraints: [match: ~r/\A[0-9a-f]{64}\z/]

    create_timestamp :inserted_at
  end
end
