defmodule Marshall.GitHub.RequestLease do
  @moduledoc "Two-second durable request pin, bounded by a five-minute stream lifetime."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.GitHub,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "github_request_leases"
    repo Marshall.Repo

    custom_indexes do
      index [:connection_id, :generation, :expires_at]
    end
  end

  cedar do
    internal [:read, :record, :renew, :close, :purge]
  end

  actions do
    defaults [:read]

    create :record do
      accept [:connection_id, :vm_id, :generation, :expires_at, :maximum_expires_at]
    end

    update :renew do
      accept [:expires_at]
    end

    destroy :close
    destroy :purge
  end

  attributes do
    uuid_primary_key :id
    attribute :generation, :integer, allow_nil?: false, constraints: [min: 1]
    attribute :expires_at, :utc_datetime_usec, allow_nil?: false
    attribute :maximum_expires_at, :utc_datetime_usec, allow_nil?: false
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :connection, Marshall.GitHub.Connection, allow_nil?: false
    belongs_to :vm, Marshall.Compute.VirtualMachine, allow_nil?: false
  end
end
