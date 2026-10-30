defmodule Marshall.GitHub.AuditEvent do
  @moduledoc "Payload-free transactional receipts for identity, credential and exclusion mutations."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.GitHub,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "github_audit_events"
    repo Marshall.Repo

    custom_indexes do
      index [:user_id, :inserted_at]
    end
  end

  cedar do
    internal [:read, :record]
  end

  actions do
    defaults [:read]

    create :record do
      accept [:connection_id, :user_id, :vm_id, :generation, :event]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :event, :atom,
      allow_nil?: false,
      constraints: [
        one_of: [
          :connected,
          :disconnected,
          :refresh_connected,
          :refresh_reconnect_required,
          :machine_excluded,
          :machine_included,
          :restored_invalidated
        ]
      ]

    attribute :generation, :integer, allow_nil?: false, constraints: [min: 1]
    create_timestamp :inserted_at
  end

  relationships do
    belongs_to :connection, Marshall.GitHub.Connection, allow_nil?: false
    belongs_to :user, Marshall.Accounts.User, allow_nil?: false
    belongs_to :vm, Marshall.Compute.VirtualMachine
  end
end
