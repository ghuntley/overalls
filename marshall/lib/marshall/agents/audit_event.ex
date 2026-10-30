defmodule Marshall.Agents.AuditEvent do
  @moduledoc "Append-only payload-free agent action receipt."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "agent_audit_events"
    repo Marshall.Repo

    custom_indexes do
      index [:vm_id, :inserted_at, :id]
      index [:actor_id, :inserted_at, :id]
      index [:thread_id, :inserted_at, :id]
    end
  end

  cedar do
    internal [:read, :record]
  end

  actions do
    defaults [:read]

    create :record do
      accept [:vm_id, :thread_id, :turn_id, :actor_id, :kind, :target_id, :outcome]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :vm_id, :uuid, allow_nil?: false
    attribute :thread_id, :uuid
    attribute :turn_id, :uuid
    attribute :actor_id, :uuid

    attribute :kind, :atom,
      allow_nil?: false,
      constraints: [
        one_of: [
          :agent_registered,
          :executor_updated,
          :prompt_admitted,
          :turn_started,
          :child_created,
          :wake_requested,
          :model_dispatched,
          :model_finished,
          :tool_dispatched,
          :tool_finished,
          :turn_finished,
          :thread_deleted,
          :cli_approved,
          :cli_refused,
          :cli_expired,
          :questions_requested,
          :questions_answered,
          :questions_cancelled,
          :plan_proposed,
          :plan_implemented,
          :context_captured,
          :context_compacted,
          :maintenance_admitted,
          :skill_install_requested,
          :skill_update_requested,
          :skill_enabled,
          :skill_disabled,
          :skill_removed,
          :skill_installed,
          :skill_failed,
          :artifact_published,
          :artifact_read,
          :artifact_listed,
          :artifact_deleted,
          :thread_subscription_revoked
        ]
      ]

    attribute :target_id, :uuid

    attribute :outcome, :atom,
      constraints: [one_of: [:accepted, :completed, :failed, :uncertain, :unavailable]]

    create_timestamp :inserted_at
  end
end
