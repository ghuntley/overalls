defmodule Marshall.Agents.ToolBootstrap do
  @moduledoc "One durable desired managed-tool generation and fenced executor bootstrap receipt per VM."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer],
    extensions: [AshStateMachine]

  postgres do
    table "agent_tool_bootstraps"
    repo Marshall.Repo
  end

  cedar do
    internal [:read, :queue, :reset, :claim, :start, :complete, :fail, :uncertain]
  end

  state_machine do
    state_attribute :phase
    initial_states [:queued]
    default_initial_state :queued

    transitions do
      transition :reset,
        from: [:queued, :claimed, :started, :completed, :failed, :uncertain],
        to: :queued

      transition :claim, from: [:queued, :uncertain], to: :claimed
      transition :start, from: :claimed, to: :started
      transition :complete, from: :started, to: :completed
      transition :fail, from: [:claimed, :started], to: :failed
      transition :uncertain, from: [:claimed, :started], to: :uncertain
    end
  end

  actions do
    defaults [:read]

    create :queue do
      accept [
        :vm_id,
        :generation,
        :platform,
        :tools_generation,
        :artifact_sha256,
        :artifact_bytes
      ]
    end

    update :reset do
      accept [
        :generation,
        :platform,
        :attempt_id,
        :executor_id,
        :fence_epoch,
        :placement_id,
        :execution_epoch,
        :tools_generation,
        :artifact_sha256,
        :artifact_bytes
      ]

      change transition_state(:queued)
    end

    update :claim do
      accept [:attempt_id, :executor_id, :fence_epoch, :placement_id, :execution_epoch]
      change transition_state(:claimed)
    end

    update :start do
      accept []
      change transition_state(:started)
    end

    update :complete do
      accept []
      change transition_state(:completed)
    end

    update :fail do
      accept []
      change transition_state(:failed)
    end

    update :uncertain do
      accept []
      change transition_state(:uncertain)
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :vm_id, :uuid, allow_nil?: false
    attribute :generation, :string, allow_nil?: false, constraints: [match: ~r/\A[0-9a-f]{64}\z/]

    attribute :platform, :string,
      allow_nil?: false,
      constraints: [match: ~r/\A(?:linux|windows|freebsd|illumos)-amd64\z/]

    attribute :phase, :atom,
      allow_nil?: false,
      default: :queued,
      constraints: [one_of: [:queued, :claimed, :started, :completed, :failed, :uncertain]]

    attribute :attempt_id, :uuid
    attribute :executor_id, :uuid
    attribute :fence_epoch, :integer, constraints: [min: 1]
    attribute :placement_id, :uuid
    attribute :execution_epoch, :integer, constraints: [min: 1]

    attribute :tools_generation, :string,
      allow_nil?: false,
      constraints: [match: ~r/\A[0-9a-f]{64}\z/]

    attribute :artifact_sha256, :string,
      allow_nil?: false,
      constraints: [match: ~r/\A[0-9a-f]{64}\z/]

    attribute :artifact_bytes, :integer,
      allow_nil?: false,
      constraints: [min: 1, max: 104_857_600]

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  identities do
    identity :machine, [:vm_id]
  end
end
