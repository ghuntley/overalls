defmodule Marshall.Administration.AuditEvent do
  @moduledoc "Durable idempotent administrative operation receipts without request payloads."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Administration,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "admin_audit_events"
    repo Marshall.Repo

    custom_indexes do
      index [:inserted_at, :id]
    end
  end

  cedar do
    internal [:read, :record]
  end

  actions do
    defaults [:read]

    create :record do
      accept [:actor_id, :request_id, :action, :resource_type, :resource_id]
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :actor_id, :uuid, allow_nil?: false
    attribute :request_id, :uuid, allow_nil?: false

    attribute :action, :atom,
      allow_nil?: false,
      constraints: [
        one_of: [:retry_job, :redaction_requested, :redaction_cancelled, :artifact_admin_delete]
      ]

    attribute :resource_type, :atom,
      allow_nil?: false,
      constraints: [one_of: [:job, :redaction, :artifact]]

    attribute :resource_id, :string,
      allow_nil?: false,
      constraints: [min_length: 1, max_length: 64]

    create_timestamp :inserted_at
  end

  identities do
    identity :one_actor_request, [:actor_id, :request_id]
  end
end
