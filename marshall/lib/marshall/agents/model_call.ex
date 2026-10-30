defmodule Marshall.Agents.ModelCall do
  @moduledoc "One durable, single-attempt model inference step within a turn."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "agent_model_calls"
    repo Marshall.Repo

    custom_indexes do
      index [:turn_id, :iteration], unique: true
      index [:host_id, :status, :inserted_at]
    end
  end

  cedar do
    internal [:read, :queue, :transition]
  end

  actions do
    defaults [:read]

    create :queue do
      accept [
        :root_id,
        :thread_id,
        :turn_id,
        :iteration,
        :host_id,
        :placement_id,
        :execution_epoch,
        :request,
        :purpose,
        :context_metadata
      ]

      # Wakes the host's Ziggy to claim at once (ADR-0142); its poll remains.
      change {Marshall.Control.Hints.Change, kind: :ziggy_work, from: :host_id}
    end

    update :transition do
      accept [:status, :claim_id, :claimed_at, :finished_at, :response]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :root_id, :uuid, allow_nil?: false
    attribute :thread_id, :uuid, allow_nil?: false
    attribute :turn_id, :uuid, allow_nil?: false
    attribute :iteration, :integer, allow_nil?: false, constraints: [min: 1, max: 72]

    attribute :purpose, :atom,
      allow_nil?: false,
      default: :inference,
      constraints: [one_of: [:inference, :summary, :native]]

    attribute :context_metadata, :map, allow_nil?: false, default: %{}
    attribute :host_id, :uuid, allow_nil?: false
    attribute :placement_id, :uuid, allow_nil?: false
    attribute :execution_epoch, :integer, allow_nil?: false, constraints: [min: 1]
    attribute :request, :map, allow_nil?: false
    attribute :response, :map
    attribute :claim_id, :uuid

    attribute :status, :atom,
      allow_nil?: false,
      default: :queued,
      constraints: [one_of: [:queued, :claimed, :completed, :failed, :uncertain, :cancelled]]

    attribute :claimed_at, :utc_datetime_usec
    attribute :finished_at, :utc_datetime_usec
    create_timestamp :inserted_at
  end
end
