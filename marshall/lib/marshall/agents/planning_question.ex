defmodule Marshall.Agents.PlanningQuestion do
  @moduledoc "A durable human-answer barrier belonging to one root planning turn."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "agent_planning_questions"
    repo Marshall.Repo

    custom_indexes do
      index [:turn_id, :call_id], unique: true
      index [:thread_id], unique: true, where: "status = 'pending'"
    end
  end

  cedar do
    internal [:read, :request, :resolve, :cancel]
  end

  actions do
    defaults [:read]

    create :request do
      accept [:thread_id, :turn_id, :call_id, :questions]
    end

    update :resolve do
      accept [:status, :answers, :answered_by_id, :answer_request_key, :resolved_at]
    end

    update :cancel do
      accept [:status, :cancellation_reason, :resolved_at]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :thread_id, :uuid, allow_nil?: false
    attribute :turn_id, :uuid, allow_nil?: false
    attribute :call_id, :string, allow_nil?: false, constraints: [min_length: 1, max_length: 128]
    attribute :questions, {:array, :map}, allow_nil?: false, sensitive?: true

    attribute :status, :atom,
      allow_nil?: false,
      default: :pending,
      constraints: [one_of: [:pending, :answered, :cancelled]]

    attribute :answers, :map, sensitive?: true
    attribute :answered_by_id, :uuid
    attribute :answer_request_key, :string, constraints: [min_length: 1, max_length: 128]

    attribute :cancellation_reason, :atom,
      constraints: [
        one_of: [:turn_finished, :access_revoked, :archived, :cancelled, :machine_unavailable]
      ]

    attribute :resolved_at, :utc_datetime_usec
    create_timestamp :inserted_at
  end
end
