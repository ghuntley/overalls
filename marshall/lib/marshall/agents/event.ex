defmodule Marshall.Agents.Event do
  @moduledoc "Ordered authorized conversation event; may contain private content."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "agent_events"
    repo Marshall.Repo

    custom_indexes do
      index [:thread_id, :sequence], unique: true
    end
  end

  cedar do
    internal [:read, :append]
  end

  actions do
    defaults [:read]

    create :append do
      accept [:thread_id, :turn_id, :sequence, :kind, :body]
      change Marshall.Agents.EventActivity
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :thread_id, :uuid, allow_nil?: false
    attribute :turn_id, :uuid
    attribute :sequence, :integer, allow_nil?: false, constraints: [min: 1]

    attribute :kind, :atom,
      allow_nil?: false,
      constraints: [
        one_of: [
          :prompt,
          :turn_started,
          :assistant,
          :model_output,
          :tool_queued,
          :tool_result,
          :child_spawned,
          :turn_finished,
          :turn_failed,
          :waiting_for_vm,
          :questions_requested,
          :questions_answered,
          :questions_cancelled,
          :plan_proposed,
          :context_captured,
          :context_compacted,
          :maintenance_finished,
          :subscription_notification
        ]
      ]

    attribute :body, :map, allow_nil?: false, default: %{}
    create_timestamp :inserted_at
  end
end
