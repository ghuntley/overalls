defmodule Marshall.Enrico.AuditEvent do
  @moduledoc "Append-only actor and outcome history for repository mirroring."
  use Ash.Resource,
    otp_app: :marshall,
    domain: Marshall.Enrico,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Marshall.Authorization.AshAuthorizer]

  postgres do
    table "enrico_audit_events"
    repo Marshall.Repo
  end

  cedar do
    internal [:read, :record]
  end

  actions do
    defaults [:read]

    create :record do
      accept [:repository_id, :actor_id, :attempt_id, :kind, :failure_reason]
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :repository_id, :uuid, allow_nil?: false
    attribute :actor_id, :uuid
    attribute :attempt_id, :uuid

    attribute :failure_reason, :atom,
      constraints: [
        one_of: [
          :tls_untrusted,
          :timeout,
          :unauthorized,
          :service_unavailable,
          :git_failed,
          :unknown
        ]
      ]

    attribute :kind, :atom,
      allow_nil?: false,
      constraints: [
        one_of: [
          :registered,
          :refresh_requested,
          :refresh_succeeded,
          :refresh_failed,
          :remove_requested,
          :removed
        ]
      ]

    create_timestamp :inserted_at
  end
end
