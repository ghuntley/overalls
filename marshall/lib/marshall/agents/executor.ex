defmodule Marshall.Agents.Executor do
  @moduledoc "VM execution-bound lease for a dumb guest tool executor."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "agent_executors"
    repo Marshall.Repo

    custom_indexes do
      index [:root_id, :fence_epoch], unique: true
      index [:root_id], unique: true, where: "invalidated_at IS NULL"
    end
  end

  cedar do
    internal [:read, :register, :heartbeat, :invalidate]
  end

  actions do
    defaults [:read]

    create :register do
      accept [
        :root_id,
        :vm_id,
        :placement_id,
        :execution_epoch,
        :fence_epoch,
        :expires_at,
        :binary_sha256,
        :capabilities
      ]
    end

    update :heartbeat do
      accept [:expires_at]
    end

    update :invalidate do
      accept [:invalidated_at]
    end
  end

  attributes do
    uuid_v7_primary_key :id
    attribute :root_id, :uuid, allow_nil?: false
    attribute :vm_id, :uuid, allow_nil?: false
    attribute :placement_id, :uuid, allow_nil?: false
    attribute :execution_epoch, :integer, allow_nil?: false, constraints: [min: 1]
    attribute :fence_epoch, :integer, allow_nil?: false, constraints: [min: 1]
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false
    attribute :binary_sha256, :string, constraints: [match: ~r/\A[0-9a-f]{64}\z/]

    attribute :capabilities, {:array, :string},
      allow_nil?: false,
      default: [],
      constraints: [max_length: 5]

    attribute :invalidated_at, :utc_datetime_usec
    create_timestamp :inserted_at
  end
end
