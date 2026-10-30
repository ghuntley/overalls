defmodule Marshall.Agents.CLISession do
  @moduledoc "Browser-approved, VM-scoped CLI credential digest."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Agents,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "agent_cli_sessions"
    repo Marshall.Repo

    custom_indexes do
      index [:code_hash], unique: true
      index [:expires_at]
    end
  end

  cedar do
    internal [:read, :approve, :expire]
  end

  actions do
    defaults [:read]

    create :approve do
      accept [:code_hash, :vm_id, :actor_id, :expires_at]
    end

    destroy :expire
  end

  attributes do
    uuid_v7_primary_key :id

    attribute :code_hash, :string,
      allow_nil?: false,
      constraints: [min_length: 64, max_length: 64]

    attribute :vm_id, :uuid, allow_nil?: false
    attribute :actor_id, :uuid, allow_nil?: false
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false
    create_timestamp :inserted_at
  end
end
