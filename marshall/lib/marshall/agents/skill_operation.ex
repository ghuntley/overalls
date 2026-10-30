defmodule Marshall.Agents.SkillOperation do
  @moduledoc "Immutable managed skill requests with a single durable terminal outcome."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "agent_skill_operations"
    repo Marshall.Repo

    custom_indexes do
      index [:thread_id, :requested_by_id, :request_key], unique: true
      index [:status, :inserted_at, :id]
    end
  end

  cedar do
    internal [:read, :record, :dispatch, :finish]
  end

  actions do
    defaults [:read]

    create :record do
      accept [
        :thread_id,
        :installation_id,
        :requested_by_id,
        :request_key,
        :request_digest,
        :kind,
        :request,
        :machine_id,
        :machine_key,
        :base_revision_id,
        :status
      ]
    end

    update :dispatch do
      accept [:status, :command_id]
    end

    update :finish do
      accept [:status, :revision_id, :failure_reason]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :thread_id, :uuid, allow_nil?: false
    attribute :installation_id, :uuid, allow_nil?: false
    attribute :requested_by_id, :uuid, allow_nil?: false

    attribute :request_key, :string,
      allow_nil?: false,
      constraints: [min_length: 1, max_length: 128]

    attribute :request_digest, :string, allow_nil?: false
    attribute :request, :map, allow_nil?: false, sensitive?: true

    attribute :kind, :atom,
      allow_nil?: false,
      constraints: [one_of: [:install, :update, :restore, :enable, :disable, :remove]]

    attribute :machine_id, :uuid
    attribute :machine_key, :string, allow_nil?: false
    attribute :base_revision_id, :uuid
    attribute :command_id, :uuid
    attribute :revision_id, :uuid

    attribute :status, :atom,
      allow_nil?: false,
      default: :queued,
      constraints: [one_of: [:queued, :dispatched, :completed, :failed, :uncertain]]

    attribute :failure_reason, :atom,
      constraints: [one_of: Marshall.Agents.Skills.Failures.values()]

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end
