defmodule Marshall.Agents.Command do
  @moduledoc "Persisted tool RPC and its fenced terminal result."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "agent_commands"
    repo Marshall.Repo

    custom_indexes do
      index [:root_id, :status, :inserted_at]
      index [:turn_id, :call_id], unique: true
    end
  end

  cedar do
    internal [:read, :queue, :transition]
  end

  actions do
    defaults [:read]

    create :queue do
      accept [:root_id, :thread_id, :turn_id, :call_id, :tool, :arguments, :redaction_profile]
    end

    update :transition do
      accept [:status, :executor_id, :fence_epoch, :claim_id, :claimed_at, :result]
      change Marshall.Artifacts.Changes.ResumeStagedPublish
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :root_id, :uuid, allow_nil?: false
    attribute :thread_id, :uuid, allow_nil?: false
    attribute :turn_id, :uuid, allow_nil?: false
    attribute :call_id, :string, allow_nil?: false, constraints: [min_length: 1, max_length: 128]

    # @cc [owner:ghuntley,label:security] agent-command-tools-profile-allowed
    # Model tools MUST be allowed by the current profile. Internal context and
    # skill commands MUST be created only by trusted coordinators and gated by
    # the executor's advertised version capability at claim and start.
    attribute :tool, :atom,
      allow_nil?: false,
      constraints: [
        one_of: [
          :exec_command,
          :read_file,
          :web_search,
          :web_fetch,
          :thread,
          :attachment,
          :message_board,
          :artifact,
          :artifact_stage,
          :context_inventory,
          :context_read,
          :skill_install,
          :skill_status
        ]
      ]

    attribute :arguments, :map, allow_nil?: false
    attribute :result, :map
    attribute :redaction_profile, :string, constraints: [max_length: 128]

    attribute :status, :atom,
      allow_nil?: false,
      default: :queued,
      constraints: [
        one_of: [:queued, :claimed, :started, :completed, :failed, :uncertain, :cancelled]
      ]

    attribute :executor_id, :uuid
    attribute :fence_epoch, :integer, constraints: [min: 1]
    attribute :claim_id, :uuid
    attribute :claimed_at, :utc_datetime_usec
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end
