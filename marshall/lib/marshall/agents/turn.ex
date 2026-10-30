defmodule Marshall.Agents.Turn do
  @moduledoc "One queued, running or terminal prompt on a thread."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "agent_turns"
    repo Marshall.Repo

    custom_indexes do
      index [:thread_id, :ordinal], unique: true
      index [:thread_id], unique: true, where: "status = 'running'"
      index [:status, :inserted_at]
      index [:thread_id, :actor_id, :request_key], unique: true
    end
  end

  cedar do
    internal [:read, :enqueue, :transition]
  end

  actions do
    defaults [:read]

    create :enqueue do
      accept [
        :thread_id,
        :actor_id,
        :request_key,
        :ordinal,
        :prompt,
        :mode,
        :collaboration_mode,
        :working_directory,
        :configuration_owner_id,
        :selected_skills,
        :maintenance_kind,
        :maintenance_metadata,
        :redaction_profile
      ]
    end

    update :transition do
      accept [:status, :started_at, :finished_at, :failure_reason]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :thread_id, :uuid, allow_nil?: false
    attribute :actor_id, :uuid, allow_nil?: false

    attribute :request_key, :string,
      allow_nil?: false,
      constraints: [min_length: 1, max_length: 128]

    attribute :ordinal, :integer, allow_nil?: false, constraints: [min: 1]

    attribute :prompt, :string, constraints: [min_length: 1, max_length: 65_536]

    attribute :mode, :atom,
      allow_nil?: false,
      default: :medium,
      constraints: [one_of: Marshall.Threads.Mode.values()]

    attribute :collaboration_mode, :atom,
      allow_nil?: false,
      default: :work,
      constraints: [one_of: [:work, :plan]]

    attribute :working_directory, :string, constraints: [max_length: 4096]
    attribute :configuration_owner_id, :uuid

    attribute :selected_skills, {:array, :string},
      allow_nil?: false,
      default: [],
      constraints: [max_length: 32]

    attribute :maintenance_kind, :atom,
      constraints: [
        one_of: [:compact_context, :reload_context, :skill_operation, :subscription_notification]
      ]

    attribute :maintenance_metadata, :map, allow_nil?: false, default: %{}
    attribute :redaction_profile, :string, constraints: [max_length: 128]

    attribute :status, :atom,
      allow_nil?: false,
      default: :queued,
      constraints: [one_of: [:queued, :running, :completed, :failed, :interrupted]]

    attribute :started_at, :utc_datetime_usec
    attribute :finished_at, :utc_datetime_usec

    attribute :failure_reason, :atom,
      constraints: [
        one_of: [
          :machine_unavailable,
          :wake_failed,
          :executor_lost,
          :provider_failed,
          :capability_denied,
          :tool_uncertain,
          :access_revoked,
          :context_too_large,
          :context_changed,
          :context_unavailable,
          :context_limit_exceeded,
          :compaction_no_progress,
          :nothing_to_compact,
          :invalid_compaction_response,
          :native_compaction_unavailable,
          :invalid_context,
          :skill_failed,
          :skill_ambiguous,
          :skill_unavailable
        ]
      ]

    create_timestamp :inserted_at
  end
end
